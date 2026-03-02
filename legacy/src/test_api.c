/* Test the new freestanding runtime APIs (herb_set_prop_int, herb_container_count, etc.) */
#include <stdio.h>
#include <stdlib.h>

extern void herb_init(void* arena, unsigned long long arena_size, void(*)(int,const char*));
extern int herb_load(const char* json, unsigned long long len);
extern int herb_run(int max);
extern int herb_create(const char* name, const char* type, const char* container);
extern int herb_set_prop_int(int entity_id, const char* property, long long value);
extern int herb_container_count(const char* container);
extern int herb_container_entity(const char* container, int idx);
extern const char* herb_entity_name(int entity_id);
extern long long herb_entity_prop_int(int entity_id, const char* property, long long default_val);
extern const char* herb_entity_location(int entity_id);
extern int herb_entity_total(void);
extern int herb_state(char* buf, int buf_size);

static char arena[4*1024*1024];
static void err_fn(int s, const char* m) { fprintf(stderr, "ERR(%d): %s\n", s, m); }

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "Usage: test_api <program.herb.json>\n"); return 1; }

    FILE* f = fopen(argv[1], "rb");
    if (!f) { fprintf(stderr, "Cannot open %s\n", argv[1]); return 1; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char* buf = (char*)malloc(sz+1);
    fread(buf, 1, sz, f);
    buf[sz] = 0;
    fclose(f);

    int pass = 0, fail = 0;
    #define CHECK(cond, msg) do { if (cond) { pass++; printf("  PASS: %s\n", msg); } else { fail++; printf("  FAIL: %s\n", msg); } } while(0)

    herb_init(arena, sizeof(arena), err_fn);
    herb_load(buf, sz);

    printf("=== Test 1: Boot ===\n");
    int ops = herb_run(100);
    printf("  boot_ops=%d\n", ops);
    CHECK(ops > 0, "boot produces ops");

    printf("\n=== Test 2: herb_container_count ===\n");
    int cpu_n = herb_container_count("CPU0");
    printf("  CPU0 count=%d\n", cpu_n);
    CHECK(cpu_n == 1, "one process running after boot");

    int ready_n = herb_container_count("READY_QUEUE");
    printf("  READY count=%d\n", ready_n);
    CHECK(ready_n >= 1, "some processes still ready");

    int bad = herb_container_count("NONEXISTENT");
    CHECK(bad == -1, "nonexistent container returns -1");

    printf("\n=== Test 3: herb_container_entity + herb_entity_name ===\n");
    int eid = herb_container_entity("CPU0", 0);
    CHECK(eid >= 0, "can get entity from CPU0");
    const char* name = herb_entity_name(eid);
    printf("  running process: %s\n", name);
    CHECK(name[0] != '?', "entity has a valid name");

    printf("\n=== Test 4: herb_entity_prop_int ===\n");
    long long pri = herb_entity_prop_int(eid, "priority", -1);
    printf("  priority=%lld\n", pri);
    CHECK(pri > 0, "running process has priority > 0");

    long long missing = herb_entity_prop_int(eid, "nonexistent", -999);
    CHECK(missing == -999, "missing property returns default");

    printf("\n=== Test 5: herb_entity_location ===\n");
    const char* loc = herb_entity_location(eid);
    printf("  location=%s\n", loc);
    CHECK(loc[0] == 'C' && loc[1] == 'P', "running process is in CPU0");

    printf("\n=== Test 6: herb_entity_total ===\n");
    int total = herb_entity_total();
    printf("  total entities=%d\n", total);
    CHECK(total >= 4, "at least 4 entities (4 processes)");

    printf("\n=== Test 7: herb_create + herb_set_prop_int ===\n");
    int new_eid = herb_create("test_p", "Process", "READY_QUEUE");
    CHECK(new_eid >= 0, "create returns valid entity id");

    int rc = herb_set_prop_int(new_eid, "priority", 99);
    CHECK(rc == 0, "set_prop_int returns 0");

    rc = herb_set_prop_int(new_eid, "time_slice", 5);
    CHECK(rc == 0, "set second property");

    long long new_pri = herb_entity_prop_int(new_eid, "priority", -1);
    CHECK(new_pri == 99, "property value reads back correctly");

    printf("\n=== Test 8: Created process gets scheduled ===\n");
    /* test_p has priority 99, higher than anything. It should get scheduled
       if we preempt the current running process (or if CPU0 is open). */
    /* Force preemption by draining time_slice, then reschedule */
    herb_set_prop_int(eid, "time_slice", 0);
    ops = herb_run(100);
    printf("  kill+schedule ops=%d\n", ops);

    loc = herb_entity_location(new_eid);
    printf("  test_p location=%s\n", loc);
    CHECK(loc[0] == 'C' && loc[1] == 'P', "highest-priority process gets scheduled");

    printf("\n=== Test 9: herb_set_prop_int updates existing ===\n");
    rc = herb_set_prop_int(new_eid, "priority", 1);
    CHECK(rc == 0, "update existing property");
    new_pri = herb_entity_prop_int(new_eid, "priority", -1);
    CHECK(new_pri == 1, "updated value reads back correctly");

    printf("\n=== RESULTS: %d passed, %d failed ===\n", pass, fail);
    free(buf);
    return fail > 0 ? 1 : 0;
}
