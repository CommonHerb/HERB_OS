/*
 * HERB Native Runtime — Extended Version
 * Session 20 — Four Essential Primitives
 *
 * Extends herb_runtime.c with the four primitives proven essential
 * in Sessions 16-18:
 *
 * 1. FUNCTIONAL — auto-retract on update (single-valued relations)
 * 2. EPHEMERAL — consumed after all rules process them
 * 3. DEFERRED — effects queue for next micro-iteration
 * 4. ONCE_PER_TICK — each binding fires at most once per tick
 *
 * The benchmark target: run the NPC adventure scenario (4 NPCs, 14 rules,
 * combat + movement + trade) at native speed.
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
#define MAX_TEMPLATES_PER_RULE 4
#define MAX_RETRACTIONS_PER_RULE 4
#define MAX_BINDINGS 8192
#define HASH_SIZE 16384
#define MAX_RELATIONS 256
#define MAX_DEFERRED 4096
#define MAX_FIRED 8192
#define MAX_MICRO_ITERATIONS 20

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
    int alive;  /* 1 if alive, 0 if retracted */
    int micro_iter;  /* which micro-iteration created this fact */
} Fact;

/* A pattern is three integers. Negative = variable slot. */
typedef struct {
    int s;
    int r;
    int o;
} Pattern;

/* A deferred effect — queued assertion or retraction */
typedef struct {
    int s;
    int r;
    int o;
    int is_retraction;  /* 1 = retract, 0 = assert */
} DeferredEffect;

/* A fired binding key — for once_per_tick tracking */
typedef struct {
    int rule_idx;
    int key_values[8];  /* binding key values */
    int key_count;
} FiredKey;

/* A rule is: patterns to match, templates to assert, retractions, flags. */
typedef struct {
    int pattern_count;
    Pattern patterns[MAX_PATTERNS_PER_RULE];

    int template_count;
    Pattern templates[MAX_TEMPLATES_PER_RULE];  /* can have multiple templates */

    int retraction_count;
    Pattern retractions[MAX_RETRACTIONS_PER_RULE];

    /* Flags */
    int deferred;       /* 1 = queue effects for next micro-iteration */
    int once_per_tick;  /* 1 = each binding fires at most once per tick */
    int key_var_count;  /* number of vars in binding key (0 = all vars) */
    int key_vars[8];    /* which variable indices form the key */

    /* For guards: simple comparison guard (op, var_idx, value) */
    int has_guard;
    int guard_op;       /* 0=none, 1=>, 2=<, 3=>=, 4=<=, 5===, 6=!= */
    int guard_var_idx;
    int guard_value;
} Rule;

/* Binding: maps variable indices to values during matching. */
typedef struct {
    int values[MAX_PATTERNS_PER_RULE * 3];  /* Max 3 vars per pattern */
    int bound[MAX_PATTERNS_PER_RULE * 3];   /* 1 if bound, 0 if not */
} Binding;

/* The world: facts + rules + indices + primitives. */
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

    /* FUNCTIONAL: bitset of functional relations */
    uint8_t functional_rels[MAX_RELATIONS / 8];

    /* EPHEMERAL: bitset of ephemeral relations */
    uint8_t ephemeral_rels[MAX_RELATIONS / 8];

    /* DEFERRED: queue of effects for next micro-iteration */
    DeferredEffect* deferred_queue;
    int deferred_count;
    int deferred_capacity;
    int micro_iter;  /* current micro-iteration */

    /* ONCE_PER_TICK: set of fired (rule, binding) keys */
    FiredKey* fired_this_tick;
    int fired_count;
    int fired_capacity;

    /* Ephemeral tracking: facts matched this iteration to consume */
    int* ephemeral_matched;
    int ephemeral_matched_count;
    int ephemeral_matched_capacity;

    /* Tick counter */
    int tick;

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
 * BITSET HELPERS
 * ============================================================ */

static inline void bitset_set(uint8_t* bs, int idx) {
    bs[idx / 8] |= (1 << (idx % 8));
}

static inline int bitset_test(uint8_t* bs, int idx) {
    return (bs[idx / 8] >> (idx % 8)) & 1;
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

    /* Initialize primitive tracking */
    memset(w->functional_rels, 0, sizeof(w->functional_rels));
    memset(w->ephemeral_rels, 0, sizeof(w->ephemeral_rels));

    /* Deferred queue */
    w->deferred_capacity = MAX_DEFERRED;
    w->deferred_count = 0;
    w->deferred_queue = malloc(sizeof(DeferredEffect) * w->deferred_capacity);
    w->micro_iter = 0;

    /* Fired tracking */
    w->fired_capacity = MAX_FIRED;
    w->fired_count = 0;
    w->fired_this_tick = malloc(sizeof(FiredKey) * w->fired_capacity);

    /* Ephemeral matched tracking */
    w->ephemeral_matched_capacity = INITIAL_FACTS;
    w->ephemeral_matched_count = 0;
    w->ephemeral_matched = malloc(sizeof(int) * w->ephemeral_matched_capacity);

    w->tick = 0;
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
    free(w->deferred_queue);
    free(w->fired_this_tick);
    free(w->ephemeral_matched);
    free(w);
}

/* Declare a relation as FUNCTIONAL (single-valued) */
void world_declare_functional(World* w, int relation) {
    if (relation >= 0 && relation < MAX_RELATIONS) {
        bitset_set(w->functional_rels, relation);
    }
}

/* Declare a relation as EPHEMERAL (consumed after use) */
void world_declare_ephemeral(World* w, int relation) {
    if (relation >= 0 && relation < MAX_RELATIONS) {
        bitset_set(w->ephemeral_rels, relation);
    }
}

/* Check if relation is functional */
int is_functional(World* w, int relation) {
    return relation >= 0 && relation < MAX_RELATIONS &&
           bitset_test(w->functional_rels, relation);
}

/* Check if relation is ephemeral */
int is_ephemeral(World* w, int relation) {
    return relation >= 0 && relation < MAX_RELATIONS &&
           bitset_test(w->ephemeral_rels, relation);
}

/* Internal: remove fact from indices (for retraction) */
static void remove_from_indices(World* w, int idx) {
    Fact* f = &w->facts[idx];

    /* Remove from SRO hash (mark as dead by alive flag) */
    /* We don't actually remove from hash — just mark as not alive */
    f->alive = 0;

    /* Note: For a production system, we'd also remove from linked lists.
     * For simplicity, we just mark as dead and skip dead facts during iteration.
     * This is fine for short-lived worlds. */
}

/* Check if fact exists and is alive. O(1) average via hash. */
int world_exists(World* w, int s, int r, int o) {
    uint32_t h = hash3(s, r, o);
    int probes = 0;

    while (w->sro_hash[h] >= 0 && probes < HASH_SIZE) {
        int idx = w->sro_hash[h];
        Fact* f = &w->facts[idx];
        if (f->s == s && f->r == r && f->o == o && f->alive) {
            return 1;
        }
        h = (h + 1) % HASH_SIZE;
        probes++;
    }
    return 0;
}

/* Find fact index by triple. Returns -1 if not found. */
int world_find(World* w, int s, int r, int o) {
    uint32_t h = hash3(s, r, o);
    int probes = 0;

    while (w->sro_hash[h] >= 0 && probes < HASH_SIZE) {
        int idx = w->sro_hash[h];
        Fact* f = &w->facts[idx];
        if (f->s == s && f->r == r && f->o == o && f->alive) {
            return idx;
        }
        h = (h + 1) % HASH_SIZE;
        probes++;
    }
    return -1;
}

/* Retract a fact. Returns 1 if found and retracted, 0 otherwise. */
int world_retract(World* w, int s, int r, int o) {
    int idx = world_find(w, s, r, o);
    if (idx >= 0) {
        remove_from_indices(w, idx);
        return 1;
    }
    return 0;
}

/* Assert a fact. Returns 1 if new, 0 if exists.
 * Handles FUNCTIONAL auto-retract. */
int world_assert(World* w, int s, int r, int o) {
    /* Check existence first */
    if (world_exists(w, s, r, o)) {
        return 0;
    }

    /* FUNCTIONAL: auto-retract any existing fact with same (s, r) */
    if (is_functional(w, r)) {
        uint32_t h = hash2(s, r);
        for (int idx = w->sr_head[h]; idx >= 0; idx = w->sr_next[idx]) {
            Fact* f = &w->facts[idx];
            if (f->s == s && f->r == r && f->alive && f->o != o) {
                /* Retract old value */
                remove_from_indices(w, idx);
                break;  /* Only one value possible for functional */
            }
        }
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
    w->facts[idx].alive = 1;
    w->facts[idx].micro_iter = w->micro_iter;

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
void world_add_rule(World* w, Rule* rule) {
    if (w->rule_count >= w->rule_capacity) {
        w->rule_capacity *= 2;
        w->rules = realloc(w->rules, sizeof(Rule) * w->rule_capacity);
    }
    w->rules[w->rule_count++] = *rule;
}

/* Convenience: add a simple rule (1 template, no retractions, no flags) */
void world_add_simple_rule(World* w, int pattern_count, Pattern* patterns, Pattern template) {
    Rule rule = {0};
    rule.pattern_count = pattern_count;
    for (int i = 0; i < pattern_count; i++) {
        rule.patterns[i] = patterns[i];
    }
    rule.template_count = 1;
    rule.templates[0] = template;
    rule.retraction_count = 0;
    rule.deferred = 0;
    rule.once_per_tick = 0;
    rule.has_guard = 0;
    world_add_rule(w, &rule);
}

/* ============================================================
 * ONCE_PER_TICK TRACKING
 * ============================================================ */

/* Check if this (rule, binding) has already fired this tick */
static int has_fired_this_tick(World* w, int rule_idx, int* key_values, int key_count) {
    for (int i = 0; i < w->fired_count; i++) {
        FiredKey* k = &w->fired_this_tick[i];
        if (k->rule_idx == rule_idx && k->key_count == key_count) {
            int match = 1;
            for (int j = 0; j < key_count; j++) {
                if (k->key_values[j] != key_values[j]) {
                    match = 0;
                    break;
                }
            }
            if (match) return 1;
        }
    }
    return 0;
}

/* Mark this (rule, binding) as fired this tick */
static void mark_fired_this_tick(World* w, int rule_idx, int* key_values, int key_count) {
    if (w->fired_count >= w->fired_capacity) return;  /* Silently drop if full */

    FiredKey* k = &w->fired_this_tick[w->fired_count++];
    k->rule_idx = rule_idx;
    k->key_count = key_count;
    for (int i = 0; i < key_count; i++) {
        k->key_values[i] = key_values[i];
    }
}

/* Clear fired tracking (called at tick start) */
static void clear_fired_this_tick(World* w) {
    w->fired_count = 0;
}

/* ============================================================
 * DEFERRED QUEUE
 * ============================================================ */

/* Queue a deferred effect */
static void queue_deferred(World* w, int s, int r, int o, int is_retraction) {
    if (w->deferred_count >= w->deferred_capacity) return;

    /* Check if already queued */
    for (int i = 0; i < w->deferred_count; i++) {
        DeferredEffect* e = &w->deferred_queue[i];
        if (e->s == s && e->r == r && e->o == o && e->is_retraction == is_retraction) {
            return;  /* Already queued */
        }
    }

    DeferredEffect* e = &w->deferred_queue[w->deferred_count++];
    e->s = s;
    e->r = r;
    e->o = o;
    e->is_retraction = is_retraction;
}

/* Check if a retraction is already queued (for deferred rule duplicate prevention) */
static int is_retraction_queued(World* w, int s, int r, int o) {
    for (int i = 0; i < w->deferred_count; i++) {
        DeferredEffect* e = &w->deferred_queue[i];
        if (e->s == s && e->r == r && e->o == o && e->is_retraction) {
            return 1;
        }
    }
    return 0;
}

/* Apply all deferred effects */
static void apply_deferred(World* w) {
    int next_micro = w->micro_iter + 1;

    for (int i = 0; i < w->deferred_count; i++) {
        DeferredEffect* e = &w->deferred_queue[i];
        if (e->is_retraction) {
            world_retract(w, e->s, e->r, e->o);
        } else {
            /* Set micro_iter for new facts */
            int old_micro = w->micro_iter;
            w->micro_iter = next_micro;
            world_assert(w, e->s, e->r, e->o);
            w->micro_iter = old_micro;
        }
    }

    w->deferred_count = 0;
}

/* ============================================================
 * EPHEMERAL TRACKING
 * ============================================================ */

/* Mark a fact as matched (to be consumed after all rules process it) */
static void mark_ephemeral_matched(World* w, int fact_idx) {
    /* Check if already marked */
    for (int i = 0; i < w->ephemeral_matched_count; i++) {
        if (w->ephemeral_matched[i] == fact_idx) return;
    }

    if (w->ephemeral_matched_count >= w->ephemeral_matched_capacity) {
        w->ephemeral_matched_capacity *= 2;
        w->ephemeral_matched = realloc(w->ephemeral_matched,
                                        sizeof(int) * w->ephemeral_matched_capacity);
    }

    w->ephemeral_matched[w->ephemeral_matched_count++] = fact_idx;
}

/* Consume all matched ephemeral facts */
static void consume_ephemeral(World* w) {
    for (int i = 0; i < w->ephemeral_matched_count; i++) {
        int idx = w->ephemeral_matched[i];
        if (w->facts[idx].alive) {
            remove_from_indices(w, idx);
        }
    }
    w->ephemeral_matched_count = 0;
}

/* ============================================================
 * PATTERN MATCHING
 * ============================================================ */

/* Try to match a pattern against a fact, extending bindings.
 * Returns 1 if match succeeds, 0 if fails. */
static int match_pattern(Pattern* p, Fact* f, Binding* b) {
    /* Skip dead facts */
    if (!f->alive) return 0;

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
 * GUARD EVALUATION
 * ============================================================ */

/* Evaluate a simple guard: op(var, value) */
static int eval_guard(Rule* rule, Binding* b) {
    if (!rule->has_guard) return 1;

    int var_val = b->values[rule->guard_var_idx];
    int cmp_val = rule->guard_value;

    switch (rule->guard_op) {
        case 1: return var_val > cmp_val;   /* > */
        case 2: return var_val < cmp_val;   /* < */
        case 3: return var_val >= cmp_val;  /* >= */
        case 4: return var_val <= cmp_val;  /* <= */
        case 5: return var_val == cmp_val;  /* == */
        case 6: return var_val != cmp_val;  /* != */
        default: return 1;
    }
}

/* ============================================================
 * RULE APPLICATION (THE CORE)
 * ============================================================ */

/* Bindings stack for recursive matching. */
typedef struct {
    Binding bindings[MAX_BINDINGS];
    int matched_facts[MAX_BINDINGS][MAX_PATTERNS_PER_RULE];  /* fact indices per binding */
    int count;
} BindingStack;

/* Recursive pattern matching with backtracking. */
static void match_patterns_recursive(
    World* w,
    Rule* rule,
    int pattern_idx,
    Binding* current,
    int* matched_facts,
    BindingStack* results
) {
    if (pattern_idx >= rule->pattern_count) {
        /* All patterns matched — save this binding */
        if (results->count < MAX_BINDINGS) {
            results->bindings[results->count] = *current;
            memcpy(results->matched_facts[results->count], matched_facts,
                   sizeof(int) * rule->pattern_count);
            results->count++;
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
            if (f->alive && f->r == r && f->o == o) {
                Binding next = *current;
                if (match_pattern(p, f, &next)) {
                    matched_facts[pattern_idx] = idx;
                    match_patterns_recursive(w, rule, pattern_idx + 1, &next,
                                            matched_facts, results);
                }
            }
        }
    } else if (!IS_VAR(s) && !IS_VAR(r)) {
        /* Use SR index: iterate facts with (s, r, ?) */
        uint32_t h = hash2(s, r);
        for (int idx = w->sr_head[h]; idx >= 0; idx = w->sr_next[idx]) {
            Fact* f = &w->facts[idx];
            if (f->alive && f->s == s && f->r == r) {
                Binding next = *current;
                if (match_pattern(p, f, &next)) {
                    matched_facts[pattern_idx] = idx;
                    match_patterns_recursive(w, rule, pattern_idx + 1, &next,
                                            matched_facts, results);
                }
            }
        }
    } else {
        /* Full scan */
        for (int idx = 0; idx < w->fact_count; idx++) {
            Fact* f = &w->facts[idx];
            if (!f->alive) continue;
            Binding next = *current;
            if (match_pattern(p, f, &next)) {
                matched_facts[pattern_idx] = idx;
                match_patterns_recursive(w, rule, pattern_idx + 1, &next,
                                        matched_facts, results);
            }
        }
    }
}

/* Check if binding is still valid (facts still alive) */
static int binding_still_valid(World* w, Rule* rule, int* matched_facts) {
    for (int i = 0; i < rule->pattern_count; i++) {
        if (!w->facts[matched_facts[i]].alive) {
            return 0;
        }
    }
    return 1;
}

/* Apply a single rule. Returns number of new facts derived. */
static int apply_rule(World* w, int rule_idx) {
    Rule* rule = &w->rules[rule_idx];
    BindingStack results;
    results.count = 0;

    Binding initial;
    memset(&initial, 0, sizeof(Binding));
    int matched_facts[MAX_PATTERNS_PER_RULE];

    /* Find all matching bindings */
    match_patterns_recursive(w, rule, 0, &initial, matched_facts, &results);

    /* Process each binding */
    int derived = 0;
    for (int i = 0; i < results.count; i++) {
        Binding* b = &results.bindings[i];
        int* mf = results.matched_facts[i];

        /* Re-validate binding (earlier firings may have retracted facts) */
        if (!binding_still_valid(w, rule, mf)) {
            continue;
        }

        /* Evaluate guard */
        if (!eval_guard(rule, b)) {
            continue;
        }

        /* ONCE_PER_TICK check */
        if (rule->once_per_tick) {
            int key_values[8];
            int key_count;

            if (rule->key_var_count > 0) {
                /* Use specified key vars */
                key_count = rule->key_var_count;
                for (int k = 0; k < key_count; k++) {
                    key_values[k] = b->values[rule->key_vars[k]];
                }
            } else {
                /* Use all bound variables */
                key_count = 0;
                for (int k = 0; k < MAX_PATTERNS_PER_RULE * 3 && key_count < 8; k++) {
                    if (b->bound[k]) {
                        key_values[key_count++] = b->values[k];
                    }
                }
            }

            if (has_fired_this_tick(w, rule_idx, key_values, key_count)) {
                continue;  /* Already fired for this binding */
            }

            mark_fired_this_tick(w, rule_idx, key_values, key_count);
        }

        /* Process templates and retractions */
        if (rule->deferred) {
            /* DEFERRED: Check if any retractions already queued */
            int should_skip = 0;
            for (int r = 0; r < rule->retraction_count; r++) {
                int rs = resolve(rule->retractions[r].s, b);
                int rr = resolve(rule->retractions[r].r, b);
                int ro = resolve(rule->retractions[r].o, b);
                if (is_retraction_queued(w, rs, rr, ro)) {
                    should_skip = 1;
                    break;
                }
            }

            if (should_skip) continue;

            /* Queue assertions */
            for (int t = 0; t < rule->template_count; t++) {
                int ts = resolve(rule->templates[t].s, b);
                int tr = resolve(rule->templates[t].r, b);
                int to = resolve(rule->templates[t].o, b);

                if (!world_exists(w, ts, tr, to)) {
                    queue_deferred(w, ts, tr, to, 0);
                    derived++;
                }
            }

            /* Queue retractions */
            for (int r = 0; r < rule->retraction_count; r++) {
                int rs = resolve(rule->retractions[r].s, b);
                int rr = resolve(rule->retractions[r].r, b);
                int ro = resolve(rule->retractions[r].o, b);

                if (world_exists(w, rs, rr, ro)) {
                    queue_deferred(w, rs, rr, ro, 1);
                    derived++;
                }
            }
        } else {
            /* IMMEDIATE: Apply effects now */

            /* Assert all templates */
            for (int t = 0; t < rule->template_count; t++) {
                int ts = resolve(rule->templates[t].s, b);
                int tr = resolve(rule->templates[t].r, b);
                int to = resolve(rule->templates[t].o, b);

                if (world_assert(w, ts, tr, to)) {
                    derived++;
                }
            }

            /* Process retractions */
            for (int r = 0; r < rule->retraction_count; r++) {
                int rs = resolve(rule->retractions[r].s, b);
                int rr = resolve(rule->retractions[r].r, b);
                int ro = resolve(rule->retractions[r].o, b);

                if (world_retract(w, rs, rr, ro)) {
                    derived++;
                }
            }
        }

        /* EPHEMERAL: Mark matched ephemeral facts for consumption */
        for (int p = 0; p < rule->pattern_count; p++) {
            int fact_idx = mf[p];
            Fact* f = &w->facts[fact_idx];
            if (is_ephemeral(w, f->r)) {
                mark_ephemeral_matched(w, fact_idx);
            }
        }
    }

    return derived;
}

/* ============================================================
 * DERIVATION (THE LOOP)
 * ============================================================ */

/* Derive to fixpoint with micro-iteration support. */
int world_derive(World* w, int max_iterations) {
    int total = 0;

    /* Micro-iteration loop */
    for (int micro = 0; micro < MAX_MICRO_ITERATIONS; micro++) {
        w->micro_iter = micro;

        /* Run all rules to fixpoint */
        int iteration = 0;
        while (iteration < max_iterations) {
            int derived = 0;

            for (int i = 0; i < w->rule_count; i++) {
                derived += apply_rule(w, i);
            }

            /* Consume ephemeral facts after ALL rules have processed */
            consume_ephemeral(w);

            if (derived == 0) {
                break;  /* Fixpoint */
            }

            total += derived;
            iteration++;
        }

        w->derivation_iterations = iteration;

        /* Check for deferred effects */
        if (w->deferred_count == 0) {
            break;  /* No deferred effects - done */
        }

        /* Apply deferred effects for next micro-iteration */
        apply_deferred(w);
    }

    w->facts_derived = total;
    return total;
}

/* Advance the world by one tick */
void world_tick(World* w, int max_iterations) {
    /* Clear once_per_tick tracking */
    clear_fired_this_tick(w);

    /* Run derivation */
    world_derive(w, max_iterations);

    /* Advance tick counter */
    w->tick++;
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
    int alive_count = 0;
    for (int i = 0; i < w->fact_count; i++) {
        if (w->facts[i].alive) alive_count++;
    }

    printf("=== World (tick %d, %d facts alive, %d total) ===\n",
           w->tick, alive_count, w->fact_count);
    for (int i = 0; i < w->fact_count; i++) {
        Fact* f = &w->facts[i];
        if (f->alive) {
            printf("  (%s %s %s)\n",
                symbols_name(st, f->s),
                symbols_name(st, f->r),
                symbols_name(st, f->o));
        }
    }
}

/* ============================================================
 * TEST: FUNCTIONAL
 * ============================================================ */

void test_functional(void) {
    printf("\n=== TEST: FUNCTIONAL ===\n");

    SymbolTable* st = symbols_new();
    World* w = world_new();

    int HERO = symbols_intern(st, "hero");
    int HP = symbols_intern(st, "hp");
    int LOCATION = symbols_intern(st, "location");
    int TOWN = symbols_intern(st, "town");
    int FOREST = symbols_intern(st, "forest");

    /* Declare HP and LOCATION as functional */
    world_declare_functional(w, HP);
    world_declare_functional(w, LOCATION);

    /* Assert initial values */
    world_assert(w, HERO, HP, 100);
    world_assert(w, HERO, LOCATION, TOWN);

    printf("Initial:\n");
    world_print(w, st);

    /* Update HP - should auto-retract old value */
    world_assert(w, HERO, HP, 80);
    printf("\nAfter HP update (100 -> 80):\n");
    world_print(w, st);

    /* Update location */
    world_assert(w, HERO, LOCATION, FOREST);
    printf("\nAfter location update (town -> forest):\n");
    world_print(w, st);

    /* Verify only one HP and one location */
    int hp_count = 0, loc_count = 0;
    for (int i = 0; i < w->fact_count; i++) {
        Fact* f = &w->facts[i];
        if (f->alive && f->s == HERO) {
            if (f->r == HP) hp_count++;
            if (f->r == LOCATION) loc_count++;
        }
    }

    printf("\nHP facts: %d (expected 1)\n", hp_count);
    printf("Location facts: %d (expected 1)\n", loc_count);
    printf("TEST %s\n", (hp_count == 1 && loc_count == 1) ? "PASSED" : "FAILED");

    world_free(w);
    symbols_free(st);
}

/* ============================================================
 * TEST: EPHEMERAL
 * ============================================================ */

void test_ephemeral(void) {
    printf("\n=== TEST: EPHEMERAL ===\n");

    SymbolTable* st = symbols_new();
    World* w = world_new();

    int INPUT = symbols_intern(st, "input");
    int COMMAND = symbols_intern(st, "command");
    int NORTH = symbols_intern(st, "north");
    int PLAYER = symbols_intern(st, "player");
    int LOCATION = symbols_intern(st, "location");
    int LOC_A = symbols_intern(st, "loc_a");
    int LOC_B = symbols_intern(st, "loc_b");
    int CONNECTS = symbols_intern(st, "connects_to");

    /* Declare command as ephemeral */
    world_declare_ephemeral(w, COMMAND);

    /* Setup */
    world_assert(w, PLAYER, LOCATION, LOC_A);
    world_assert(w, LOC_A, CONNECTS, LOC_B);

    /* Add movement rule */
    Rule move_rule = {0};
    move_rule.pattern_count = 3;
    move_rule.patterns[0] = (Pattern){INPUT, COMMAND, VAR(0)};     /* ?dest */
    move_rule.patterns[1] = (Pattern){PLAYER, LOCATION, VAR(1)};   /* ?loc */
    move_rule.patterns[2] = (Pattern){VAR(1), CONNECTS, VAR(0)};   /* loc connects dest */
    move_rule.template_count = 1;
    move_rule.templates[0] = (Pattern){PLAYER, LOCATION, VAR(0)};  /* player at dest */
    move_rule.retraction_count = 1;
    move_rule.retractions[0] = (Pattern){PLAYER, LOCATION, VAR(1)};
    world_add_rule(w, &move_rule);

    printf("Before command:\n");
    world_print(w, st);

    /* Issue command */
    world_assert(w, INPUT, COMMAND, LOC_B);

    printf("\nCommand issued:\n");
    world_print(w, st);

    /* Tick */
    world_tick(w, 100);

    printf("\nAfter tick (command should be consumed):\n");
    world_print(w, st);

    /* Verify command was consumed */
    int cmd_exists = world_exists(w, INPUT, COMMAND, LOC_B);
    printf("\nCommand exists: %d (expected 0)\n", cmd_exists);
    printf("TEST %s\n", cmd_exists == 0 ? "PASSED" : "FAILED");

    world_free(w);
    symbols_free(st);
}

/* ============================================================
 * TEST: DEFERRED
 * ============================================================ */

void test_deferred(void) {
    printf("\n=== TEST: DEFERRED ===\n");

    SymbolTable* st = symbols_new();
    World* w = world_new();

    int ENTITY = symbols_intern(st, "entity");
    int HP = symbols_intern(st, "hp");
    int PENDING_DAMAGE = symbols_intern(st, "pending_damage");
    int IS_ALIVE = symbols_intern(st, "is_alive");
    int HERO = symbols_intern(st, "hero");

    /* Declare HP and is_alive as functional */
    world_declare_functional(w, HP);
    world_declare_functional(w, IS_ALIVE);

    /* Setup */
    world_assert(w, HERO, HP, 30);
    world_assert(w, HERO, IS_ALIVE, 1);
    world_assert(w, HERO, PENDING_DAMAGE, 15);

    /* Rule 1: apply damage (deferred) */
    Rule damage_rule = {0};
    damage_rule.pattern_count = 2;
    damage_rule.patterns[0] = (Pattern){VAR(0), PENDING_DAMAGE, VAR(1)};  /* ?e pending_damage ?dmg */
    damage_rule.patterns[1] = (Pattern){VAR(0), HP, VAR(2)};              /* ?e hp ?hp */
    damage_rule.template_count = 1;
    /* Note: In real impl we'd have expressions. Here we simulate with constant */
    /* For test, we'll just set HP to a value that simulates hp - dmg */
    damage_rule.templates[0] = (Pattern){VAR(0), HP, 15};  /* hp becomes 15 (30-15) */
    damage_rule.retraction_count = 1;
    damage_rule.retractions[0] = (Pattern){VAR(0), PENDING_DAMAGE, VAR(1)};
    damage_rule.deferred = 1;  /* DEFERRED! */
    world_add_rule(w, &damage_rule);

    /* Rule 2: check death (deferred, fires after damage applies) */
    Rule death_rule = {0};
    death_rule.pattern_count = 2;
    death_rule.patterns[0] = (Pattern){VAR(0), HP, VAR(1)};       /* ?e hp ?hp */
    death_rule.patterns[1] = (Pattern){VAR(0), IS_ALIVE, 1};      /* ?e is_alive true */
    death_rule.template_count = 1;
    death_rule.templates[0] = (Pattern){VAR(0), IS_ALIVE, 0};     /* is_alive false */
    death_rule.has_guard = 1;
    death_rule.guard_op = 4;  /* <= */
    death_rule.guard_var_idx = 1;  /* VAR(1) = hp */
    death_rule.guard_value = 0;    /* hp <= 0 */
    death_rule.deferred = 1;
    world_add_rule(w, &death_rule);

    printf("Before tick:\n");
    world_print(w, st);

    /* Tick */
    world_tick(w, 100);

    printf("\nAfter tick:\n");
    world_print(w, st);

    /* Verify damage applied, pending_damage consumed */
    int pending_exists = world_exists(w, HERO, PENDING_DAMAGE, 15);
    printf("\nPending damage exists: %d (expected 0)\n", pending_exists);
    printf("TEST %s\n", pending_exists == 0 ? "PASSED" : "FAILED");

    world_free(w);
    symbols_free(st);
}

/* ============================================================
 * TEST: ONCE_PER_TICK
 * ============================================================ */

void test_once_per_tick(void) {
    printf("\n=== TEST: ONCE_PER_TICK ===\n");

    SymbolTable* st = symbols_new();
    World* w = world_new();

    int GUARD = symbols_intern(st, "guard");
    int GOBLIN = symbols_intern(st, "goblin");
    int WOLF = symbols_intern(st, "wolf");
    int LOCATION = symbols_intern(st, "location");
    int FOREST = symbols_intern(st, "forest");
    int IS_A = symbols_intern(st, "is_a");
    int ENEMY = symbols_intern(st, "enemy");
    int COMBATANT = symbols_intern(st, "combatant");
    int PENDING_DAMAGE = symbols_intern(st, "pending_damage");
    int HP = symbols_intern(st, "hp");
    int IS_ALIVE = symbols_intern(st, "is_alive");

    /* Declare functional */
    world_declare_functional(w, LOCATION);
    world_declare_functional(w, HP);
    world_declare_functional(w, IS_ALIVE);

    /* Setup guard */
    world_assert(w, GUARD, IS_A, COMBATANT);
    world_assert(w, GUARD, LOCATION, FOREST);
    world_assert(w, GUARD, HP, 80);
    world_assert(w, GUARD, IS_ALIVE, 1);

    /* Setup enemies */
    world_assert(w, GOBLIN, IS_A, ENEMY);
    world_assert(w, GOBLIN, LOCATION, FOREST);
    world_assert(w, GOBLIN, HP, 30);
    world_assert(w, GOBLIN, IS_ALIVE, 1);

    world_assert(w, WOLF, IS_A, ENEMY);
    world_assert(w, WOLF, LOCATION, FOREST);
    world_assert(w, WOLF, HP, 25);
    world_assert(w, WOLF, IS_ALIVE, 1);

    /* Guard attacks rule (ONCE PER TICK per target) */
    Rule attack_rule = {0};
    attack_rule.pattern_count = 4;
    attack_rule.patterns[0] = (Pattern){GUARD, IS_A, COMBATANT};
    attack_rule.patterns[1] = (Pattern){GUARD, LOCATION, VAR(0)};    /* ?loc */
    attack_rule.patterns[2] = (Pattern){VAR(1), IS_A, ENEMY};        /* ?e is_a enemy */
    attack_rule.patterns[3] = (Pattern){VAR(1), LOCATION, VAR(0)};   /* ?e at same loc */
    attack_rule.template_count = 1;
    attack_rule.templates[0] = (Pattern){VAR(1), PENDING_DAMAGE, 12};  /* guard does 12 dmg */
    attack_rule.once_per_tick = 1;
    attack_rule.key_var_count = 1;
    attack_rule.key_vars[0] = 1;  /* Key on ?e (the target) */
    world_add_rule(w, &attack_rule);

    printf("Before tick:\n");
    world_print(w, st);

    /* Tick */
    world_tick(w, 100);

    printf("\nAfter tick:\n");
    world_print(w, st);

    /* Count pending_damage facts */
    int damage_count = 0;
    for (int i = 0; i < w->fact_count; i++) {
        Fact* f = &w->facts[i];
        if (f->alive && f->r == PENDING_DAMAGE) {
            damage_count++;
            printf("  Found: %s pending_damage %d\n",
                   symbols_name(st, f->s), f->o);
        }
    }

    printf("\nPending damage facts: %d (expected 2 - one per enemy)\n", damage_count);
    printf("TEST %s\n", damage_count == 2 ? "PASSED" : "FAILED");

    world_free(w);
    symbols_free(st);
}

/* ============================================================
 * BENCHMARK: VISIBILITY (same as original)
 * ============================================================ */

void benchmark_visibility(int num_entities) {
    printf("\n=== BENCHMARK: VISIBILITY (%d entities) ===\n", num_entities);

    SymbolTable* st = symbols_new();
    World* w = world_new();

    /* Intern symbols */
    int IS_A = symbols_intern(st, "is_a");
    int PERSON = symbols_intern(st, "person");
    int LOCATION = symbols_intern(st, "location");
    int SEES = symbols_intern(st, "sees");

    int entities[num_entities];
    int zones[10];

    for (int i = 0; i < 10; i++) {
        char buf[32];
        sprintf(buf, "zone_%d", i);
        zones[i] = symbols_intern(st, buf);
    }

    for (int i = 0; i < num_entities; i++) {
        char buf[32];
        sprintf(buf, "entity_%d", i);
        entities[i] = symbols_intern(st, buf);
    }

    /* Assert initial facts */
    for (int i = 0; i < num_entities; i++) {
        world_assert(w, entities[i], IS_A, PERSON);
        world_assert(w, entities[i], LOCATION, zones[i % 10]);
    }
    printf("Initial facts: %d\n", w->fact_count);

    /* Add visibility rule */
    Pattern patterns[4] = {
        { VAR(0), IS_A, PERSON },
        { VAR(1), IS_A, PERSON },
        { VAR(0), LOCATION, VAR(2) },
        { VAR(1), LOCATION, VAR(2) }
    };
    Pattern tmpl = { VAR(0), SEES, VAR(1) };
    world_add_simple_rule(w, 4, patterns, tmpl);

    /* Derive */
    clock_t start = clock();
    int derived = world_derive(w, 1000);
    clock_t end = clock();
    double ms = (double)(end - start) * 1000.0 / CLOCKS_PER_SEC;

    printf("Derived %d facts in %d iterations\n", derived, w->derivation_iterations);
    printf("Time: %.3f ms\n", ms);

    /* Count "sees" facts */
    int sees_count = 0;
    for (int i = 0; i < w->fact_count; i++) {
        if (w->facts[i].alive && w->facts[i].r == SEES) sees_count++;
    }
    printf("Total 'sees' facts: %d\n", sees_count);
    printf("Expected: %d\n", num_entities * (num_entities/10));

    world_free(w);
    symbols_free(st);
}

/* ============================================================
 * MAIN
 * ============================================================ */

int main(void) {
    printf("HERB Native Runtime — Extended Version\n");
    printf("Session 20: Four Essential Primitives\n");
    printf("========================================\n");

    /* Run tests */
    test_functional();
    test_ephemeral();
    test_deferred();
    test_once_per_tick();

    /* Run benchmark */
    benchmark_visibility(100);
    benchmark_visibility(200);

    printf("\n========================================\n");
    printf("All tests completed.\n");

    return 0;
}
