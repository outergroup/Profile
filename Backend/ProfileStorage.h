#ifndef PROFILE_STORAGE_H
#define PROFILE_STORAGE_H

#include <sys/file.h>

#define PROFILE_STORE_LIMIT (512u * 1024u * 1024u)
static char g_profile_store_path[PATH_MAX];
static int g_profile_store_lock = -1;

static uint32_t store_u32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static uint64_t store_u64(const unsigned char *p) {
    return store_u32(p) | (uint64_t)store_u32(p + 4) << 32;
}
static double store_double(const unsigned char *p) {
    uint64_t bits = store_u64(p); double value; memcpy(&value, &bits, 8); return value;
}
static void store_put32(StringBuilder *b, size_t at, uint32_t value) {
    for (int i = 0; i < 4; i++) b->data[at + i] = (char)(value >> (i * 8));
}
static void store_put64(StringBuilder *b, size_t at, uint64_t value) {
    for (int i = 0; i < 8; i++) b->data[at + i] = (char)(value >> (i * 8));
}
static void store_put_double(StringBuilder *b, size_t at, double value) {
    uint64_t bits; memcpy(&bits, &value, 8); store_put64(b, at, bits);
}
static bool store_space(StringBuilder *b, size_t length) {
    if (length > PROFILE_STORE_LIMIT || b->length > PROFILE_STORE_LIMIT - length) return false;
    static const char zeros[128] = {0};
    while (length) {
        size_t n = length < sizeof(zeros) ? length : sizeof(zeros);
        if (!sb_append_n(b, zeros, n)) return false;
        length -= n;
    }
    return true;
}
static bool store_string(StringBuilder *b, size_t ref, const char *value) {
    size_t length = value ? strlen(value) : 0;
    if (length > PROFILE_STORE_LIMIT || b->length > PROFILE_STORE_LIMIT - length) return false;
    store_put32(b, ref, (uint32_t)b->length);
    store_put32(b, ref + 4, (uint32_t)length);
    return !length || sb_append_n(b, value, length);
}
static bool profile_store_encode(StringBuilder *b) {
    size_t first = g_profiles.count > MAX_STORED_PROFILES ? g_profiles.count - MAX_STORED_PROFILES : 0;
    size_t count = g_profiles.count - first;
    if (!store_space(b, 32 + count * 128)) return false;
    memcpy(b->data, "PRFS", 4);
    store_put32(b, 4, 1); store_put64(b, 8, g_next_profile_id);
    store_put32(b, 16, (uint32_t)count); store_put32(b, 20, 32);
    for (size_t i = 0; i < count; i++) {
        const ProfileRun *r = &g_profiles.items[first + i]; size_t row = 32 + i * 128;
        store_put64(b, row, r->id); store_put32(b, row + 8, (uint32_t)r->pid);
        store_put32(b, row + 12, (uint32_t)r->duration); store_put32(b, row + 16, (uint32_t)r->frequency);
        store_put32(b, row + 20, (uint32_t)r->record_status); store_put32(b, row + 24, (uint32_t)r->script_status);
        store_put32(b, row + 28, (r->parsed ? 1 : 0) | (r->have_cpu_milliseconds ? 2 : 0));
        store_put_double(b, row + 32, r->cpu_milliseconds);
        store_put_double(b, row + 40, r->start_time); store_put_double(b, row + 48, r->end_time);
        store_put32(b, row + 56, (uint32_t)r->container.local_pid);
        if (r->samples.count > PROFILE_STORE_LIMIT / 16) return false;
        store_put32(b, row + 60, (uint32_t)r->samples.count);
        size_t samples = b->length; store_put32(b, row + 64, (uint32_t)samples);
        if (!store_space(b, r->samples.count * 16)) return false;
        for (size_t j = 0; j < r->samples.count; j++) {
            const StackSample *sample = &r->samples.items[j]; size_t at = samples + j * 16;
            if (sample->depth > MAX_STACK_DEPTH) return false;
            store_put_double(b, at, sample->timestamp); store_put32(b, at + 8, (uint32_t)sample->depth);
            size_t frames = b->length; store_put32(b, at + 12, (uint32_t)frames);
            if (!store_space(b, sample->depth * 8)) return false;
            for (size_t k = 0; k < sample->depth; k++) if (!store_string(b, frames + k * 8, sample->frames[k])) return false;
        }
        if (!store_string(b, row + 68, r->status) || !store_string(b, row + 76, r->record_output) ||
            !store_string(b, row + 84, r->script_error) || !store_string(b, row + 92, r->container.id) ||
            !store_string(b, row + 100, r->container.name)) return false;
    }
    store_put32(b, 24, (uint32_t)b->length);
    return true;
}
static bool store_span(size_t length, size_t offset, size_t count, size_t stride) {
    return offset <= length && count <= (length - offset) / stride;
}
static char *store_read_string(const unsigned char *b, size_t length, size_t ref) {
    size_t offset = store_u32(b + ref), size = store_u32(b + ref + 4);
    if (!store_span(length, offset, size, 1) || memchr(b + offset, 0, size)) return NULL;
    char *value = malloc(size + 1);
    if (value) { memcpy(value, b + offset, size); value[size] = 0; }
    return value;
}
static bool profile_store_decode(const unsigned char *b, size_t length) {
    if (length < 32 || length > PROFILE_STORE_LIMIT || memcmp(b, "PRFS", 4) || store_u32(b + 4) != 1 ||
        store_u32(b + 24) != length || !store_u64(b + 8)) return false;
    size_t count = store_u32(b + 16), rows = store_u32(b + 20);
    if (count > MAX_STORED_PROFILES || !store_span(length, rows, count, 128)) return false;
    ProfileStore loaded = { .items = calloc(count ? count : 1, sizeof(ProfileRun)), .count = count, .capacity = count };
    if (!loaded.items) return false;
    for (size_t i = 0; i < count; i++) {
        ProfileRun *r = &loaded.items[i]; const unsigned char *row = b + rows + i * 128;
        r->id = store_u64(row); r->pid = (int32_t)store_u32(row + 8);
        if (!r->id || r->id >= store_u64(b + 8)) goto fail;
        for (size_t j = 0; j < i; j++) if (loaded.items[j].id == r->id) goto fail;
        r->duration = (int32_t)store_u32(row + 12); r->frequency = (int32_t)store_u32(row + 16);
        r->record_status = (int32_t)store_u32(row + 20); r->script_status = (int32_t)store_u32(row + 24);
        r->parsed = (store_u32(row + 28) & 1) != 0; r->have_cpu_milliseconds = (store_u32(row + 28) & 2) != 0;
        r->cpu_milliseconds = store_double(row + 32); r->start_time = store_double(row + 40); r->end_time = store_double(row + 48);
        if (!isfinite(r->cpu_milliseconds) || !isfinite(r->start_time) || !isfinite(r->end_time)) goto fail;
        r->container.local_pid = (int32_t)store_u32(row + 56);
        r->status = store_read_string(b, length, rows + i * 128 + 68);
        r->record_output = store_read_string(b, length, rows + i * 128 + 76);
        r->script_error = store_read_string(b, length, rows + i * 128 + 84);
        char *id = store_read_string(b, length, rows + i * 128 + 92), *name = store_read_string(b, length, rows + i * 128 + 100);
        bool strings_ok = r->status && r->record_output && r->script_error && id && name && strlen(id) < sizeof(r->container.id) && strlen(name) < sizeof(r->container.name);
        if (strings_ok) { strcpy(r->container.id, id); strcpy(r->container.name, name); }
        free(id); free(name); if (!strings_ok) goto fail;
        size_t samples = store_u32(row + 64), n = store_u32(row + 60);
        if (!store_span(length, samples, n, 16)) goto fail;
        r->samples.items = calloc(n ? n : 1, sizeof(StackSample));
        if (!r->samples.items) goto fail;
        r->samples.count = r->samples.capacity = n;
        for (size_t j = 0; j < n; j++) {
            StackSample *sample = &r->samples.items[j]; const unsigned char *at = b + samples + j * 16;
            sample->timestamp = store_double(at); size_t depth = store_u32(at + 8), frames = store_u32(at + 12);
            if (!isfinite(sample->timestamp) || depth > MAX_STACK_DEPTH || !store_span(length, frames, depth, 8)) goto fail;
            sample->frames = calloc(depth ? depth : 1, sizeof(char *));
            if (!sample->frames) goto fail;
            sample->depth = depth;
            for (size_t k = 0; k < depth; k++) if (!(sample->frames[k] = store_read_string(b, length, frames + k * 8))) goto fail;
        }
    }
    g_profiles = loaded; g_next_profile_id = store_u64(b + 8); return true;
fail:
    for (size_t i = 0; i < count; i++) profile_run_free(&loaded.items[i]);
    free(loaded.items); return false;
}
static bool profile_store_save(void) {
    StringBuilder binary = {0};
    if (!profile_store_encode(&binary)) { free(binary.data); errno = EFBIG; perror("encode recordings"); return false; }
    char temp[PATH_MAX];
    if (snprintf(temp, sizeof(temp), "%s.XXXXXX", g_profile_store_path) >= (int)sizeof(temp)) { free(binary.data); return false; }
    int fd = mkstemp(temp);
    bool ok = fd >= 0 && queue_all(fd, binary.data, binary.length) && fsync(fd) == 0;
    if (fd >= 0 && close(fd) != 0) ok = false;
    free(binary.data);
    if (ok) ok = rename(temp, g_profile_store_path) == 0;
    if (!ok) { perror("save recordings"); unlink(temp); return false; }
    char directory[PATH_MAX]; snprintf(directory, sizeof(directory), "%s", g_profile_store_path);
    char *slash = strrchr(directory, '/'); if (slash) *slash = 0;
    int dir = open(directory, O_RDONLY | O_DIRECTORY);
    if (dir >= 0) { if (fsync(dir) != 0) perror("sync recordings directory"); close(dir); }
    return true;
}
static bool profile_store_open(const char *directory) {
    char path[PATH_MAX];
    if (snprintf(path, sizeof(path), "%s", directory) >= (int)sizeof(path)) return false;
    for (char *p = path + 1; ; p++) {
        if (*p != '/' && *p != 0) continue;
        char saved = *p; *p = 0;
        if (mkdir(path, 0700) != 0 && errno != EEXIST) return false;
        *p = saved; if (!saved) break;
    }
    if (snprintf(g_profile_store_path, sizeof(g_profile_store_path), "%s/recordings.bin", directory) >= (int)sizeof(g_profile_store_path)) return false;
    char lock_path[PATH_MAX];
    if (snprintf(lock_path, sizeof(lock_path), "%s/recordings.lock", directory) >= (int)sizeof(lock_path)) return false;
    g_profile_store_lock = open(lock_path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (g_profile_store_lock < 0 || flock(g_profile_store_lock, LOCK_EX | LOCK_NB) != 0) {
        perror("lock recordings");
        if (g_profile_store_lock >= 0) close(g_profile_store_lock);
        g_profile_store_lock = -1;
        return false;
    }
    FILE *file = fopen(g_profile_store_path, "rb");
    if (!file) return errno == ENOENT && profile_store_save();
    struct stat st;
    if (fstat(fileno(file), &st) != 0 || st.st_size < 32 || st.st_size > PROFILE_STORE_LIMIT) { fclose(file); return false; }
    unsigned char *bytes = malloc((size_t)st.st_size);
    bool ok = bytes && fread(bytes, 1, (size_t)st.st_size, file) == (size_t)st.st_size && profile_store_decode(bytes, (size_t)st.st_size);
    free(bytes); fclose(file); return ok;
}
static uint64_t profile_reserve_id(void) {
    if (g_next_profile_id == UINT64_MAX) return 0;
    uint64_t id = g_next_profile_id++;
    if (!profile_store_save()) { g_next_profile_id--; return 0; }
    return id;
}
#endif
