#define main profile_backend_main
#include "../Backend/main.c"
#undef main
#include <assert.h>

static void clear_store(void) {
    if (g_profile_store_lock >= 0) close(g_profile_store_lock);
    g_profile_store_lock = -1;
    for (size_t i = 0; i < g_profiles.count; i++) profile_run_free(&g_profiles.items[i]);
    free(g_profiles.items); memset(&g_profiles, 0, sizeof(g_profiles)); g_next_profile_id = 1;
}
static ProfileRun fixture(uint64_t id) {
    ProfileRun r = {.id=id, .pid=42, .duration=4, .frequency=1000, .parsed=true,
        .have_cpu_milliseconds=true, .cpu_milliseconds=17.5, .start_time=100, .end_time=104,
        .status=strdup("saved"), .record_output=strdup("record output"), .script_error=strdup(""),
        .container={.id="docker:example", .name="Example", .local_pid=2}};
    r.samples.count = r.samples.capacity = 2; r.samples.items = calloc(2, sizeof(StackSample));
    for (size_t i = 0; i < 2; i++) {
        r.samples.items[i].timestamp = 100.25 + i * 2;
        r.samples.items[i].depth = 2; r.samples.items[i].frames = calloc(2, sizeof(char *));
        r.samples.items[i].frames[0] = strdup("main\tapp"); r.samples.items[i].frames[1] = strdup(i ? "work\tlib" : "sleep\tlib");
    }
    return r;
}
int main(void) {
    char directory[] = "/tmp/profile-storage-test-XXXXXX"; assert(mkdtemp(directory));
    assert(profile_store_open(directory));
    uint64_t id = profile_reserve_id(); assert(id == 1);
    assert(profile_store_append(fixture(id)));
    StringBuilder before={0}; assert(profile_store_encode(&before));
    clear_store(); assert(profile_store_open(directory));
    StringBuilder after={0}; assert(profile_store_encode(&after));
    assert(before.length == after.length && !memcmp(before.data, after.data, before.length));
    assert(g_profiles.items[0].samples.items[1].timestamp == 102.25);
    assert(!strcmp(g_profiles.items[0].container.name, "Example"));
    StackAggregates aggregate={0}; assert(aggregate_samples_in_range(&g_profiles.items[0].samples, 102, 103, &aggregate));
    assert(aggregate.sample_count == 1); aggregates_free(&aggregate);
    assert(!profile_store_decode((unsigned char *)before.data, before.length - 1));
    before.data[4]=99; assert(!profile_store_decode((unsigned char *)before.data,before.length));
    assert(g_profiles.count == 1);
    char saved_path[PATH_MAX]; strcpy(saved_path,g_profile_store_path);
    strcpy(g_profile_store_path,"/nonexistent/profile-test/recordings.bin");
    assert(!profile_store_delete(id)); assert(g_profiles.count == 1);
    strcpy(g_profile_store_path,saved_path);
    assert(profile_store_delete(id)); clear_store(); assert(profile_store_open(directory));
    assert(g_profiles.count == 0 && g_next_profile_id == 2);
    for (int i = 0; i < MAX_STORED_PROFILES + 1; i++) assert(profile_store_append(fixture(profile_reserve_id())));
    assert(g_profiles.count == MAX_STORED_PROFILES && g_profiles.items[0].id == 3);
    uint64_t next = g_next_profile_id; clear_store(); assert(profile_store_open(directory));
    assert(g_next_profile_id == next && g_profiles.count == MAX_STORED_PROFILES);
    assert(is_profile_document_path("/traces/2")); assert(is_profile_document_path("/"));
    assert(!is_profile_document_path("/traces/0")); assert(!is_profile_document_path("/traces/2/foo"));
    assert(!is_profile_document_path("/traces/18446744073709551616"));
    unlink(g_profile_store_path); clear_store();
    char lock_path[PATH_MAX]; snprintf(lock_path, sizeof(lock_path), "%s/recordings.lock", directory);
    unlink(lock_path); rmdir(directory); free(before.data); free(after.data);
    puts("PASS durable sample round-trip, filtering, deletion, ID continuity, retention, invalid files, and document routes");
}
