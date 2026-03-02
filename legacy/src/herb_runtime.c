/*
 * HERB Native Runtime
 * Session 19 — The Kernel Foundation
 *
 * This is NOT a compiler. This is a native engine that executes HERB rules.
 * Rules are data. The engine interprets them at native speed.
 *
 * Core insight: HERB doesn't need compilation because it has no complexity
 * that makes compilers hard. No call stack, no register allocation, no
 * control flow. Just: store facts, match patterns, loop until done.
 *
 * This file is the foundation of the HERB kernel. An OS is:
 * - World state (processes, files, devices as facts)
 * - Rules (scheduling policy, permissions, event handlers)
 * - Derivation (tick the system forward)
 *
 * REPRESENTATION:
 *
 * Values are integers. Atoms get interned at load time:
 *   "hero" -> 0, "hp" -> 1, "location" -> 2, etc.
 * This makes comparison O(1) and storage 4 bytes per value.
 *
 * Facts are 3 integers: (subject, relation, object).
 * 12 bytes per fact. Cache-friendly. No pointers, no indirection.
 *
 * Patterns are 3 integers where -1 means "variable slot".
 * Pattern (?, is_a, person) becomes (-1, 1, 2) if is_a=1, person=2.
 *
 * Rules are: input patterns + output template.
 * No guards, no retractions, no deferred — those are policy layers
 * that can be added later. The core is just pattern -> assert.
 *
 * Indices use sorted arrays + binary search for predictable performance.
 * Hash tables are faster on average but have worst-case spikes.
 * For a kernel, predictable > fast-average.
 *
 * MEMORY MODEL:
 *
 * Everything is in contiguous arrays. No malloc during derivation.
 * Pre-allocate fact array, grow only when needed (doubling).
 * This is critical for kernel use — no allocator pressure during ticks.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

/* ============================================================
 * CONFIGURATION
 * ============================================================ */

#define INITIAL_FACTS 8192
#define INITIAL_RULES 64
#define MAX_PATTERNS_PER_RULE 8
#define MAX_BINDINGS 8192
#define HASH_SIZE 16384

/* Variable slot marker — any value < 0 is a variable */
#define VAR(n) (-(n) - 1)    /* VAR(0) = -1, VAR(1) = -2, etc. */
#define IS_VAR(v) ((v) < 0)
#define VAR_INDEX(v) (-(v) - 1)

/* ============================================================
 * DATA STRUCTURES
 * ============================================================ */

/* A fact is three integers. That's it. */
typedef struct {
    int s;  /* subject */
    int r;  /* relation */
    int o;  /* object */
} Fact;

/* A pattern is three integers. Negative = variable slot. */
typedef struct {
    int s;
    int r;
    int o;
} Pattern;

/* A rule is: patterns to match, template to assert. */
typedef struct {
    int pattern_count;
    Pattern patterns[MAX_PATTERNS_PER_RULE];
    Pattern template;
} Rule;

/* Binding: maps variable indices to values during matching. */
typedef struct {
    int values[MAX_PATTERNS_PER_RULE * 3];  /* Max 3 vars per pattern */
    int bound[MAX_PATTERNS_PER_RULE * 3];   /* 1 if bound, 0 if not */
} Binding;

/* The world: facts + rules + index. */
typedef struct {
    /* Facts */
    Fact* facts;
    int fact_count;
    int fact_capacity;

    /* Rules */
    Rule* rules;
    int rule_count;
    int rule_capacity;

    /* Index: hash table for (s,r,o) existence check */
    int* sro_hash;  /* -1 if empty, fact index if present */

    /* Index: by (relation, object) for pattern (?x, R, O) */
    int* ro_head;   /* Head of linked list for each (r,o) hash */
    int* ro_next;   /* Next pointer for each fact */

    /* Index: by (subject, relation) for pattern (S, R, ?x) */
    int* sr_head;
    int* sr_next;

    /* Statistics */
    int derivation_iterations;
    int facts_derived;
} World;

/* ============================================================
 * HASH FUNCTIONS
 * ============================================================ */

static inline uint32_t hash2(int a, int b) {
    uint32_t h = 2166136261u;
    h = (h * 16777619u) ^ (uint32_t)a;
    h = (h * 16777619u) ^ (uint32_t)b;
    return h % HASH_SIZE;
}

static inline uint32_t hash3(int a, int b, int c) {
    uint32_t h = 2166136261u;
    h = (h * 16777619u) ^ (uint32_t)a;
    h = (h * 16777619u) ^ (uint32_t)b;
    h = (h * 16777619u) ^ (uint32_t)c;
    return h % HASH_SIZE;
}

/* ============================================================
 * WORLD OPERATIONS
 * ============================================================ */

World* world_new(void) {
    World* w = malloc(sizeof(World));

    w->fact_capacity = INITIAL_FACTS;
    w->fact_count = 0;
    w->facts = malloc(sizeof(Fact) * w->fact_capacity);

    w->rule_capacity = INITIAL_RULES;
    w->rule_count = 0;
    w->rules = malloc(sizeof(Rule) * w->rule_capacity);

    /* Initialize indices */
    w->sro_hash = malloc(sizeof(int) * HASH_SIZE);
    w->ro_head = malloc(sizeof(int) * HASH_SIZE);
    w->sr_head = malloc(sizeof(int) * HASH_SIZE);
    w->ro_next = malloc(sizeof(int) * w->fact_capacity);
    w->sr_next = malloc(sizeof(int) * w->fact_capacity);

    for (int i = 0; i < HASH_SIZE; i++) {
        w->sro_hash[i] = -1;
        w->ro_head[i] = -1;
        w->sr_head[i] = -1;
    }

    w->derivation_iterations = 0;
    w->facts_derived = 0;

    return w;
}

void world_free(World* w) {
    free(w->facts);
    free(w->rules);
    free(w->sro_hash);
    free(w->ro_head);
    free(w->sr_head);
    free(w->ro_next);
    free(w->sr_next);
    free(w);
}

/* Check if fact exists. O(1) average via hash. */
int world_exists(World* w, int s, int r, int o) {
    uint32_t h = hash3(s, r, o);
    int probes = 0;

    while (w->sro_hash[h] >= 0 && probes < HASH_SIZE) {
        int idx = w->sro_hash[h];
        Fact* f = &w->facts[idx];
        if (f->s == s && f->r == r && f->o == o) {
            return 1;
        }
        h = (h + 1) % HASH_SIZE;
        probes++;
    }
    return 0;
}

/* Assert a fact. Returns 1 if new, 0 if exists. */
int world_assert(World* w, int s, int r, int o) {
    /* Check existence first */
    if (world_exists(w, s, r, o)) {
        return 0;
    }

    /* Grow arrays if needed */
    if (w->fact_count >= w->fact_capacity) {
        w->fact_capacity *= 2;
        w->facts = realloc(w->facts, sizeof(Fact) * w->fact_capacity);
        w->ro_next = realloc(w->ro_next, sizeof(int) * w->fact_capacity);
        w->sr_next = realloc(w->sr_next, sizeof(int) * w->fact_capacity);
    }

    /* Add fact */
    int idx = w->fact_count++;
    w->facts[idx].s = s;
    w->facts[idx].r = r;
    w->facts[idx].o = o;

    /* Update SRO hash (linear probing) */
    uint32_t h = hash3(s, r, o);
    while (w->sro_hash[h] >= 0) {
        h = (h + 1) % HASH_SIZE;
    }
    w->sro_hash[h] = idx;

    /* Update RO linked list */
    uint32_t hro = hash2(r, o);
    w->ro_next[idx] = w->ro_head[hro];
    w->ro_head[hro] = idx;

    /* Update SR linked list */
    uint32_t hsr = hash2(s, r);
    w->sr_next[idx] = w->sr_head[hsr];
    w->sr_head[hsr] = idx;

    return 1;
}

/* Add a rule. */
void world_add_rule(World* w, int pattern_count, Pattern* patterns, Pattern template) {
    if (w->rule_count >= w->rule_capacity) {
        w->rule_capacity *= 2;
        w->rules = realloc(w->rules, sizeof(Rule) * w->rule_capacity);
    }

    Rule* rule = &w->rules[w->rule_count++];
    rule->pattern_count = pattern_count;
    for (int i = 0; i < pattern_count; i++) {
        rule->patterns[i] = patterns[i];
    }
    rule->template = template;
}

/* ============================================================
 * PATTERN MATCHING
 * ============================================================ */

/* Try to match a pattern against a fact, extending bindings.
 * Returns 1 if match succeeds, 0 if fails. */
static int match_pattern(Pattern* p, Fact* f, Binding* b) {
    /* Check/bind subject */
    if (IS_VAR(p->s)) {
        int vi = VAR_INDEX(p->s);
        if (b->bound[vi]) {
            if (b->values[vi] != f->s) return 0;
        } else {
            b->values[vi] = f->s;
            b->bound[vi] = 1;
        }
    } else {
        if (p->s != f->s) return 0;
    }

    /* Check/bind relation */
    if (IS_VAR(p->r)) {
        int vi = VAR_INDEX(p->r);
        if (b->bound[vi]) {
            if (b->values[vi] != f->r) return 0;
        } else {
            b->values[vi] = f->r;
            b->bound[vi] = 1;
        }
    } else {
        if (p->r != f->r) return 0;
    }

    /* Check/bind object */
    if (IS_VAR(p->o)) {
        int vi = VAR_INDEX(p->o);
        if (b->bound[vi]) {
            if (b->values[vi] != f->o) return 0;
        } else {
            b->values[vi] = f->o;
            b->bound[vi] = 1;
        }
    } else {
        if (p->o != f->o) return 0;
    }

    return 1;
}

/* Resolve a pattern element using bindings. */
static int resolve(int v, Binding* b) {
    if (IS_VAR(v)) {
        return b->values[VAR_INDEX(v)];
    }
    return v;
}

/* ============================================================
 * RULE APPLICATION (THE CORE)
 * ============================================================ */

/* Bindings stack for recursive matching. */
typedef struct {
    Binding bindings[MAX_BINDINGS];
    int count;
} BindingStack;

/* Recursive pattern matching with backtracking. */
static void match_patterns_recursive(
    World* w,
    Rule* rule,
    int pattern_idx,
    Binding* current,
    BindingStack* results
) {
    if (pattern_idx >= rule->pattern_count) {
        /* All patterns matched — save this binding */
        if (results->count < MAX_BINDINGS) {
            results->bindings[results->count++] = *current;
        }
        return;
    }

    Pattern* p = &rule->patterns[pattern_idx];

    /* Resolve any bound variables in the pattern */
    int s = IS_VAR(p->s) && current->bound[VAR_INDEX(p->s)] ?
            current->values[VAR_INDEX(p->s)] : p->s;
    int r = IS_VAR(p->r) && current->bound[VAR_INDEX(p->r)] ?
            current->values[VAR_INDEX(p->r)] : p->r;
    int o = IS_VAR(p->o) && current->bound[VAR_INDEX(p->o)] ?
            current->values[VAR_INDEX(p->o)] : p->o;

    /* Choose iteration strategy based on what's bound */
    if (!IS_VAR(r) && !IS_VAR(o)) {
        /* Use RO index: iterate facts with (?, r, o) */
        uint32_t h = hash2(r, o);
        for (int idx = w->ro_head[h]; idx >= 0; idx = w->ro_next[idx]) {
            Fact* f = &w->facts[idx];
            if (f->r == r && f->o == o) {
                Binding next = *current;
                if (match_pattern(p, f, &next)) {
                    match_patterns_recursive(w, rule, pattern_idx + 1, &next, results);
                }
            }
        }
    } else if (!IS_VAR(s) && !IS_VAR(r)) {
        /* Use SR index: iterate facts with (s, r, ?) */
        uint32_t h = hash2(s, r);
        for (int idx = w->sr_head[h]; idx >= 0; idx = w->sr_next[idx]) {
            Fact* f = &w->facts[idx];
            if (f->s == s && f->r == r) {
                Binding next = *current;
                if (match_pattern(p, f, &next)) {
                    match_patterns_recursive(w, rule, pattern_idx + 1, &next, results);
                }
            }
        }
    } else {
        /* Full scan */
        for (int idx = 0; idx < w->fact_count; idx++) {
            Fact* f = &w->facts[idx];
            Binding next = *current;
            if (match_pattern(p, f, &next)) {
                match_patterns_recursive(w, rule, pattern_idx + 1, &next, results);
            }
        }
    }
}

/* Apply a single rule. Returns number of new facts derived. */
static int apply_rule(World* w, Rule* rule) {
    BindingStack results;
    results.count = 0;

    Binding initial;
    memset(&initial, 0, sizeof(Binding));

    /* Find all matching bindings */
    match_patterns_recursive(w, rule, 0, &initial, &results);

    /* Assert template for each binding */
    int derived = 0;
    for (int i = 0; i < results.count; i++) {
        Binding* b = &results.bindings[i];
        int s = resolve(rule->template.s, b);
        int r = resolve(rule->template.r, b);
        int o = resolve(rule->template.o, b);

        derived += world_assert(w, s, r, o);
    }

    return derived;
}

/* ============================================================
 * DERIVATION (THE LOOP)
 * ============================================================ */

/* Derive to fixpoint: apply all rules until no new facts. */
int world_derive(World* w, int max_iterations) {
    int total = 0;
    int iteration = 0;

    while (iteration < max_iterations) {
        int derived = 0;

        for (int i = 0; i < w->rule_count; i++) {
            derived += apply_rule(w, &w->rules[i]);
        }

        if (derived == 0) {
            break;  /* Fixpoint */
        }

        total += derived;
        iteration++;
    }

    w->derivation_iterations = iteration;
    w->facts_derived = total;

    return total;
}

/* ============================================================
 * SYMBOL TABLE (for human-readable I/O)
 * ============================================================ */

#define MAX_SYMBOLS 1024
#define MAX_SYMBOL_LEN 64

typedef struct {
    char names[MAX_SYMBOLS][MAX_SYMBOL_LEN];
    int count;
} SymbolTable;

SymbolTable* symbols_new(void) {
    SymbolTable* st = malloc(sizeof(SymbolTable));
    st->count = 0;
    return st;
}

void symbols_free(SymbolTable* st) {
    free(st);
}

int symbols_intern(SymbolTable* st, const char* name) {
    /* Check if exists */
    for (int i = 0; i < st->count; i++) {
        if (strcmp(st->names[i], name) == 0) {
            return i;
        }
    }
    /* Add new */
    if (st->count < MAX_SYMBOLS) {
        strncpy(st->names[st->count], name, MAX_SYMBOL_LEN - 1);
        st->names[st->count][MAX_SYMBOL_LEN - 1] = '\0';
        return st->count++;
    }
    return -1;  /* Table full */
}

const char* symbols_name(SymbolTable* st, int id) {
    if (id >= 0 && id < st->count) {
        return st->names[id];
    }
    return "?";
}

/* ============================================================
 * PRINTING
 * ============================================================ */

void world_print(World* w, SymbolTable* st) {
    printf("=== World (%d facts, %d rules) ===\n", w->fact_count, w->rule_count);
    for (int i = 0; i < w->fact_count; i++) {
        Fact* f = &w->facts[i];
        printf("  (%s %s %s)\n",
            symbols_name(st, f->s),
            symbols_name(st, f->r),
            symbols_name(st, f->o));
    }
}

/* ============================================================
 * BENCHMARK
 * ============================================================ */

/*
 * Test: 100 entities, each is_a person, each in one of 10 zones.
 * Rule: if X and Y are persons in same zone, X sees Y.
 * This is O(N²) matching — the expensive case.
 */

int main(void) {
    printf("HERB Native Runtime\n");
    printf("====================\n\n");

    SymbolTable* st = symbols_new();
    World* w = world_new();

    /* Intern symbols */
    int IS_A = symbols_intern(st, "is_a");
    int PERSON = symbols_intern(st, "person");
    int LOCATION = symbols_intern(st, "location");
    int SEES = symbols_intern(st, "sees");

    #define NUM_ENTITIES 200
    int entities[NUM_ENTITIES];
    int zones[10];

    for (int i = 0; i < 10; i++) {
        char buf[32];
        sprintf(buf, "zone_%d", i);
        zones[i] = symbols_intern(st, buf);
    }

    for (int i = 0; i < NUM_ENTITIES; i++) {
        char buf[32];
        sprintf(buf, "entity_%d", i);
        entities[i] = symbols_intern(st, buf);
    }

    /* Assert initial facts */
    printf("Asserting %d entities with is_a and location...\n", NUM_ENTITIES);
    for (int i = 0; i < NUM_ENTITIES; i++) {
        world_assert(w, entities[i], IS_A, PERSON);
        world_assert(w, entities[i], LOCATION, zones[i % 10]);
    }
    printf("Initial facts: %d\n\n", w->fact_count);

    /* Add visibility rule:
     * WHEN (?x is_a person) AND (?y is_a person) AND (?x location ?z) AND (?y location ?z)
     * THEN (?x sees ?y)
     *
     * Variables: x=0, y=1, z=2
     */
    Pattern patterns[4] = {
        { VAR(0), IS_A, PERSON },      /* ?x is_a person */
        { VAR(1), IS_A, PERSON },      /* ?y is_a person */
        { VAR(0), LOCATION, VAR(2) },  /* ?x location ?z */
        { VAR(1), LOCATION, VAR(2) }   /* ?y location ?z (z must match!) */
    };
    Pattern tmpl = { VAR(0), SEES, VAR(1) };  /* ?x sees ?y */

    world_add_rule(w, 4, patterns, tmpl);
    printf("Added visibility rule (4 patterns)\n\n");

    /* Derive */
    printf("Running derivation...\n");
    clock_t start = clock();
    int derived = world_derive(w, 1000);
    clock_t end = clock();
    double ms = (double)(end - start) * 1000.0 / CLOCKS_PER_SEC;

    printf("Derived %d facts in %d iterations\n", derived, w->derivation_iterations);
    printf("Time: %.3f ms\n\n", ms);

    /* Count "sees" facts */
    int sees_count = 0;
    for (int i = 0; i < w->fact_count; i++) {
        if (w->facts[i].r == SEES) sees_count++;
    }
    printf("Total 'sees' facts: %d\n", sees_count);
    printf("Expected: %d entities * %d per zone = %d\n\n",
           NUM_ENTITIES, NUM_ENTITIES/10, NUM_ENTITIES * (NUM_ENTITIES/10));

    /* Print first 20 and last 10 facts */
    printf("First 20 facts:\n");
    for (int i = 0; i < 20 && i < w->fact_count; i++) {
        Fact* f = &w->facts[i];
        printf("  (%s %s %s)\n",
            symbols_name(st, f->s),
            symbols_name(st, f->r),
            symbols_name(st, f->o));
    }

    printf("\nLast 10 'sees' facts:\n");
    int printed = 0;
    for (int i = w->fact_count - 1; i >= 0 && printed < 10; i--) {
        Fact* f = &w->facts[i];
        if (f->r == SEES) {
            printf("  (%s %s %s)\n",
                symbols_name(st, f->s),
                symbols_name(st, f->r),
                symbols_name(st, f->o));
            printed++;
        }
    }

    /* Cleanup */
    world_free(w);
    symbols_free(st);

    printf("\nDone.\n");
    return 0;
}
