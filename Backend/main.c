#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#define _GNU_SOURCE

#include <arpa/inet.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "HTTPCache.h"
#include "ContainerContext.h"
#ifdef __linux__
#include <linux/perf_event.h>
#include <sys/syscall.h>
#endif

#define DEFAULT_PORT 7356
#define READ_BUFFER_SIZE 8192
#define MAX_STACK_DEPTH 128
#define MAX_PROFILE_AGGREGATES 2000
#define TIMELINE_BUCKET_SECONDS 0.010
#define MAX_TIMELINE_BUCKETS 300000
#define MAX_PROFILE_FREQUENCY 1000
#define MAX_STORED_PROFILES 32
#define PROFILE_BINARY_VERSION 1
#define PROFILE_BINARY_PROCESSES 1
#define PROFILE_BINARY_PROFILE_LIST 2
#define PROFILE_BINARY_RECORDING 3
#define PROFILE_BINARY_PROFILE 4
#define PROFILE_BINARY_PERF_CONFIG 5
#define PROFILE_BINARY_FILE_PICKER 6

static const unsigned char kProfileBinaryMagic[4] = {'P', 'R', 'F', 'L'};
static const char *kProfileBinaryContentType = "application/vnd.outer-profile+binary";

static const char *kBundleUrlPath = "/bundles/ProfileContent";
static const char *kBundleUrlPathMacosArm = "/bundles/ProfileContent/macos-arm";
static const char *kBundleUrlPathMacosX86 = "/bundles/ProfileContent/macos-x86";
static const char *kBundleFilePathMacosArm = "ProfileContent.bundle.macos-arm.aar";
static const char *kBundleFilePathMacosX86 = "ProfileContent.bundle.macos-x86.aar";

static char g_bundle_file_path_macos_arm[PATH_MAX] = "";
static char g_bundle_file_path_macos_x86[PATH_MAX] = "";
static char g_web_root[PATH_MAX] = "";
static char g_backend_label[256] = "org.outershell.Profile";
static char g_perf_path[PATH_MAX] = "";
static bool g_perf_status_checked = false;
static bool g_perf_status_usable = false;
static bool g_perf_status_machine_unsupported = false;
static char g_perf_status_path[PATH_MAX] = "";
static char g_perf_status_message[1024] = "";
static volatile sig_atomic_t g_shutdown_requested = 0;
static volatile sig_atomic_t g_listener_fd = -1;
static bool g_systemd_socket_activation = false;
static bool g_current_request_is_head = false;

static char *read_text_file(const char *path, size_t max_bytes);

typedef struct {
    char *data;
    size_t length;
    size_t capacity;
} StringBuilder;

typedef struct {
    int pid;
    int ppid;
    char *name;
    char *command;
} ProcessRow;

typedef struct {
    ProcessRow *items;
    size_t count;
    size_t capacity;
} ProcessList;

typedef struct {
    char **frames;
    size_t depth;
    uint32_t count;
} StackAggregate;

typedef struct {
    StackAggregate *items;
    size_t count;
    size_t capacity;
    uint32_t sample_count;
} StackAggregates;

typedef struct {
    double timestamp;
    char **frames;
    size_t depth;
} StackSample;

typedef struct {
    StackSample *items;
    size_t count;
    size_t capacity;
} StackSamples;

typedef struct {
    uint64_t id;
    int pid;
    int duration;
    int frequency;
    int record_status;
    int script_status;
    bool parsed;
    bool have_cpu_milliseconds;
    double cpu_milliseconds;
    double start_time;
    double end_time;
    char *status;
    char *record_output;
    char *script_error;
    StackSamples samples;
    ContainerContext container;
} ProfileRun;

typedef struct {
    ProfileRun *items;
    size_t count;
    size_t capacity;
} ProfileStore;

typedef struct {
    bool active;
    uint64_t id;
    int pid;
    int frequency;
    pid_t child_pid;
    char temp_dir[PATH_MAX];
    char perf_data[PATH_MAX];
    char record_log[PATH_MAX];
    char script_text[PATH_MAX];
    char script_err[PATH_MAX];
    char perf_path[PATH_MAX];
    uint64_t cpu_ticks_before;
    bool have_cpu_ticks_before;
    double start_time;
    ContainerContext container;
} RecordingRun;

typedef struct {
    char name[NAME_MAX + 1];
    char path[PATH_MAX];
    bool is_directory;
    uint64_t size;
} FilePickerEntry;

static ProfileStore g_profiles = {0};
static RecordingRun g_recording = {0};
static uint64_t g_next_profile_id = 1;

static void handle_shutdown_signal(int signal_number) {
    (void)signal_number;
    g_shutdown_requested = 1;
    if (g_listener_fd >= 0) close((int)g_listener_fd);
}

static void write_uint32_le(unsigned char *dst, uint32_t value) {
    dst[0] = (unsigned char)(value & 0xffu);
    dst[1] = (unsigned char)((value >> 8) & 0xffu);
    dst[2] = (unsigned char)((value >> 16) & 0xffu);
    dst[3] = (unsigned char)((value >> 24) & 0xffu);
}

static void write_uint64_le(unsigned char *dst, uint64_t value) {
    for (int i = 0; i < 8; i++) dst[i] = (unsigned char)((value >> (i * 8)) & 0xffu);
}

static bool queue_all(int fd, const void *data, size_t len) {
    const char *bytes = (const char *)data;
    while (len > 0) {
        ssize_t written = write(fd, bytes, len);
        if (written < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        bytes += written;
        len -= (size_t)written;
    }
    return true;
}

static void send_response(int fd, int status, const char *status_text, const char *content_type,
                          const void *body, size_t body_len) {
    char header[512];
    int header_len = snprintf(header, sizeof(header),
                              "HTTP/1.1 %d %s\r\n"
                              "Content-Type: %s\r\n"
                              "Content-Length: %zu\r\n"
                              "Connection: close\r\n"
                              "Cache-Control: no-store\r\n"
                              "\r\n",
                              status, status_text, content_type, body_len);
    if (header_len > 0 && (size_t)header_len < sizeof(header)) queue_all(fd, header, (size_t)header_len);
    if (!g_current_request_is_head && body && body_len > 0) queue_all(fd, body, body_len);
}

static void send_text_response(int fd, int status, const char *message) {
    const char *status_text = status == 200 ? "OK" :
                              status == 400 ? "Bad Request" :
                              status == 404 ? "Not Found" :
                              status == 500 ? "Internal Server Error" : "Error";
    send_response(fd, status, status_text, "text/plain; charset=utf-8", message, strlen(message));
}

static void send_cached_header(int fd,
                               int status,
                               const char *content_type,
                               size_t content_length,
                               const char *etag,
                               const char *last_modified) {
    char header[1024];
    size_t header_length = outer_http_cache_response_header(header, sizeof(header), status,
                                                            content_type, content_length,
                                                            etag, last_modified);
    if (header_length > 0) queue_all(fd, header, header_length);
}

static void send_cached_memory_response(int fd,
                                        const char *request,
                                        size_t request_header_length,
                                        const char *content_type,
                                        const void *body,
                                        size_t body_length,
                                        bool send_body) {
    time_t last_modified = outer_http_cache_server_start_time();
    char etag[96], last_modified_text[64];
    outer_http_cache_memory_etag(body, body_length, etag, sizeof(etag));
    outer_http_cache_format_date(last_modified, last_modified_text, sizeof(last_modified_text));
    if (outer_http_cache_not_modified(request, request_header_length, etag, &last_modified)) {
        send_cached_header(fd, 304, content_type, 0, etag, last_modified_text);
        return;
    }
    send_cached_header(fd, 200, content_type, body_length, etag, last_modified_text);
    if (send_body && body_length > 0) queue_all(fd, body, body_length);
}

static bool request_accepts_outerframe(const char *request, size_t request_length) {
    static const char needle[] = "application/vnd.outerframe";
    return request && request_length >= sizeof(needle) - 1 &&
           memmem(request, request_length, needle, sizeof(needle) - 1) != NULL;
}

static void send_web_file(int fd, const char *name, const char *content_type,
                          const char *request, size_t request_length, bool send_body) {
    if (!g_web_root[0] || !name || strchr(name, '/')) {
        send_text_response(fd, 404, "web frontend not installed\n");
        return;
    }
    char path[PATH_MAX];
    if (snprintf(path, sizeof(path), "%s/%s", g_web_root, name) >= (int)sizeof(path)) {
        send_text_response(fd, 404, "not found\n");
        return;
    }
    int file_fd = open(path, O_RDONLY);
    if (file_fd < 0) {
        send_text_response(fd, 404, "web frontend not installed\n");
        return;
    }
    struct stat st;
    if (fstat(file_fd, &st) != 0 || st.st_size < 0) {
        close(file_fd);
        send_text_response(fd, 500, "failed to stat web asset\n");
        return;
    }
    size_t size = (size_t)st.st_size;
    unsigned char *data = malloc(size ? size : 1);
    if (!data) {
        close(file_fd);
        send_text_response(fd, 500, "out of memory\n");
        return;
    }
    size_t used = 0;
    while (used < size) {
        ssize_t n = read(file_fd, data + used, size - used);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        used += (size_t)n;
    }
    close(file_fd);
    if (used != size) {
        free(data);
        send_text_response(fd, 500, "failed to read web asset\n");
        return;
    }
    send_cached_memory_response(fd, request, request_length, content_type, data, size, send_body);
    free(data);
}

static bool read_process_cpu_ticks(int pid, uint64_t *ticks_out) {
    if (ticks_out) *ticks_out = 0;
#ifndef __linux__
    (void)pid;
    return false;
#else
    char stat_path[PATH_MAX];
    snprintf(stat_path, sizeof(stat_path), "/proc/%d/stat", pid);
    char *stat_text = read_text_file(stat_path, 4096);
    if (!stat_text) return false;
    char *close_paren = strrchr(stat_text, ')');
    if (!close_paren) {
        free(stat_text);
        return false;
    }

    char state = '\0';
    unsigned long long utime = 0;
    unsigned long long stime = 0;
    int parsed = sscanf(close_paren + 2,
                        " %c %*d %*d %*d %*d %*d %*u %*llu %*llu %*llu %*llu %llu %llu",
                        &state,
                        &utime,
                        &stime);
    free(stat_text);
    if (parsed != 3) return false;
    (void)state;
    if (ticks_out) *ticks_out = (uint64_t)(utime + stime);
    return true;
#endif
}

static bool sb_reserve(StringBuilder *builder, size_t additional) {
    if (builder->length + additional + 1 <= builder->capacity) return true;
    size_t new_capacity = builder->capacity ? builder->capacity * 2 : 4096;
    while (new_capacity < builder->length + additional + 1) new_capacity *= 2;
    char *new_data = realloc(builder->data, new_capacity);
    if (!new_data) return false;
    builder->data = new_data;
    builder->capacity = new_capacity;
    return true;
}

static bool sb_append_n(StringBuilder *builder, const char *text, size_t length) {
    if (!sb_reserve(builder, length)) return false;
    memcpy(builder->data + builder->length, text, length);
    builder->length += length;
    builder->data[builder->length] = '\0';
    return true;
}

static bool sb_append_u32(StringBuilder *builder, uint32_t value) {
    unsigned char bytes[4];
    write_uint32_le(bytes, value);
    return sb_append_n(builder, (const char *)bytes, sizeof(bytes));
}

static bool sb_append_i32(StringBuilder *builder, int32_t value) {
    return sb_append_u32(builder, (uint32_t)value);
}

static bool sb_append_u64(StringBuilder *builder, uint64_t value) {
    unsigned char bytes[8];
    write_uint64_le(bytes, value);
    return sb_append_n(builder, (const char *)bytes, sizeof(bytes));
}

static bool sb_append_f64(StringBuilder *builder, double value) {
    uint64_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return sb_append_u64(builder, bits);
}

static bool sb_append_binary_header(StringBuilder *builder, uint32_t type) {
    return sb_append_n(builder, (const char *)kProfileBinaryMagic, sizeof(kProfileBinaryMagic)) &&
           sb_append_u32(builder, PROFILE_BINARY_VERSION) &&
           sb_append_u32(builder, type) &&
           sb_append_u32(builder, 0);
}

static void send_outer_descriptor(int fd,
                                  const char *request,
                                  size_t request_header_length,
                                  bool send_body) {
    const char *plugin_payload = "{\"processesAPIPath\":\"/api/processes\",\"profileAPIPath\":\"/api/profile\",\"profileStartAPIPath\":\"/api/profile/start\",\"profileStopAPIPath\":\"/api/profile/stop\",\"profileStatusAPIPath\":\"/api/profile/status\",\"profileListAPIPath\":\"/api/profiles\",\"profileRangeAPIPath\":\"/api/profile/range\",\"profileDeleteAPIPath\":\"/api/profile/delete\",\"perfAPIPath\":\"/api/perf\",\"filePickerAPIPath\":\"/api/file-picker\"}";
    size_t path_len = strlen(kBundleUrlPath);
    size_t plugin_len = strlen(plugin_payload);
    size_t header_len = 40;
    size_t data_offset = header_len + path_len;
    size_t total_len = data_offset + plugin_len;
    unsigned char *payload = malloc(total_len);
    if (!payload) {
        send_text_response(fd, 500, "out of memory\n");
        return;
    }
    payload[0] = 'O';
    payload[1] = 'U';
    payload[2] = 'T';
    payload[3] = 'R';
    write_uint32_le(payload + 4, 1);
    write_uint64_le(payload + 8, (uint64_t)header_len);
    write_uint64_le(payload + 16, (uint64_t)path_len);
    write_uint64_le(payload + 24, (uint64_t)data_offset);
    write_uint64_le(payload + 32, (uint64_t)plugin_len);
    memcpy(payload + header_len, kBundleUrlPath, path_len);
    memcpy(payload + data_offset, plugin_payload, plugin_len);
    send_cached_memory_response(fd, request, request_header_length,
                                "application/vnd.outerframe", payload, total_len,
                                send_body);
    free(payload);
}

static void send_bundle_file(int fd,
                             const char *path,
                             const char *request,
                             size_t request_header_length,
                             bool send_body) {
    int file_fd = open(path, O_RDONLY);
    if (file_fd < 0) {
        send_text_response(fd, 404, "bundle not found\n");
        return;
    }
    struct stat st;
    if (fstat(file_fd, &st) != 0 || st.st_size < 0) {
        close(file_fd);
        send_text_response(fd, 500, "failed to stat bundle\n");
        return;
    }
    char etag[96], last_modified[64];
    outer_http_cache_file_etag(&st, etag, sizeof(etag));
    outer_http_cache_format_date(st.st_mtime, last_modified, sizeof(last_modified));
    if (outer_http_cache_not_modified(request, request_header_length, etag, &st.st_mtime)) {
        close(file_fd);
        send_cached_header(fd, 304, "application/octet-stream", 0, etag, last_modified);
        return;
    }
    size_t size = (size_t)st.st_size;
    if (!send_body) {
        close(file_fd);
        send_cached_header(fd, 200, "application/octet-stream", size, etag, last_modified);
        return;
    }
    unsigned char *data = malloc(size ? size : 1);
    if (!data) {
        close(file_fd);
        send_text_response(fd, 500, "out of memory\n");
        return;
    }
    size_t offset = 0;
    while (offset < size) {
        ssize_t got = read(file_fd, data + offset, size - offset);
        if (got < 0) {
            if (errno == EINTR) continue;
            free(data);
            close(file_fd);
            send_text_response(fd, 500, "failed to read bundle\n");
            return;
        }
        if (got == 0) break;
        offset += (size_t)got;
    }
    close(file_fd);
    if (offset != size) {
        free(data);
        send_text_response(fd, 500, "failed to read bundle\n");
        return;
    }
    send_cached_header(fd, 200, "application/octet-stream", size, etag, last_modified);
    if (size > 0) queue_all(fd, data, size);
    free(data);
}

static int hex_value(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static void url_decode(const char *src, char *dst, size_t dst_size) {
    if (!dst_size) return;
    size_t out = 0;
    for (size_t i = 0; src && src[i] && out + 1 < dst_size; i++) {
        if (src[i] == '%' && isxdigit((unsigned char)src[i + 1]) && isxdigit((unsigned char)src[i + 2])) {
            dst[out++] = (char)((hex_value(src[i + 1]) << 4) | hex_value(src[i + 2]));
            i += 2;
        } else if (src[i] == '+') {
            dst[out++] = ' ';
        } else {
            dst[out++] = src[i];
        }
    }
    dst[out] = '\0';
}

static bool query_value(const char *query, const char *name, char *dst, size_t dst_size) {
    if (!query || !name || !dst || dst_size == 0) return false;
    size_t name_len = strlen(name);
    const char *p = query;
    while (*p) {
        const char *part_end = strchr(p, '&');
        if (!part_end) part_end = p + strlen(p);
        const char *equals = memchr(p, '=', (size_t)(part_end - p));
        if (equals && (size_t)(equals - p) == name_len && strncmp(p, name, name_len) == 0) {
            char encoded[1024];
            size_t len = (size_t)(part_end - equals - 1);
            if (len >= sizeof(encoded)) len = sizeof(encoded) - 1;
            memcpy(encoded, equals + 1, len);
            encoded[len] = '\0';
            url_decode(encoded, dst, dst_size);
            return true;
        }
        p = *part_end ? part_end + 1 : part_end;
    }
    return false;
}

static char *read_text_file(const char *path, size_t max_bytes) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return NULL;
    char *buffer = calloc(max_bytes + 1, 1);
    if (!buffer) {
        close(fd);
        return NULL;
    }
    ssize_t got = read(fd, buffer, max_bytes);
    close(fd);
    if (got < 0) {
        free(buffer);
        return NULL;
    }
    buffer[got] = '\0';
    return buffer;
}

static char *trimmed_duplicate(const char *text) {
    if (!text) return strdup("");
    while (isspace((unsigned char)*text)) text++;
    size_t len = strlen(text);
    while (len > 0 && isspace((unsigned char)text[len - 1])) len--;
    char *copy = malloc(len + 1);
    if (!copy) return NULL;
    memcpy(copy, text, len);
    copy[len] = '\0';
    return copy;
}

static bool process_list_append(ProcessList *list, ProcessRow row) {
    if (list->count == list->capacity) {
        size_t new_capacity = list->capacity ? list->capacity * 2 : 128;
        ProcessRow *new_items = realloc(list->items, new_capacity * sizeof(ProcessRow));
        if (!new_items) return false;
        list->items = new_items;
        list->capacity = new_capacity;
    }
    list->items[list->count++] = row;
    return true;
}

static void process_list_free(ProcessList *list) {
    for (size_t i = 0; i < list->count; i++) {
        free(list->items[i].name);
        free(list->items[i].command);
    }
    free(list->items);
    memset(list, 0, sizeof(*list));
}

static int compare_process_rows(const void *a, const void *b) {
    const ProcessRow *left = a;
    const ProcessRow *right = b;
    return left->pid - right->pid;
}

static bool collect_processes(ProcessList *list) {
#ifdef __linux__
    DIR *dir = opendir("/proc");
    if (!dir) return false;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (!isdigit((unsigned char)entry->d_name[0])) continue;
        int pid = atoi(entry->d_name);
        if (pid <= 0) continue;
        char stat_path[PATH_MAX];
        snprintf(stat_path, sizeof(stat_path), "/proc/%d/stat", pid);
        char *stat_text = read_text_file(stat_path, 4096);
        if (!stat_text) continue;
        char *open_paren = strchr(stat_text, '(');
        char *close_paren = strrchr(stat_text, ')');
        if (!open_paren || !close_paren || close_paren <= open_paren) {
            free(stat_text);
            continue;
        }
        *close_paren = '\0';
        char *name = trimmed_duplicate(open_paren + 1);
        int ppid = 0;
        sscanf(close_paren + 2, "%*c %d", &ppid);
        free(stat_text);

        char cmd_path[PATH_MAX];
        snprintf(cmd_path, sizeof(cmd_path), "/proc/%d/cmdline", pid);
        char *cmd = read_text_file(cmd_path, 4096);
        if (cmd) {
            for (char *p = cmd; p < cmd + 4096 && *p; p++) {
                if (*p == '\0') *p = ' ';
            }
            for (size_t i = 0; i < 4096 && cmd[i]; i++) {
                if (cmd[i] == '\0') cmd[i] = ' ';
            }
        }
        char *command = trimmed_duplicate(cmd && cmd[0] ? cmd : name);
        free(cmd);
        if (!name || !command || !process_list_append(list, (ProcessRow){.pid = pid, .ppid = ppid, .name = name, .command = command})) {
            free(name);
            free(command);
            closedir(dir);
            return false;
        }
    }
    closedir(dir);
    qsort(list->items, list->count, sizeof(ProcessRow), compare_process_rows);
    return true;
#else
    FILE *pipe = popen("ps -axo pid=,ppid=,comm=,args=", "r");
    if (!pipe) return false;
    char line[8192];
    while (fgets(line, sizeof(line), pipe)) {
        int pid = 0;
        int ppid = 0;
        char name[256] = "";
        char command[4096] = "";
        if (sscanf(line, "%d %d %255s %4095[^\n]", &pid, &ppid, name, command) < 3) continue;
        char *name_copy = trimmed_duplicate(name);
        char *command_copy = trimmed_duplicate(command[0] ? command : name);
        if (!name_copy || !command_copy || !process_list_append(list, (ProcessRow){.pid = pid, .ppid = ppid, .name = name_copy, .command = command_copy})) {
            free(name_copy);
            free(command_copy);
            pclose(pipe);
            return false;
        }
    }
    pclose(pipe);
    qsort(list->items, list->count, sizeof(ProcessRow), compare_process_rows);
    return true;
#endif
}

static void expand_tilde_path(const char *input, char *output, size_t output_size) {
    if (!output || output_size == 0) return;
    const char *path = input && input[0] ? input : "~";
    if (path[0] == '~' && (path[1] == '\0' || path[1] == '/')) {
        const char *home = getenv("HOME");
        if (!home || !home[0]) home = "/";
        snprintf(output, output_size, "%s%s", home, path + 1);
    } else {
        snprintf(output, output_size, "%s", path);
    }
}

static void parent_path_for(const char *path, char *parent, size_t parent_size) {
    if (!parent || parent_size == 0) return;
    if (!path || !path[0] || strcmp(path, "/") == 0) {
        snprintf(parent, parent_size, "/");
        return;
    }
    char copy[PATH_MAX];
    snprintf(copy, sizeof(copy), "%s", path);
    size_t len = strlen(copy);
    while (len > 1 && copy[len - 1] == '/') copy[--len] = '\0';
    char *slash = strrchr(copy, '/');
    if (!slash) {
        snprintf(parent, parent_size, ".");
    } else if (slash == copy) {
        snprintf(parent, parent_size, "/");
    } else {
        *slash = '\0';
        snprintf(parent, parent_size, "%s", copy);
    }
}

static bool join_child_path(const char *directory, const char *name, char *output, size_t output_size) {
    if (!directory || !name || !output || output_size == 0) return false;
    int written = strcmp(directory, "/") == 0
        ? snprintf(output, output_size, "/%s", name)
        : snprintf(output, output_size, "%s/%s", directory, name);
    return written > 0 && (size_t)written < output_size;
}

static int compare_file_picker_entries(const void *lhs, const void *rhs) {
    const FilePickerEntry *a = lhs;
    const FilePickerEntry *b = rhs;
    if (a->is_directory != b->is_directory) return a->is_directory ? -1 : 1;
    return strcasecmp(a->name, b->name);
}

static void free_frame_array(char **frames, size_t depth) {
    for (size_t i = 0; i < depth; i++) free(frames[i]);
    free(frames);
}

static void aggregates_free(StackAggregates *aggregates) {
    for (size_t i = 0; i < aggregates->count; i++) {
        free_frame_array(aggregates->items[i].frames, aggregates->items[i].depth);
    }
    free(aggregates->items);
    memset(aggregates, 0, sizeof(*aggregates));
}

static void samples_free(StackSamples *samples) {
    for (size_t i = 0; i < samples->count; i++) {
        free_frame_array(samples->items[i].frames, samples->items[i].depth);
    }
    free(samples->items);
    memset(samples, 0, sizeof(*samples));
}

static void profile_run_free(ProfileRun *run) {
    free(run->status);
    free(run->record_output);
    free(run->script_error);
    samples_free(&run->samples);
    memset(run, 0, sizeof(*run));
}

static ProfileRun *profile_store_find(uint64_t id) {
    for (size_t i = 0; i < g_profiles.count; i++) {
        if (g_profiles.items[i].id == id) return &g_profiles.items[i];
    }
    return NULL;
}

static ProfileRun *profile_store_latest(void) {
    if (g_profiles.count == 0) return NULL;
    return &g_profiles.items[g_profiles.count - 1];
}

static bool profile_store_delete(uint64_t id) {
    for (size_t i = 0; i < g_profiles.count; i++) {
        if (g_profiles.items[i].id != id) continue;
        profile_run_free(&g_profiles.items[i]);
        if (i + 1 < g_profiles.count) {
            memmove(&g_profiles.items[i],
                    &g_profiles.items[i + 1],
                    (g_profiles.count - i - 1) * sizeof(ProfileRun));
        }
        g_profiles.count--;
        return true;
    }
    return false;
}

static bool profile_store_append(ProfileRun run) {
    if (g_profiles.count == MAX_STORED_PROFILES) {
        profile_run_free(&g_profiles.items[0]);
        if (g_profiles.count > 1) {
            memmove(&g_profiles.items[0],
                    &g_profiles.items[1],
                    (g_profiles.count - 1) * sizeof(ProfileRun));
        }
        g_profiles.count--;
    }
    if (g_profiles.count == g_profiles.capacity) {
        size_t new_capacity = g_profiles.capacity ? g_profiles.capacity * 2 : 8;
        if (new_capacity > MAX_STORED_PROFILES) new_capacity = MAX_STORED_PROFILES;
        ProfileRun *new_items = realloc(g_profiles.items, new_capacity * sizeof(ProfileRun));
        if (!new_items) return false;
        g_profiles.items = new_items;
        g_profiles.capacity = new_capacity;
    }
    g_profiles.items[g_profiles.count++] = run;
    return true;
}

static bool samples_add(StackSamples *samples, double timestamp, char **frames, size_t depth) {
    if (depth == 0) return true;
    if (samples->count == samples->capacity) {
        size_t new_capacity = samples->capacity ? samples->capacity * 2 : 512;
        StackSample *new_items = realloc(samples->items, new_capacity * sizeof(StackSample));
        if (!new_items) return false;
        samples->items = new_items;
        samples->capacity = new_capacity;
    }
    char **copy = calloc(depth, sizeof(char *));
    if (!copy) return false;
    for (size_t i = 0; i < depth; i++) {
        copy[i] = strdup(frames[i]);
        if (!copy[i]) {
            free_frame_array(copy, depth);
            return false;
        }
    }
    samples->items[samples->count++] = (StackSample){.timestamp = timestamp, .frames = copy, .depth = depth};
    return true;
}

static bool stack_equals(const StackAggregate *aggregate, char **frames, size_t depth) {
    if (aggregate->depth != depth) return false;
    for (size_t i = 0; i < depth; i++) {
        if (strcmp(aggregate->frames[i], frames[i]) != 0) return false;
    }
    return true;
}

static bool aggregates_add(StackAggregates *aggregates, char **frames, size_t depth) {
    if (depth == 0) return true;
    aggregates->sample_count++;
    for (size_t i = 0; i < aggregates->count; i++) {
        if (stack_equals(&aggregates->items[i], frames, depth)) {
            aggregates->items[i].count++;
            return true;
        }
    }
    if (aggregates->count == aggregates->capacity) {
        size_t new_capacity = aggregates->capacity ? aggregates->capacity * 2 : 256;
        StackAggregate *new_items = realloc(aggregates->items, new_capacity * sizeof(StackAggregate));
        if (!new_items) return false;
        aggregates->items = new_items;
        aggregates->capacity = new_capacity;
    }
    char **copy = calloc(depth, sizeof(char *));
    if (!copy) return false;
    for (size_t i = 0; i < depth; i++) {
        copy[i] = strdup(frames[i]);
        if (!copy[i]) {
            free_frame_array(copy, depth);
            return false;
        }
    }
    aggregates->items[aggregates->count++] = (StackAggregate){.frames = copy, .depth = depth, .count = 1};
    return true;
}

static bool aggregates_add_sample(StackAggregates *aggregates, const StackSample *sample) {
    return aggregates_add(aggregates, sample->frames, sample->depth);
}

static void trim_in_place(char *text) {
    if (!text) return;
    char *start = text;
    while (isspace((unsigned char)*start)) start++;
    if (start != text) memmove(text, start, strlen(start) + 1);
    size_t len = strlen(text);
    while (len > 0 && isspace((unsigned char)text[len - 1])) text[--len] = '\0';
}

static const char *path_basename(const char *path) {
    if (!path || !path[0]) return "";
    const char *slash = strrchr(path, '/');
    return slash && slash[1] ? slash + 1 : path;
}

static bool parse_frame_symbol_and_binary(const char *line,
                                          char *symbol,
                                          size_t symbol_size,
                                          char *binary,
                                          size_t binary_size) {
    if (!line || !symbol || symbol_size == 0 || !binary || binary_size == 0) return false;
    char work[4096];
    snprintf(work, sizeof(work), "%s", line);
    trim_in_place(work);
    if (!isxdigit((unsigned char)work[0])) return false;
    char *p = work;
    while (*p && !isspace((unsigned char)*p)) p++;
    while (isspace((unsigned char)*p)) p++;
    if (!*p) return false;
    char *start = p;
    while (*p && *p != '+' && *p != '(' && *p != '[' && *p != '\n' && *p != '\r') p++;
    while (p > start && isspace((unsigned char)p[-1])) p--;
    size_t len = (size_t)(p - start);
    if (len == 0) return false;
    if (len >= symbol_size) len = symbol_size - 1;
    memcpy(symbol, start, len);
    symbol[len] = '\0';
    if (strcmp(symbol, "0") == 0 || strcmp(symbol, "[unknown]") == 0) return false;

    binary[0] = '\0';
    char *open_paren = strrchr(p, '(');
    char *close_paren = strrchr(p, ')');
    if (open_paren && close_paren && close_paren > open_paren + 1) {
        *close_paren = '\0';
        const char *name = path_basename(open_paren + 1);
        snprintf(binary, binary_size, "%s", name);
        trim_in_place(binary);
    } else {
        char *open_bracket = strrchr(p, '[');
        char *close_bracket = strrchr(p, ']');
        if (open_bracket && close_bracket && close_bracket > open_bracket + 1) {
            *close_bracket = '\0';
            snprintf(binary, binary_size, "%s", open_bracket + 1);
            trim_in_place(binary);
        }
    }
    if (!binary[0]) snprintf(binary, binary_size, "unknown");
    return true;
}

static bool parse_sample_timestamp(const char *line, double *timestamp_out) {
    if (timestamp_out) *timestamp_out = 0.0;
    if (!line) return false;
    for (const char *colon = strchr(line, ':'); colon; colon = strchr(colon + 1, ':')) {
        const char *end = colon;
        while (end > line && isspace((unsigned char)end[-1])) end--;
        const char *start = end;
        while (start > line && (isdigit((unsigned char)start[-1]) || start[-1] == '.')) start--;
        if (start == end) continue;
        char number[64];
        size_t len = (size_t)(end - start);
        if (len >= sizeof(number)) continue;
        memcpy(number, start, len);
        number[len] = '\0';
        char *parse_end = NULL;
        double value = strtod(number, &parse_end);
        if (parse_end && *parse_end == '\0' && value > 0.0) {
            if (timestamp_out) *timestamp_out = value;
            return true;
        }
    }
    return false;
}

static bool finish_parsed_sample(StackSamples *samples, double timestamp, char **frames, size_t *depth) {
    if (!depth || *depth == 0) return true;
    for (size_t i = 0; i < *depth / 2; i++) {
        char *tmp = frames[i];
        frames[i] = frames[*depth - i - 1];
        frames[*depth - i - 1] = tmp;
    }
    bool ok = samples_add(samples, timestamp, frames, *depth);
    for (size_t i = 0; i < *depth; i++) {
        free(frames[i]);
        frames[i] = NULL;
    }
    *depth = 0;
    return ok;
}

static bool parse_perf_script_file(const char *path, StackSamples *samples) {
    FILE *file = fopen(path, "r");
    if (!file) return false;
    char line[4096];
    char *frames[MAX_STACK_DEPTH] = {0};
    size_t depth = 0;
    double current_timestamp = 0.0;
    bool ok = true;
    while (fgets(line, sizeof(line), file)) {
        bool indented = line[0] == ' ' || line[0] == '\t';
        char symbol[512];
        char binary[512];
        if (indented && parse_frame_symbol_and_binary(line, symbol, sizeof(symbol), binary, sizeof(binary))) {
            if (depth < MAX_STACK_DEPTH) {
                char frame[1100];
                snprintf(frame, sizeof(frame), "%s\t%s", symbol, binary);
                frames[depth] = strdup(frame);
                if (!frames[depth]) {
                    ok = false;
                    break;
                }
                depth++;
            }
            continue;
        }
        if (line[0] == '\n' || line[0] == '\r') {
            ok = finish_parsed_sample(samples, current_timestamp, frames, &depth);
            if (!ok) break;
            continue;
        }
        if (!indented) {
            ok = finish_parsed_sample(samples, current_timestamp, frames, &depth);
            if (!ok) break;
            double parsed_timestamp = 0.0;
            if (parse_sample_timestamp(line, &parsed_timestamp)) current_timestamp = parsed_timestamp;
        }
    }
    if (ok && depth > 0) {
        ok = finish_parsed_sample(samples, current_timestamp, frames, &depth);
    }
    for (size_t i = 0; i < depth; i++) free(frames[i]);
    fclose(file);
    return ok;
}

static int compare_aggregates_desc(const void *a, const void *b) {
    const StackAggregate *left = a;
    const StackAggregate *right = b;
    if (left->count < right->count) return 1;
    if (left->count > right->count) return -1;
    return 0;
}

static const char *find_perf_binary(void) {
    if (g_perf_path[0]) return g_perf_path;
    static const char *candidates[] = {"/usr/bin/perf", "/bin/perf", "/usr/local/bin/perf", NULL};
    for (int i = 0; candidates[i]; i++) {
        if (access(candidates[i], X_OK) == 0) return candidates[i];
    }
    return "perf";
}

static const char *find_versioned_perf_binary(void) {
    static char candidate_path[PATH_MAX];
    static const char *directories[] = {"/usr/bin", "/bin", "/usr/local/bin", NULL};
    for (int i = 0; directories[i]; i++) {
        DIR *dir = opendir(directories[i]);
        if (!dir) continue;
        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            if (strncmp(entry->d_name, "perf_", 5) != 0 && strncmp(entry->d_name, "perf-", 5) != 0) continue;
            snprintf(candidate_path, sizeof(candidate_path), "%s/%s", directories[i], entry->d_name);
            if (access(candidate_path, X_OK) == 0) {
                closedir(dir);
                return candidate_path;
            }
        }
        closedir(dir);
    }
    return NULL;
}

static void copy_first_nonempty_line(const char *text, char *dst, size_t dst_size) {
    if (!dst || dst_size == 0) return;
    dst[0] = '\0';
    if (!text) return;
    const char *p = text;
    while (*p) {
        while (*p == '\n' || *p == '\r') p++;
        const char *line_start = p;
        while (*p && *p != '\n' && *p != '\r') p++;
        const char *line_end = p;
        while (line_start < line_end && isspace((unsigned char)*line_start)) line_start++;
        while (line_end > line_start && isspace((unsigned char)line_end[-1])) line_end--;
        if (line_end > line_start) {
            size_t len = (size_t)(line_end - line_start);
            if (len >= dst_size) len = dst_size - 1;
            memcpy(dst, line_start, len);
            dst[len] = '\0';
            return;
        }
    }
}

static bool check_perf_available(const char *perf, char *message, size_t message_size) {
    if (message && message_size > 0) message[0] = '\0';
    int pipe_fds[2];
    if (pipe(pipe_fds) != 0) {
        if (message && message_size > 0) snprintf(message, message_size, "failed to create perf check pipe: %s", strerror(errno));
        return false;
    }

    pid_t child = fork();
    if (child < 0) {
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        if (message && message_size > 0) snprintf(message, message_size, "failed to start perf check: %s", strerror(errno));
        return false;
    }

    if (child == 0) {
        close(pipe_fds[0]);
        dup2(pipe_fds[1], STDOUT_FILENO);
        dup2(pipe_fds[1], STDERR_FILENO);
        if (pipe_fds[1] > STDERR_FILENO) close(pipe_fds[1]);
        execlp(perf, perf, "--version", (char *)NULL);
        _exit(127);
    }

    close(pipe_fds[1]);
    char output[2048];
    size_t used = 0;
    while (used + 1 < sizeof(output)) {
        ssize_t got = read(pipe_fds[0], output + used, sizeof(output) - used - 1);
        if (got < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (got == 0) break;
        used += (size_t)got;
    }
    output[used] = '\0';
    close(pipe_fds[0]);

    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return true;

    char detail[1024];
    copy_first_nonempty_line(output, detail, sizeof(detail));
    if (message && message_size > 0) {
        if (detail[0]) {
            snprintf(message, message_size, "perf is not installed or is not usable: %s\n", detail);
        } else if (WIFEXITED(status)) {
            snprintf(message, message_size, "perf is not installed or is not usable: perf --version exited with status %d\n", WEXITSTATUS(status));
        } else if (WIFSIGNALED(status)) {
            snprintf(message, message_size, "perf is not installed or is not usable: perf --version was terminated by signal %d\n", WTERMSIG(status));
        } else {
            snprintf(message, message_size, "perf is not installed or is not usable.\n");
        }
    }
    return false;
}

static bool check_perf_kernel_available(char *message, size_t message_size, bool *machine_unsupported) {
    if (message && message_size > 0) message[0] = '\0';
    if (machine_unsupported) *machine_unsupported = false;
#ifndef __linux__
    if (message && message_size > 0) snprintf(message, message_size, "Linux perf profiling is only available on Linux.\n");
    if (machine_unsupported) *machine_unsupported = true;
    return false;
#elif !defined(__NR_perf_event_open)
    if (message && message_size > 0) {
        snprintf(message,
                 message_size,
                 "This system does not expose the perf_event_open syscall number. Profile cannot record stack samples on this machine.\n");
    }
    if (machine_unsupported) *machine_unsupported = true;
    return false;
#else
    struct perf_event_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.type = PERF_TYPE_SOFTWARE;
    attr.size = sizeof(attr);
    attr.config = PERF_COUNT_SW_CPU_CLOCK;
    attr.disabled = 1;
    attr.exclude_kernel = 1;
    attr.exclude_hv = 1;

    int fd = (int)syscall(__NR_perf_event_open, &attr, 0, -1, -1, PERF_FLAG_FD_CLOEXEC);
    if (fd >= 0) {
        close(fd);
        return true;
    }

    int err = errno;
    if (message && message_size > 0) {
        if (err == ENOSYS) {
            snprintf(message,
                     message_size,
                     "This Linux kernel does not implement perf_event_open. It may have been built without CONFIG_PERF_EVENTS, so Profile cannot record stack samples on this machine.\n");
            if (machine_unsupported) *machine_unsupported = true;
        } else if (err == EACCES || err == EPERM) {
            snprintf(message,
                     message_size,
                     "The kernel denied perf_event_open: %s. Try running Profile as root or lowering kernel.perf_event_paranoid.\n",
                     strerror(err));
        } else if (err == ENOENT || err == EOPNOTSUPP) {
            snprintf(message,
                     message_size,
                     "This Linux kernel does not support the cpu-clock perf event needed by Profile: %s.\n",
                     strerror(err));
            if (machine_unsupported) *machine_unsupported = true;
        } else {
            snprintf(message,
                     message_size,
                     "Profile could not open a test perf event: %s.\n",
                     strerror(err));
        }
    }
    return false;
#endif
}

static bool check_perf_ready(const char *perf, char *message, size_t message_size) {
    if (message && message_size > 0) message[0] = '\0';
    if (!check_perf_available(perf, message, message_size)) return false;
    return check_perf_kernel_available(message, message_size, NULL);
}

static void refresh_perf_status(void) {
    const char *perf = find_perf_binary();
    char message[sizeof(g_perf_status_message)];

    bool machine_unsupported = false;
    if (!check_perf_kernel_available(message, sizeof(message), &machine_unsupported) && machine_unsupported) {
        if (g_perf_path[0] == '\0') {
            const char *versioned_perf = find_versioned_perf_binary();
            if (versioned_perf) perf = versioned_perf;
        }
        snprintf(g_perf_status_path, sizeof(g_perf_status_path), "%s", perf);
        snprintf(g_perf_status_message, sizeof(g_perf_status_message), "%s", message);
        g_perf_status_usable = false;
        g_perf_status_machine_unsupported = true;
        g_perf_status_checked = true;
        return;
    }

    bool perf_usable = check_perf_available(perf, message, sizeof(message));
    if (!perf_usable && g_perf_path[0] == '\0') {
        const char *versioned_perf = find_versioned_perf_binary();
        if (versioned_perf) {
            char versioned_message[sizeof(g_perf_status_message)];
            if (check_perf_available(versioned_perf, versioned_message, sizeof(versioned_message))) {
                perf = versioned_perf;
                perf_usable = true;
                snprintf(message, sizeof(message), "%s", versioned_message);
            }
        }
    }
    bool usable = perf_usable && check_perf_kernel_available(message, sizeof(message), &machine_unsupported);
    snprintf(g_perf_status_path, sizeof(g_perf_status_path), "%s", perf);
    snprintf(g_perf_status_message, sizeof(g_perf_status_message), "%s", message);
    g_perf_status_usable = usable;
    g_perf_status_machine_unsupported = machine_unsupported;
    g_perf_status_checked = true;
}

static bool cached_perf_ready(char *message, size_t message_size) {
    const char *perf = find_perf_binary();
    if (!g_perf_status_checked || (g_perf_path[0] != '\0' && strcmp(g_perf_status_path, perf) != 0)) {
        refresh_perf_status();
    }
    if (message && message_size > 0) {
        snprintf(message, message_size, "%s", g_perf_status_message);
    }
    return g_perf_status_usable;
}

static char *read_whole_file_or_empty(const char *path) {
    char *text = read_text_file(path, 65536);
    if (!text) return strdup("");
    return text;
}

static void log_perf_diagnostic(const char *context, const char *detail) {
    char first_line[1024];
    copy_first_nonempty_line(detail, first_line, sizeof(first_line));
    if (first_line[0]) {
        fprintf(stderr, "ProfileBackend %s: %s\n", context ? context : "perf error", first_line);
    } else {
        fprintf(stderr, "ProfileBackend %s\n", context ? context : "perf error");
    }
    fflush(stderr);
}

static void log_perf_command_failure(const char *context, int status, const char *output) {
    char first_line[1024];
    copy_first_nonempty_line(output, first_line, sizeof(first_line));
    if (first_line[0]) {
        fprintf(stderr, "ProfileBackend %s: %s\n", context, first_line);
    } else if (WIFEXITED(status)) {
        fprintf(stderr, "ProfileBackend %s: exited with status %d\n", context, WEXITSTATUS(status));
    } else if (WIFSIGNALED(status)) {
        fprintf(stderr, "ProfileBackend %s: terminated by signal %d\n", context, WTERMSIG(status));
    } else {
        fprintf(stderr, "ProfileBackend %s\n", context);
    }
    fflush(stderr);
}

static void cleanup_temp_dir(const char *dir) {
    if (!dir || !dir[0]) return;
    char command[PATH_MAX + 32];
    snprintf(command, sizeof(command), "rm -rf '%s'", dir);
    system(command);
}

static double monotonic_seconds(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0.0;
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

static int wait_exit_status(int status) {
    return WIFEXITED(status) ? WEXITSTATUS(status) : status;
}

static bool perf_record_status_ok(int status) {
    if (WIFEXITED(status)) {
        int exit_status = WEXITSTATUS(status);
        return exit_status == 0 || exit_status == 2;
    }
    if (WIFSIGNALED(status)) {
        int signal = WTERMSIG(status);
        return signal == SIGINT || signal == SIGTERM;
    }
    return false;
}

static bool perf_script_status_ok(int status) {
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

typedef struct {
    StringBuilder strings;
    uint32_t base_offset;
} BinaryStringTable;

static bool send_binary_builder(int fd, StringBuilder *binary);

static bool binary_add_string(BinaryStringTable *table, const char *text, uint32_t *offset_out, uint32_t *length_out) {
    size_t length = strlen(text ? text : "");
    if (table->base_offset > UINT32_MAX - table->strings.length || length > UINT32_MAX) return false;
    if (offset_out) *offset_out = table->base_offset + (uint32_t)table->strings.length;
    if (length_out) *length_out = (uint32_t)length;
    return sb_append_n(&table->strings, text ? text : "", length);
}

static bool binary_add_string_n(BinaryStringTable *table, const char *text, size_t length, uint32_t *offset_out, uint32_t *length_out) {
    if (table->base_offset > UINT32_MAX - table->strings.length || length > UINT32_MAX) return false;
    if (offset_out) *offset_out = table->base_offset + (uint32_t)table->strings.length;
    if (length_out) *length_out = (uint32_t)length;
    return sb_append_n(&table->strings, text ? text : "", length);
}

static void send_perf_config_binary(int fd) {
    char check_message[1024];
    bool usable = cached_perf_ready(check_message, sizeof(check_message));
    const char *perf = g_perf_status_path[0] ? g_perf_status_path : find_perf_binary();
    const uint32_t header_size = 48;
    BinaryStringTable string_table = {.base_offset = header_size};
    uint32_t path_offset = 0, path_length = 0, message_offset = 0, message_length = 0;
    bool ok = binary_add_string(&string_table, perf, &path_offset, &path_length) &&
              binary_add_string(&string_table, check_message, &message_offset, &message_length);
    StringBuilder binary = {0};
    ok = ok &&
         sb_append_binary_header(&binary, PROFILE_BINARY_PERF_CONFIG) &&
         sb_append_u32(&binary, usable ? 1 : 0) &&
         sb_append_u32(&binary, path_offset) &&
         sb_append_u32(&binary, path_length) &&
         sb_append_u32(&binary, message_offset) &&
         sb_append_u32(&binary, message_length) &&
         sb_append_u32(&binary, header_size) &&
         sb_append_u32(&binary, (uint32_t)string_table.strings.length) &&
         sb_append_u32(&binary, g_perf_status_machine_unsupported ? 1 : 0) &&
         sb_append_n(&binary, string_table.strings.data, string_table.strings.length);
    free(string_table.strings.data);
    if (!ok) {
        free(binary.data);
        send_text_response(fd, 500, "out of memory\n");
        return;
    }
    send_binary_builder(fd, &binary);
}

static void send_file_picker_binary(int fd, const char *query) {
    char requested[PATH_MAX] = "";
    char expanded[PATH_MAX];
    query_value(query, "path", requested, sizeof(requested));
    expand_tilde_path(requested[0] ? requested : "/", expanded, sizeof(expanded));
    if (expanded[0] != '/') {
        snprintf(expanded, sizeof(expanded), "/");
    }

    DIR *dir = opendir(expanded);
    if (!dir) {
        char fallback[PATH_MAX];
        parent_path_for(expanded, fallback, sizeof(fallback));
        dir = opendir(fallback);
        if (dir) snprintf(expanded, sizeof(expanded), "%s", fallback);
    }
    if (!dir) {
        char message[PATH_MAX + 64];
        snprintf(message, sizeof(message), "failed to open %s: %s\n", expanded, strerror(errno));
        send_text_response(fd, 404, message);
        return;
    }

    FilePickerEntry *entries = NULL;
    size_t count = 0;
    size_t capacity = 0;
    struct dirent *entry = NULL;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        char child_path[PATH_MAX];
        if (!join_child_path(expanded, entry->d_name, child_path, sizeof(child_path))) continue;
        struct stat st;
        if (stat(child_path, &st) != 0 && lstat(child_path, &st) != 0) continue;
        bool is_directory = S_ISDIR(st.st_mode);
        if (!is_directory && !S_ISREG(st.st_mode) && !S_ISLNK(st.st_mode)) continue;
        if (count == capacity) {
            size_t new_capacity = capacity ? capacity * 2 : 64;
            FilePickerEntry *new_entries = realloc(entries, new_capacity * sizeof(FilePickerEntry));
            if (!new_entries) {
                free(entries);
                closedir(dir);
                send_text_response(fd, 500, "out of memory\n");
                return;
            }
            entries = new_entries;
            capacity = new_capacity;
        }
        FilePickerEntry *item = &entries[count++];
        memset(item, 0, sizeof(*item));
        snprintf(item->name, sizeof(item->name), "%s", entry->d_name);
        snprintf(item->path, sizeof(item->path), "%s", child_path);
        item->is_directory = is_directory;
        item->size = (uint64_t)st.st_size;
    }
    closedir(dir);
    qsort(entries, count, sizeof(FilePickerEntry), compare_file_picker_entries);

    char parent[PATH_MAX];
    parent_path_for(expanded, parent, sizeof(parent));

    const uint32_t header_size = 48;
    const uint32_t row_size = 32;
    uint32_t rows_offset = header_size;
    uint32_t strings_offset = rows_offset + (uint32_t)count * row_size;
    BinaryStringTable string_table = {.base_offset = strings_offset};
    uint32_t path_offset = 0, path_length = 0, parent_offset = 0, parent_length = 0;
    StringBuilder rows = {0};
    bool ok = binary_add_string(&string_table, expanded, &path_offset, &path_length) &&
              binary_add_string(&string_table, parent, &parent_offset, &parent_length);
    for (size_t i = 0; ok && i < count; i++) {
        uint32_t name_offset = 0, name_length = 0, entry_path_offset = 0, entry_path_length = 0;
        ok = binary_add_string(&string_table, entries[i].name, &name_offset, &name_length) &&
             binary_add_string(&string_table, entries[i].path, &entry_path_offset, &entry_path_length) &&
             sb_append_u32(&rows, name_offset) &&
             sb_append_u32(&rows, name_length) &&
             sb_append_u32(&rows, entry_path_offset) &&
             sb_append_u32(&rows, entry_path_length) &&
             sb_append_u32(&rows, entries[i].is_directory ? 1 : 0) &&
             sb_append_u32(&rows, 0) &&
             sb_append_u64(&rows, entries[i].size);
    }
    free(entries);

    StringBuilder binary = {0};
    ok = ok &&
         sb_append_binary_header(&binary, PROFILE_BINARY_FILE_PICKER) &&
         sb_append_u32(&binary, path_offset) &&
         sb_append_u32(&binary, path_length) &&
         sb_append_u32(&binary, parent_offset) &&
         sb_append_u32(&binary, parent_length) &&
         sb_append_u32(&binary, (uint32_t)count) &&
         sb_append_u32(&binary, rows_offset) &&
         sb_append_u32(&binary, strings_offset) &&
         sb_append_u32(&binary, (uint32_t)string_table.strings.length) &&
         sb_append_n(&binary, rows.data, rows.length) &&
         sb_append_n(&binary, string_table.strings.data, string_table.strings.length);
    free(rows.data);
    free(string_table.strings.data);
    if (!ok) {
        free(binary.data);
        send_text_response(fd, 500, "out of memory\n");
        return;
    }
    send_binary_builder(fd, &binary);
}

static uint32_t timeline_bucket_count_for_run(const ProfileRun *run) {
    double duration = run->end_time - run->start_time;
    if (duration <= 0.0) duration = run->duration > 0 ? (double)run->duration : 1.0;
    size_t bucket_count = (size_t)ceil(duration / TIMELINE_BUCKET_SECONDS);
    if (bucket_count < 1) bucket_count = 1;
    if (bucket_count > MAX_TIMELINE_BUCKETS) bucket_count = MAX_TIMELINE_BUCKETS;
    return (uint32_t)bucket_count;
}

static bool append_timeline_binary_rows(StringBuilder *binary, const ProfileRun *run) {
    double duration = run->end_time - run->start_time;
    if (duration <= 0.0) duration = run->duration > 0 ? (double)run->duration : 1.0;
    uint32_t bucket_count = timeline_bucket_count_for_run(run);
    double bucket_duration = duration / (double)bucket_count;
    uint32_t *sample_counts = calloc(bucket_count, sizeof(uint32_t));
    if (!sample_counts) return false;

    for (size_t i = 0; i < run->samples.count; i++) {
        double offset = run->samples.items[i].timestamp - run->start_time;
        if (offset < 0.0) continue;
        uint32_t bucket_index = (uint32_t)(offset / bucket_duration);
        if (bucket_index >= bucket_count) {
            if (run->samples.items[i].timestamp <= run->end_time) {
                bucket_index = bucket_count - 1;
            } else {
                continue;
            }
        }
        if (sample_counts[bucket_index] < UINT32_MAX) sample_counts[bucket_index]++;
    }

    bool ok = true;
    for (uint32_t i = 0; i < bucket_count; i++) {
        double start = run->start_time + (double)i * bucket_duration;
        double end = (i + 1 == bucket_count) ? run->end_time : start + bucket_duration;
        uint32_t samples = sample_counts[i];
        double cpu_percent = 0.0;
        if (run->frequency > 0 && bucket_duration > 0.0) {
            cpu_percent = ((double)samples * 100.0) / ((double)run->frequency * bucket_duration);
        }
        if (!sb_append_f64(binary, start - run->start_time) ||
            !sb_append_f64(binary, end - run->start_time) ||
            !sb_append_f64(binary, cpu_percent) ||
            !sb_append_u32(binary, samples) ||
            !sb_append_u32(binary, 0)) {
            ok = false;
            break;
        }
    }
    free(sample_counts);
    return ok;
}

static bool send_binary_builder(int fd, StringBuilder *binary) {
    send_response(fd, 200, "OK", kProfileBinaryContentType, binary->data, binary->length);
    free(binary->data);
    memset(binary, 0, sizeof(*binary));
    return true;
}

static void send_processes_binary(int fd, bool containers) {
    ProcessList list = {0};
    if (!collect_processes(&list)) {
        send_text_response(fd, 500, "failed to list processes\n");
        return;
    }

    const uint32_t header_size = 32;
    const uint32_t row_size = containers ? 56 : 24;
    uint32_t rows_offset = header_size;
    uint32_t strings_offset = rows_offset + (uint32_t)list.count * row_size;
    BinaryStringTable string_table = {.base_offset = strings_offset};
    StringBuilder rows = {0};
    bool ok = true;

    for (size_t i = 0; ok && i < list.count; i++) {
        ProcessRow *row = &list.items[i];
        uint32_t name_offset = 0, name_length = 0, command_offset = 0, command_length = 0;
        ok = binary_add_string(&string_table, row->name, &name_offset, &name_length) &&
             binary_add_string(&string_table, row->command, &command_offset, &command_length) &&
             sb_append_i32(&rows, row->pid) &&
             sb_append_i32(&rows, row->ppid) &&
             sb_append_u32(&rows, name_offset) &&
             sb_append_u32(&rows, name_length) &&
             sb_append_u32(&rows, command_offset) &&
             sb_append_u32(&rows, command_length);
        if (ok && containers) {
            ContainerContext context = container_for_pid(row->pid);
            uint32_t name_offset, name_length, id_offset, id_length;
            ok = binary_add_string(&string_table, context.name, &name_offset, &name_length) &&
                 binary_add_string(&string_table, context.id, &id_offset, &id_length) &&
                 sb_append_u32(&rows, name_offset) && sb_append_u32(&rows, name_length) &&
                 sb_append_u32(&rows, id_offset) && sb_append_u32(&rows, id_length) &&
                 sb_append_i32(&rows, context.local_pid) && sb_append_u32(&rows, 0) &&
                 sb_append_u64(&rows, container_process_start(row->pid));
        }
    }

    StringBuilder binary = {0};
    ok = ok &&
         sb_append_binary_header(&binary, PROFILE_BINARY_PROCESSES) &&
         sb_append_u32(&binary, (uint32_t)list.count) &&
         sb_append_u32(&binary, rows_offset) &&
         sb_append_u32(&binary, strings_offset) &&
         sb_append_u32(&binary, (uint32_t)string_table.strings.length) &&
         sb_append_n(&binary, rows.data, rows.length) &&
         sb_append_n(&binary, string_table.strings.data, string_table.strings.length);

    process_list_free(&list);
    free(rows.data);
    free(string_table.strings.data);

    if (!ok) {
        free(binary.data);
        send_text_response(fd, 500, "out of memory\n");
        return;
    }
    send_binary_builder(fd, &binary);
}

static void send_recording_binary(int fd, bool recording, uint64_t recording_id, int pid, int frequency, double elapsed) {
    StringBuilder binary = {0};
    bool ok = sb_append_binary_header(&binary, PROFILE_BINARY_RECORDING) &&
              sb_append_u32(&binary, recording ? 1 : 0) &&
              sb_append_u64(&binary, recording_id) &&
              sb_append_i32(&binary, pid) &&
              sb_append_i32(&binary, frequency) &&
              sb_append_f64(&binary, elapsed > 0.0 ? elapsed : 0.0);
    if (!ok) {
        free(binary.data);
        send_text_response(fd, 500, "out of memory\n");
        return;
    }
    send_binary_builder(fd, &binary);
}

static void send_profile_list_binary(int fd, bool containers) {
#ifndef __linux__
    send_text_response(fd, 500, "Linux perf profiling is only available on Linux.\n");
#else
    const uint32_t header_size = 48;
    const uint32_t row_size = containers ? 72 : 48;
    uint32_t rows_offset = header_size;
    uint32_t strings_offset = rows_offset + (uint32_t)g_profiles.count * row_size;
    BinaryStringTable string_table = {.base_offset = strings_offset};
    StringBuilder rows = {0};
    bool ok = true;

    for (size_t i = 0; ok && i < g_profiles.count; i++) {
        ProfileRun *run = &g_profiles.items[i];
        double duration = run->end_time - run->start_time;
        if (duration <= 0.0) duration = run->duration > 0 ? (double)run->duration : 0.0;
        uint32_t status_offset = 0, status_length = 0;
        ok = binary_add_string(&string_table, run->status, &status_offset, &status_length) &&
             sb_append_u64(&rows, run->id) &&
             sb_append_i32(&rows, run->pid) &&
             sb_append_i32(&rows, run->frequency) &&
             sb_append_u32(&rows, (uint32_t)run->samples.count) &&
             sb_append_u32(&rows, 0) &&
             sb_append_f64(&rows, duration) &&
             sb_append_f64(&rows, run->have_cpu_milliseconds ? run->cpu_milliseconds : -1.0) &&
             sb_append_u32(&rows, status_offset) &&
             sb_append_u32(&rows, status_length);
        if (ok && containers) {
            uint32_t name_offset, name_length, id_offset, id_length;
            ok = binary_add_string(&string_table, run->container.name, &name_offset, &name_length) &&
                 binary_add_string(&string_table, run->container.id, &id_offset, &id_length) &&
                 sb_append_u32(&rows, name_offset) && sb_append_u32(&rows, name_length) &&
                 sb_append_u32(&rows, id_offset) && sb_append_u32(&rows, id_length) &&
                 sb_append_i32(&rows, run->container.local_pid) && sb_append_u32(&rows, 0);
        }
    }

    StringBuilder binary = {0};
    ok = ok &&
         sb_append_binary_header(&binary, PROFILE_BINARY_PROFILE_LIST) &&
         sb_append_u32(&binary, g_recording.active ? 1 : 0) &&
         sb_append_u64(&binary, g_recording.id) &&
         sb_append_u32(&binary, (uint32_t)g_profiles.count) &&
         sb_append_u32(&binary, rows_offset) &&
         sb_append_u32(&binary, strings_offset) &&
         sb_append_u32(&binary, (uint32_t)string_table.strings.length) &&
         sb_append_u32(&binary, 0) &&
         sb_append_n(&binary, rows.data, rows.length) &&
         sb_append_n(&binary, string_table.strings.data, string_table.strings.length);

    free(rows.data);
    free(string_table.strings.data);

    if (!ok) {
        free(binary.data);
        send_text_response(fd, 500, "out of memory\n");
        return;
    }
    send_binary_builder(fd, &binary);
#endif
}

static bool append_binary_frame_row(StringBuilder *rows, BinaryStringTable *string_table, const char *frame) {
    const char *binary = frame ? strchr(frame, '\t') : NULL;
    uint32_t symbol_offset = 0, symbol_length = 0, binary_offset = 0, binary_length = 0;
    bool ok;
    if (binary) {
        ok = binary_add_string_n(string_table, frame, (size_t)(binary - frame), &symbol_offset, &symbol_length) &&
             binary_add_string(string_table, binary + 1, &binary_offset, &binary_length);
    } else {
        ok = binary_add_string(string_table, frame, &symbol_offset, &symbol_length) &&
             binary_add_string(string_table, "", &binary_offset, &binary_length);
    }
    return ok &&
           sb_append_u32(rows, symbol_offset) &&
           sb_append_u32(rows, symbol_length) &&
           sb_append_u32(rows, binary_offset) &&
           sb_append_u32(rows, binary_length);
}

static bool aggregate_samples_in_range(const StackSamples *samples,
                                       double start_time,
                                       double end_time,
                                       StackAggregates *aggregates);

static void send_profile_response_binary(int fd, const ProfileRun *run, double relative_start, double relative_end) {
    double full_duration = run->end_time - run->start_time;
    if (full_duration <= 0.0) full_duration = run->duration > 0 ? (double)run->duration : 1.0;
    if (relative_start < 0.0) relative_start = 0.0;
    if (relative_end <= 0.0 || relative_end > full_duration) relative_end = full_duration;
    if (relative_start >= relative_end) {
        relative_start = 0.0;
        relative_end = full_duration;
    }

    StackAggregates aggregates = {0};
    bool aggregated = aggregate_samples_in_range(&run->samples,
                                                 run->start_time + relative_start,
                                                 run->start_time + relative_end,
                                                 &aggregates);
    qsort(aggregates.items, aggregates.count, sizeof(StackAggregate), compare_aggregates_desc);

    const char *range_status = "";
    if (run->samples.count > 0 && aggregates.sample_count == 0) {
        range_status = "No stack samples in the selected time range.";
    } else if (run->status) {
        range_status = run->status;
    }

    size_t max_items = aggregates.count < MAX_PROFILE_AGGREGATES ? aggregates.count : MAX_PROFILE_AGGREGATES;
    uint32_t frame_count = 0;
    for (size_t i = 0; i < max_items; i++) {
        if (aggregates.items[i].depth > UINT32_MAX - frame_count) {
            aggregates_free(&aggregates);
            send_text_response(fd, 500, "profile too large\n");
            return;
        }
        frame_count += (uint32_t)aggregates.items[i].depth;
    }

    uint32_t timeline_count = timeline_bucket_count_for_run(run);
    const uint32_t header_size = 140;
    const uint32_t timeline_row_size = 32;
    const uint32_t folded_row_size = 12;
    const uint32_t frame_row_size = 16;
    uint32_t timeline_offset = header_size;
    uint32_t folded_offset = timeline_offset + timeline_count * timeline_row_size;
    uint32_t frames_offset = folded_offset + (uint32_t)max_items * folded_row_size;
    uint32_t strings_offset = frames_offset + frame_count * frame_row_size;

    BinaryStringTable string_table = {.base_offset = strings_offset};
    StringBuilder folded_rows = {0};
    StringBuilder frame_rows = {0};
    uint32_t status_offset = 0, status_length = 0;
    uint32_t record_output_offset = 0, record_output_length = 0;
    uint32_t script_error_offset = 0, script_error_length = 0;
    uint32_t next_frame_index = 0;

    bool ok = aggregated &&
              binary_add_string(&string_table, range_status, &status_offset, &status_length) &&
              binary_add_string(&string_table, run->record_output, &record_output_offset, &record_output_length) &&
              binary_add_string(&string_table, run->script_error, &script_error_offset, &script_error_length);

    for (size_t i = 0; ok && i < max_items; i++) {
        StackAggregate *aggregate = &aggregates.items[i];
        ok = sb_append_u32(&folded_rows, aggregate->count) &&
             sb_append_u32(&folded_rows, (uint32_t)aggregate->depth) &&
             sb_append_u32(&folded_rows, next_frame_index);
        for (size_t j = 0; ok && j < aggregate->depth; j++) {
            ok = append_binary_frame_row(&frame_rows, &string_table, aggregate->frames[j]);
            next_frame_index++;
        }
    }

    StringBuilder binary = {0};
    ok = ok &&
         sb_append_binary_header(&binary, PROFILE_BINARY_PROFILE) &&
         sb_append_u64(&binary, run->id) &&
         sb_append_i32(&binary, run->pid) &&
         sb_append_i32(&binary, run->duration) &&
         sb_append_i32(&binary, run->frequency) &&
         sb_append_u32(&binary, run->parsed ? 1 : 0) &&
         sb_append_f64(&binary, run->have_cpu_milliseconds ? run->cpu_milliseconds : -1.0) &&
         sb_append_f64(&binary, relative_start) &&
         sb_append_f64(&binary, relative_end) &&
         sb_append_u32(&binary, aggregates.sample_count) &&
         sb_append_u32(&binary, (uint32_t)run->samples.count) &&
         sb_append_u32(&binary, (uint32_t)aggregates.count) &&
         sb_append_i32(&binary, wait_exit_status(run->record_status)) &&
         sb_append_i32(&binary, wait_exit_status(run->script_status)) &&
         sb_append_u32(&binary, status_offset) &&
         sb_append_u32(&binary, status_length) &&
         sb_append_u32(&binary, record_output_offset) &&
         sb_append_u32(&binary, record_output_length) &&
         sb_append_u32(&binary, script_error_offset) &&
         sb_append_u32(&binary, script_error_length) &&
         sb_append_u32(&binary, timeline_count) &&
         sb_append_u32(&binary, timeline_offset) &&
         sb_append_u32(&binary, (uint32_t)max_items) &&
         sb_append_u32(&binary, folded_offset) &&
         sb_append_u32(&binary, frame_count) &&
         sb_append_u32(&binary, frames_offset) &&
         sb_append_u32(&binary, strings_offset) &&
         sb_append_u32(&binary, (uint32_t)string_table.strings.length) &&
         append_timeline_binary_rows(&binary, run) &&
         sb_append_n(&binary, folded_rows.data, folded_rows.length) &&
         sb_append_n(&binary, frame_rows.data, frame_rows.length) &&
         sb_append_n(&binary, string_table.strings.data, string_table.strings.length);

    aggregates_free(&aggregates);
    free(folded_rows.data);
    free(frame_rows.data);
    free(string_table.strings.data);

    if (!ok) {
        free(binary.data);
        send_text_response(fd, 500, "out of memory\n");
        return;
    }
    send_binary_builder(fd, &binary);
}

static bool aggregate_samples_in_range(const StackSamples *samples,
                                       double start_time,
                                       double end_time,
                                       StackAggregates *aggregates) {
    bool ok = true;
    for (size_t i = 0; ok && i < samples->count; i++) {
        const StackSample *sample = &samples->items[i];
        if (sample->timestamp < start_time || sample->timestamp > end_time) continue;
        ok = aggregates_add_sample(aggregates, sample);
    }
    return ok;
}

static ProfileRun *install_completed_profile_run(ContainerContext container, uint64_t requested_id,
                                          int pid,
                                          int duration,
                                          int frequency,
                                          int record_status,
                                          int script_status,
                                          bool parsed,
                                          StackSamples samples,
                                          double profile_start_time,
                                          double profile_end_time,
                                          bool have_cpu_ticks_before,
                                          uint64_t cpu_ticks_before,
                                          bool have_cpu_ticks_after,
                                          uint64_t cpu_ticks_after,
                                          char *record_output,
                                          char *script_error) {
    long clock_ticks_per_second = sysconf(_SC_CLK_TCK);
    double cpu_milliseconds = 0.0;
    bool have_cpu_milliseconds = have_cpu_ticks_before &&
                                 have_cpu_ticks_after &&
                                 cpu_ticks_after >= cpu_ticks_before &&
                                 clock_ticks_per_second > 0;
    if (have_cpu_milliseconds) {
        cpu_milliseconds = ((double)(cpu_ticks_after - cpu_ticks_before) * 1000.0) / (double)clock_ticks_per_second;
    }

    double run_start_time = profile_start_time;
    double run_end_time = profile_end_time > profile_start_time ? profile_end_time : profile_start_time + (double)duration;
    if (samples.count > 0) {
        run_start_time = samples.items[0].timestamp;
        double elapsed = profile_end_time > profile_start_time ? profile_end_time - profile_start_time : (double)duration;
        run_end_time = run_start_time + elapsed;
        double last_sample_time = samples.items[samples.count - 1].timestamp;
        if (last_sample_time > run_end_time) run_end_time = last_sample_time;
    }

    const char *status = "";
    char status_buffer[512] = "";
    if (samples.count == 0) {
        if (perf_record_status_ok(record_status) && perf_script_status_ok(script_status)) {
            if (have_cpu_milliseconds) {
                snprintf(status_buffer,
                         sizeof(status_buffer),
                         "perf ran successfully, but the selected process used only %.2f ms of CPU during the recording.",
                         cpu_milliseconds);
                status = status_buffer;
            } else {
                status = "perf ran successfully, but the selected process did not run on CPU during the recording.";
            }
        } else if (!perf_record_status_ok(record_status) && record_output && record_output[0]) {
            char detail[384];
            copy_first_nonempty_line(record_output, detail, sizeof(detail));
            if (detail[0]) {
                snprintf(status_buffer, sizeof(status_buffer), "perf record failed: %s", detail);
                status = status_buffer;
            } else {
                status = "perf record failed.";
            }
        } else if (script_error && script_error[0]) {
            char detail[384];
            copy_first_nonempty_line(script_error, detail, sizeof(detail));
            if (detail[0]) {
                snprintf(status_buffer, sizeof(status_buffer), "perf script failed: %s", detail);
                status = status_buffer;
            } else {
                status = "perf completed, but could not decode stack samples.";
            }
        } else if ((!record_output || !record_output[0]) &&
                   (!script_error || !script_error[0])) {
            status = "perf completed, but did not produce stack samples.";
        } else {
            status = "perf completed, but did not produce stack samples.";
        }
    }
    if (!perf_record_status_ok(record_status)) {
        log_perf_command_failure("perf record failed", record_status, record_output);
    } else if (!perf_script_status_ok(script_status)) {
        log_perf_command_failure("perf script failed", script_status, script_error);
    } else if (!parsed && script_error && script_error[0]) {
        log_perf_diagnostic("perf script output was not decoded", script_error);
    }

    ProfileRun run = {
        .container = container,
        .id = requested_id ? requested_id : g_next_profile_id++,
        .pid = pid,
        .duration = duration,
        .frequency = frequency,
        .record_status = record_status,
        .script_status = script_status,
        .parsed = parsed,
        .have_cpu_milliseconds = have_cpu_milliseconds,
        .cpu_milliseconds = cpu_milliseconds,
        .start_time = run_start_time,
        .end_time = run_end_time,
        .status = strdup(status),
        .record_output = record_output,
        .script_error = script_error,
        .samples = samples
    };
    if (!run.status || !run.record_output || !run.script_error) {
        profile_run_free(&run);
        return NULL;
    }

    if (!profile_store_append(run)) {
        profile_run_free(&run);
        return NULL;
    }
    return profile_store_latest();
}

static void send_profile_capture(int fd, const char *query) {
#ifndef __linux__
    (void)query;
    send_text_response(fd, 500, "Linux perf profiling is only available on Linux.\n");
#else
    char value[64];
    if (!query_value(query, "pid", value, sizeof(value))) {
        send_text_response(fd, 400, "missing pid\n");
        return;
    }
    int pid = atoi(value);
    if (pid <= 0) {
        send_text_response(fd, 400, "invalid pid\n");
        return;
    }
    int duration = 5;
    if (query_value(query, "duration", value, sizeof(value))) duration = atoi(value);
    if (duration < 1) duration = 1;
    if (duration > 30) duration = 30;
    int frequency = 99;
    if (query_value(query, "frequency", value, sizeof(value))) frequency = atoi(value);
    if (frequency < 19) frequency = 19;
    if (frequency > MAX_PROFILE_FREQUENCY) frequency = MAX_PROFILE_FREQUENCY;

    char perf_error[1024];
    if (!cached_perf_ready(perf_error, sizeof(perf_error))) {
        log_perf_diagnostic("perf availability check failed", perf_error);
        send_text_response(fd, 500, perf_error[0] ? perf_error : "perf is not installed or is not usable.\n");
        return;
    }
    const char *perf = g_perf_status_path[0] ? g_perf_status_path : find_perf_binary();
    char temp_template[] = "/tmp/outer-profile-XXXXXX";
    char *temp_dir = mkdtemp(temp_template);
    if (!temp_dir) {
        send_text_response(fd, 500, "failed to create temp directory\n");
        return;
    }
    ContainerContext container = container_for_pid(pid);
    char perf_data[PATH_MAX], record_log[PATH_MAX], script_text[PATH_MAX], script_err[PATH_MAX];
    snprintf(perf_data, sizeof(perf_data), "%s/perf.data", temp_dir);
    snprintf(record_log, sizeof(record_log), "%s/record.log", temp_dir);
    snprintf(script_text, sizeof(script_text), "%s/script.txt", temp_dir);
    snprintf(script_err, sizeof(script_err), "%s/script.err", temp_dir);

    uint64_t cpu_ticks_before = 0;
    uint64_t cpu_ticks_after = 0;
    bool have_cpu_ticks_before = read_process_cpu_ticks(pid, &cpu_ticks_before);
    double profile_start_time = monotonic_seconds();

    char command[PATH_MAX * 4];
    snprintf(command, sizeof(command),
             "'%s' record --namespaces -e cpu-clock -F %d -g --call-graph fp -p %d -o '%s' -- sleep %d > '%s' 2>&1",
             perf, frequency, pid, perf_data, duration, record_log);
    int record_status = system(command);
    double profile_end_time = monotonic_seconds();
    bool have_cpu_ticks_after = read_process_cpu_ticks(pid, &cpu_ticks_after);
    snprintf(command, sizeof(command),
             "'%s' script -i '%s' > '%s' 2> '%s'",
             perf, perf_data, script_text, script_err);
    int script_status = system(command);

    StackSamples samples = {0};
    bool parsed = parse_perf_script_file(script_text, &samples);
    double run_start_time = profile_start_time;
    double run_end_time = profile_end_time > profile_start_time ? profile_end_time : profile_start_time + (double)duration;
    if (samples.count > 0) {
        run_start_time = samples.items[0].timestamp;
        run_end_time = run_start_time + (double)duration;
        double last_sample_time = samples.items[samples.count - 1].timestamp;
        if (last_sample_time > run_end_time) run_end_time = last_sample_time;
    }
    char *record_output = read_whole_file_or_empty(record_log);
    char *script_error = read_whole_file_or_empty(script_err);

    ProfileRun *run = install_completed_profile_run(container, 0,
                                                    pid,
                                                    duration,
                                                    frequency,
                                                    record_status,
                                                    script_status,
                                                    parsed,
                                                    samples,
                                                    run_start_time,
                                                    run_end_time,
                                                    have_cpu_ticks_before,
                                                    cpu_ticks_before,
                                                    have_cpu_ticks_after,
                                                    cpu_ticks_after,
                                                    record_output,
                                                    script_error);
    if (!run) {
        cleanup_temp_dir(temp_dir);
        send_text_response(fd, 500, "out of memory\n");
        return;
    }

    cleanup_temp_dir(temp_dir);
    send_profile_response_binary(fd, run, 0.0, (double)duration);
#endif
}

static void send_recording_status(int fd) {
#ifndef __linux__
    send_text_response(fd, 500, "Linux perf profiling is only available on Linux.\n");
#else
    double elapsed = g_recording.active ? monotonic_seconds() - g_recording.start_time : 0.0;
    send_recording_binary(fd, g_recording.active, g_recording.id, g_recording.pid, g_recording.frequency, elapsed);
#endif
}

static void send_profile_start(int fd, const char *query) {
#ifndef __linux__
    (void)query;
    send_text_response(fd, 500, "Linux perf profiling is only available on Linux.\n");
#else
    if (g_recording.active) {
        send_text_response(fd, 400, "recording already active\n");
        return;
    }
    char value[64];
    if (!query_value(query, "pid", value, sizeof(value))) {
        send_text_response(fd, 400, "missing pid\n");
        return;
    }
    int pid = atoi(value);
    if (pid <= 0) {
        send_text_response(fd, 400, "invalid pid\n");
        return;
    }
    int frequency = MAX_PROFILE_FREQUENCY;
    if (query_value(query, "frequency", value, sizeof(value))) frequency = atoi(value);
    if (frequency < 19) frequency = 19;
    if (frequency > MAX_PROFILE_FREQUENCY) frequency = MAX_PROFILE_FREQUENCY;
    char perf_path[PATH_MAX];
    if (query_value(query, "perfPath", perf_path, sizeof(perf_path)) && perf_path[0]) {
        snprintf(g_perf_path, sizeof(g_perf_path), "%s", perf_path);
    }

    char temp_template[] = "/tmp/outer-profile-XXXXXX";
    char *temp_dir = mkdtemp(temp_template);
    if (!temp_dir) {
        send_text_response(fd, 500, "failed to create temp directory\n");
        return;
    }

    RecordingRun recording = {0};
    recording.active = true;
    recording.id = g_next_profile_id++;
    recording.pid = pid;
    recording.container = container_for_pid(pid);
    char expected_start[32], expected_container[128];
    if ((query_value(query, "startTime", expected_start, sizeof(expected_start)) &&
         strtoull(expected_start, NULL, 10) != container_process_start(pid)) ||
        (query_value(query, "container", expected_container, sizeof(expected_container)) &&
         strcmp(expected_container, recording.container.id))) {
        cleanup_temp_dir(temp_dir);
        send_text_response(fd, 409, "The selected process has exited or changed. Refresh the process list.\n");
        return;
    }
    recording.frequency = frequency;
    recording.start_time = monotonic_seconds();
    recording.have_cpu_ticks_before = read_process_cpu_ticks(pid, &recording.cpu_ticks_before);
    snprintf(recording.temp_dir, sizeof(recording.temp_dir), "%s", temp_dir);
    snprintf(recording.perf_data, sizeof(recording.perf_data), "%s/perf.data", temp_dir);
    snprintf(recording.record_log, sizeof(recording.record_log), "%s/record.log", temp_dir);
    snprintf(recording.script_text, sizeof(recording.script_text), "%s/script.txt", temp_dir);
    snprintf(recording.script_err, sizeof(recording.script_err), "%s/script.err", temp_dir);

    char perf_error[1024];
    if (!cached_perf_ready(perf_error, sizeof(perf_error))) {
        log_perf_diagnostic("perf availability check failed", perf_error);
        cleanup_temp_dir(temp_dir);
        send_text_response(fd, 500, perf_error[0] ? perf_error : "perf is not installed or is not usable.\n");
        return;
    }
    const char *perf = g_perf_status_path[0] ? g_perf_status_path : find_perf_binary();
    snprintf(recording.perf_path, sizeof(recording.perf_path), "%s", perf);
    char frequency_text[32], pid_text[32];
    snprintf(frequency_text, sizeof(frequency_text), "%d", frequency);
    snprintf(pid_text, sizeof(pid_text), "%d", pid);

    pid_t child = fork();
    if (child < 0) {
        cleanup_temp_dir(temp_dir);
        send_text_response(fd, 500, "failed to start perf\n");
        return;
    }
    if (child == 0) {
        setpgid(0, 0);
        int log_fd = open(recording.record_log, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (log_fd >= 0) {
            dup2(log_fd, STDOUT_FILENO);
            dup2(log_fd, STDERR_FILENO);
            if (log_fd > STDERR_FILENO) close(log_fd);
        }
        execlp(recording.perf_path,
               recording.perf_path,
               "record",
               "--namespaces",
               "-e", "cpu-clock",
               "-F", frequency_text,
               "-g",
               "--call-graph", "fp",
               "-p", pid_text,
               "-o", recording.perf_data,
               (char *)NULL);
        _exit(127);
    }
    setpgid(child, child);
    recording.child_pid = child;
    g_recording = recording;

    send_recording_binary(fd, true, g_recording.id, g_recording.pid, g_recording.frequency, 0.0);
#endif
}

static int stop_recording_child(pid_t child) {
    int status = 0;
    pid_t waited = waitpid(child, &status, WNOHANG);
    if (waited == child) return status;

    kill(-child, SIGINT);
    for (int i = 0; i < 80; i++) {
        waited = waitpid(child, &status, WNOHANG);
        if (waited == child) return status;
        usleep(50000);
    }

    kill(-child, SIGTERM);
    for (int i = 0; i < 40; i++) {
        waited = waitpid(child, &status, WNOHANG);
        if (waited == child) return status;
        usleep(50000);
    }

    kill(-child, SIGKILL);
    waitpid(child, &status, 0);
    return status;
}

static void send_profile_stop(int fd) {
#ifndef __linux__
    send_text_response(fd, 500, "Linux perf profiling is only available on Linux.\n");
#else
    if (!g_recording.active) {
        send_text_response(fd, 400, "no recording active\n");
        return;
    }

    RecordingRun recording = g_recording;
    memset(&g_recording, 0, sizeof(g_recording));

    double profile_end_time = monotonic_seconds();
    uint64_t cpu_ticks_after = 0;
    bool have_cpu_ticks_after = read_process_cpu_ticks(recording.pid, &cpu_ticks_after);
    int record_status = stop_recording_child(recording.child_pid);

    const char *perf = recording.perf_path[0] ? recording.perf_path : find_perf_binary();
    char command[PATH_MAX * 4];
    snprintf(command, sizeof(command),
             "'%s' script -i '%s' > '%s' 2> '%s'",
             perf, recording.perf_data, recording.script_text, recording.script_err);
    int script_status = system(command);

    StackSamples samples = {0};
    bool parsed = parse_perf_script_file(recording.script_text, &samples);
    char *record_output = read_whole_file_or_empty(recording.record_log);
    char *script_error = read_whole_file_or_empty(recording.script_err);
    int duration = (int)ceil(profile_end_time - recording.start_time);
    if (duration < 1) duration = 1;

    ProfileRun *run = install_completed_profile_run(recording.container, recording.id,
                                                    recording.pid,
                                                    duration,
                                                    recording.frequency,
                                                    record_status,
                                                    script_status,
                                                    parsed,
                                                    samples,
                                                    recording.start_time,
                                                    profile_end_time,
                                                    recording.have_cpu_ticks_before,
                                                    recording.cpu_ticks_before,
                                                    have_cpu_ticks_after,
                                                    cpu_ticks_after,
                                                    record_output,
                                                    script_error);
    if (!run) {
        cleanup_temp_dir(recording.temp_dir);
        send_text_response(fd, 500, "out of memory\n");
        return;
    }

    cleanup_temp_dir(recording.temp_dir);
    send_profile_response_binary(fd, run, 0.0, profile_end_time - recording.start_time);
#endif
}

static void send_profile_range(int fd, const char *query) {
#ifndef __linux__
    (void)query;
    send_text_response(fd, 500, "Linux perf profiling is only available on Linux.\n");
#else
    if (g_profiles.count == 0) {
        send_text_response(fd, 404, "no profile captured\n");
        return;
    }
    char value[64];
    uint64_t profile_id = 0;
    if (query_value(query, "profileID", value, sizeof(value))) {
        profile_id = strtoull(value, NULL, 10);
    }
    ProfileRun *run = profile_id ? profile_store_find(profile_id) : profile_store_latest();
    if (!run) {
        send_text_response(fd, 404, "profile not found\n");
        return;
    }
    double start = 0.0;
    double end = run->end_time - run->start_time;
    if (query_value(query, "start", value, sizeof(value))) start = strtod(value, NULL);
    if (query_value(query, "end", value, sizeof(value))) end = strtod(value, NULL);

    send_profile_response_binary(fd, run, start, end);
#endif
}

static void send_profile_delete(int fd, const char *query) {
#ifndef __linux__
    (void)query;
    send_text_response(fd, 500, "Linux perf profiling is only available on Linux.\n");
#else
    char value[64];
    if (!query_value(query, "profileID", value, sizeof(value))) {
        send_text_response(fd, 400, "missing profileID\n");
        return;
    }
    uint64_t profile_id = strtoull(value, NULL, 10);
    if (profile_id == 0) {
        send_text_response(fd, 400, "invalid profileID\n");
        return;
    }
    if (!profile_store_delete(profile_id)) {
        send_text_response(fd, 404, "profile not found\n");
        return;
    }
    send_profile_list_binary(fd, query && strstr(query, "containers=1"));
#endif
}

static void handle_client(int fd) {
    char buffer[READ_BUFFER_SIZE + 1];
    ssize_t got = read(fd, buffer, READ_BUFFER_SIZE);
    if (got <= 0) return;
    buffer[got] = '\0';
    char *header_end = strstr(buffer, "\r\n\r\n");
    size_t request_header_length = header_end ? (size_t)(header_end + 4 - buffer) : (size_t)got;

    char method[8] = "";
    char target[2048] = "";
    if (sscanf(buffer, "%7s %2047s", method, target) != 2) {
        send_text_response(fd, 400, "bad request\n");
        return;
    }

    char *query = strchr(target, '?');
    if (query) *query++ = '\0';

    g_current_request_is_head = strcasecmp(method, "HEAD") == 0;

    if (strcasecmp(method, "GET") != 0 && strcasecmp(method, "HEAD") != 0 && strcasecmp(method, "POST") != 0) {
        send_text_response(fd, 400, "unsupported method\n");
    } else if (strcmp(target, "/") == 0 && !request_accepts_outerframe(buffer, request_header_length)) {
        send_web_file(fd, "index.html", "text/html; charset=utf-8", buffer, request_header_length,
                      !g_current_request_is_head);
    } else if (strcmp(target, "/web/app-icon.png") == 0 || strcmp(target, "/favicon.ico") == 0) {
        send_web_file(fd, "app-icon.png", "image/png", buffer, request_header_length, !g_current_request_is_head);
    } else if (strcmp(target, "/web/app.css") == 0) {
        send_web_file(fd, "app.css", "text/css; charset=utf-8", buffer, request_header_length,
                      !g_current_request_is_head);
    } else if (strcmp(target, "/web/app.js") == 0) {
        send_web_file(fd, "app.js", "text/javascript; charset=utf-8", buffer, request_header_length,
                      !g_current_request_is_head);
    } else if (strcmp(target, "/") == 0 || strcmp(target, "/index.outer") == 0) {
        send_outer_descriptor(fd, buffer, request_header_length, !g_current_request_is_head);
    } else if (strcmp(target, kBundleUrlPath) == 0) {
        send_text_response(fd, 200, "macos-arm\nmacos-x86\n");
    } else if (strcmp(target, kBundleUrlPathMacosArm) == 0) {
        send_bundle_file(fd, g_bundle_file_path_macos_arm,
                         buffer, request_header_length, !g_current_request_is_head);
    } else if (strcmp(target, kBundleUrlPathMacosX86) == 0) {
        send_bundle_file(fd, g_bundle_file_path_macos_x86,
                         buffer, request_header_length, !g_current_request_is_head);
    } else if (strcmp(target, "/api/processes") == 0) {
        send_processes_binary(fd, query && strstr(query, "containers=1"));
    } else if (strcmp(target, "/api/profile") == 0) {
        send_profile_capture(fd, query ? query : "");
    } else if (strcmp(target, "/api/profile/start") == 0) {
        send_profile_start(fd, query ? query : "");
    } else if (strcmp(target, "/api/profile/stop") == 0) {
        send_profile_stop(fd);
    } else if (strcmp(target, "/api/profile/status") == 0) {
        send_recording_status(fd);
    } else if (strcmp(target, "/api/profiles") == 0) {
        send_profile_list_binary(fd, query && strstr(query, "containers=1"));
    } else if (strcmp(target, "/api/profile/range") == 0) {
        send_profile_range(fd, query ? query : "");
    } else if (strcmp(target, "/api/profile/delete") == 0) {
        send_profile_delete(fd, query ? query : "");
    } else if (strcmp(target, "/api/perf") == 0) {
        char path[PATH_MAX] = "";
        if (query_value(query ? query : "", "path", path, sizeof(path))) {
            snprintf(g_perf_path, sizeof(g_perf_path), "%s", path);
        }
        send_perf_config_binary(fd);
    } else if (strcmp(target, "/api/file-picker") == 0) {
        send_file_picker_binary(fd, query ? query : "");
    } else {
        send_text_response(fd, 404, "not found\n");
    }
    g_current_request_is_head = false;
}

static int make_tcp_listener(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 64) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int make_unix_listener(const char *socket_path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    snprintf(address.sun_path, sizeof(address.sun_path), "%s", socket_path);
    unlink(socket_path);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 64) != 0) {
        close(fd);
        return -1;
    }
    chmod(socket_path, 0666);
    return fd;
}

static void default_socket_path(char *dst, size_t dst_size) {
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (!runtime || !runtime[0]) runtime = getenv("TMPDIR");
    if (!runtime || !runtime[0]) runtime = "/tmp";
    snprintf(dst, dst_size, "%s/%s", runtime, g_backend_label);
}

static int systemd_activated_listener(void) {
    const char *listen_pid = getenv("LISTEN_PID");
    const char *listen_fds = getenv("LISTEN_FDS");
    if (!listen_pid || !listen_fds) {
        return -1;
    }

    char *end = NULL;
    long pid = strtol(listen_pid, &end, 10);
    if (!end || *end != '\0' || pid != (long)getpid()) {
        return -1;
    }

    end = NULL;
    long fds = strtol(listen_fds, &end, 10);
    if (!end || *end != '\0' || fds < 1) {
        return -1;
    }

    unsetenv("LISTEN_PID");
    unsetenv("LISTEN_FDS");
    unsetenv("LISTEN_FDNAMES");
    g_systemd_socket_activation = true;
    return 3;
}

static void print_usage(const char *program) {
    fprintf(stderr, "Usage: %s [--port PORT | --socket-path PATH] [--label LABEL] [--bundles-dir DIR] [--web-root DIR]\n", program);
}

int main(int argc, char **argv) {
    container_start();
    int port = 0;
    const char *bundles_dir = "bundles";
    char socket_path[PATH_MAX] = "";

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--socket-path") == 0 && i + 1 < argc) {
            snprintf(socket_path, sizeof(socket_path), "%s", argv[++i]);
        } else if (strcmp(argv[i], "--label") == 0 && i + 1 < argc) {
            snprintf(g_backend_label, sizeof(g_backend_label), "%s", argv[++i]);
        } else if (strcmp(argv[i], "--bundles-dir") == 0 && i + 1 < argc) {
            bundles_dir = argv[++i];
        } else if (strcmp(argv[i], "--web-root") == 0 && i + 1 < argc) {
            snprintf(g_web_root, sizeof(g_web_root), "%s", argv[++i]);
        } else if ((strcmp(argv[i], "--api-socket-path") == 0 || strcmp(argv[i], "--icon-file") == 0) && i + 1 < argc) {
            i++;
        } else if (strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else {
            print_usage(argv[0]);
            return 2;
        }
    }

    snprintf(g_bundle_file_path_macos_arm, sizeof(g_bundle_file_path_macos_arm), "%s/%s", bundles_dir, kBundleFilePathMacosArm);
    snprintf(g_bundle_file_path_macos_x86, sizeof(g_bundle_file_path_macos_x86), "%s/%s", bundles_dir, kBundleFilePathMacosX86);
    if (!g_web_root[0]) snprintf(g_web_root, sizeof(g_web_root), "%s/../web", bundles_dir);
    refresh_perf_status();
    if (!g_perf_status_usable) {
        log_perf_diagnostic("perf startup check failed", g_perf_status_message);
    }

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = handle_shutdown_signal;
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGTERM, &action, NULL);
    signal(SIGPIPE, SIG_IGN);

    int listener = -1;
    if (port > 0) {
        listener = make_tcp_listener(port);
        if (listener < 0) {
            perror("listen tcp");
            return 1;
        }
        fprintf(stderr, "ProfileBackend listening on http://127.0.0.1:%d/\n", port);
    } else {
        if (!socket_path[0]) default_socket_path(socket_path, sizeof(socket_path));
        listener = systemd_activated_listener();
        if (listener >= 0) {
            fprintf(stderr, "ProfileBackend using systemd socket %s\n", socket_path);
        } else {
            listener = make_unix_listener(socket_path);
        }
        if (listener < 0) {
            perror("listen unix");
            return 1;
        }
        if (!g_systemd_socket_activation) {
            fprintf(stderr, "ProfileBackend listening on %s\n", socket_path);
        }
    }
    g_listener_fd = listener;

    while (!g_shutdown_requested) {
        struct pollfd pfd = {.fd = listener, .events = POLLIN};
        int ready = poll(&pfd, 1, 1000);
        if (ready < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (ready == 0) continue;
        int client = accept(listener, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) continue;
            break;
        }
        handle_client(client);
        close(client);
    }

    close(listener);
    if (socket_path[0] && !g_systemd_socket_activation) unlink(socket_path);
    return 0;
}
