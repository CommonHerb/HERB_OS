/* Binary vs JSON equivalence test: load program, run, output state */
#include <stdio.h>
#include <stdlib.h>

extern void herb_init(void* arena, unsigned long long arena_size, void(*)(int,const char*));
extern int herb_load(const char* buf, unsigned long long len);
extern int herb_run(int max);
extern int herb_create(const char* name, const char* type, const char* container);
extern int herb_state(char* buf, int buf_size);

static void err_fn(int s, const char* m) { (void)s; (void)m; }

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "Usage: test_binary_equiv <file> [signals...]\n"); return 1; }
    FILE* f = fopen(argv[1], "rb");
    if (!f) { fprintf(stderr, "Cannot open %s\n", argv[1]); return 1; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    char* buf = (char*)malloc(sz + 1);
    fread(buf, 1, sz, f); buf[sz] = 0; fclose(f);

    void* arena = malloc(4*1024*1024);
    herb_init(arena, 4*1024*1024, err_fn);
    herb_load(buf, sz);
    herb_run(100);

    /* Process signal args: "name type container" */
    for (int i = 2; i < argc; i++) {
        char name[64], type[64], container[64];
        if (sscanf(argv[i], "%63s %63s %63s", name, type, container) == 3) {
            herb_create(name, type, container);
            herb_run(100);
        }
    }

    char state[32768];
    herb_state(state, sizeof(state));
    printf("%s", state);

    free(buf); free(arena);
    return 0;
}
