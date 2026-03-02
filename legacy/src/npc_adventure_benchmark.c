/*
 * NPC Adventure Benchmark — C Runtime
 * Session 20
 *
 * This benchmark runs the NPC adventure scenario from npc_adventure.py
 * in the C runtime to compare performance.
 *
 * The scenario:
 * - 4 NPCs: guard, merchant, wanderer, bandit
 * - 14+ rules for combat, movement, trading
 * - Multiple ticks simulating game actions
 *
 * Key primitives tested:
 * - FUNCTIONAL (hp, location, gold are single-valued)
 * - EPHEMERAL (attack_cmd, move_cmd consumed after use)
 * - DEFERRED (damage -> hp update -> death -> loot)
 * - ONCE_PER_TICK (each NPC acts once per turn)
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
#define MAX_RULES 64
#define MAX_PATTERNS_PER_RULE 8
#define MAX_TEMPLATES_PER_RULE 4
#define MAX_RETRACTIONS_PER_RULE 4
#define MAX_BINDINGS 8192
#define HASH_SIZE 16384
#define MAX_RELATIONS 256
#define MAX_DEFERRED 4096
#define MAX_FIRED 8192
#define MAX_MICRO_ITERATIONS 20

#define VAR(n) (-(n) - 1)
#define IS_VAR(v) ((v) < 0)
#define VAR_INDEX(v) (-(v) - 1)

/* Expression operations */
#define EXPR_NONE 0
#define EXPR_SUB 1   /* subtraction: arg1 - arg2 */
#define EXPR_ADD 2   /* addition: arg1 + arg2 */

/* Guard operations */
#define GUARD_NONE 0
#define GUARD_GT 1   /* > */
#define GUARD_LT 2   /* < */
#define GUARD_GE 3   /* >= */
#define GUARD_LE 4   /* <= */
#define GUARD_EQ 5   /* == */
#define GUARD_NE 6   /* != */

/* ============================================================
 * DATA STRUCTURES
 * ============================================================ */

typedef struct {
    int s, r, o;
    int alive;
    int micro_iter;
} Fact;

typedef struct {
    int s, r, o;
} Pattern;

/* Expression: computes a value from bound variables */
typedef struct {
    int op;      /* EXPR_* */
    int arg1;    /* var index or literal */
    int arg2;    /* var index or literal */
    int arg1_is_var;
    int arg2_is_var;
} Expr;

/* Template with optional expression for object */
typedef struct {
    int s;          /* subject (may be var) */
    int r;          /* relation (usually literal) */
    int o;          /* object (literal, or result of expr) */
    int use_expr;   /* if 1, compute o from expr */
    Expr expr;
} Template;

/* Guard: filters bindings */
typedef struct {
    int op;      /* GUARD_* */
    int var_idx;
    int value;
} Guard;

typedef struct {
    int s, r, o;
    int is_retraction;
} DeferredEffect;

typedef struct {
    int rule_idx;
    int key_values[8];
    int key_count;
} FiredKey;

typedef struct {
    int pattern_count;
    Pattern patterns[MAX_PATTERNS_PER_RULE];
    int template_count;
    Template templates[MAX_TEMPLATES_PER_RULE];
    int retraction_count;
    Pattern retractions[MAX_RETRACTIONS_PER_RULE];
    int deferred;
    int once_per_tick;
    int key_var_count;
    int key_vars[8];
    Guard guard;
} Rule;

typedef struct {
    int values[MAX_PATTERNS_PER_RULE * 3];
    int bound[MAX_PATTERNS_PER_RULE * 3];
} Binding;

typedef struct {
    Fact* facts;
    int fact_count;
    int fact_capacity;
    Rule rules[MAX_RULES];
    int rule_count;
    int* sro_hash;
    int* ro_head;
    int* sr_head;
    int* ro_next;
    int* sr_next;
    uint8_t functional_rels[MAX_RELATIONS / 8];
    uint8_t ephemeral_rels[MAX_RELATIONS / 8];
    DeferredEffect deferred_queue[MAX_DEFERRED];
    int deferred_count;
    int micro_iter;
    FiredKey fired_this_tick[MAX_FIRED];
    int fired_count;
    int* ephemeral_matched;
    int ephemeral_matched_count;
    int ephemeral_matched_capacity;
    int tick;
} World;

/* ============================================================
 * SYMBOL TABLE
 * ============================================================ */

#define MAX_SYMBOLS 256
#define MAX_SYMBOL_LEN 32

typedef struct {
    char names[MAX_SYMBOLS][MAX_SYMBOL_LEN];
    int count;
} SymbolTable;

static SymbolTable g_symbols = {0};

int sym(const char* name) {
    for (int i = 0; i < g_symbols.count; i++) {
        if (strcmp(g_symbols.names[i], name) == 0) return i;
    }
    if (g_symbols.count < MAX_SYMBOLS) {
        strncpy(g_symbols.names[g_symbols.count], name, MAX_SYMBOL_LEN - 1);
        return g_symbols.count++;
    }
    return -1;
}

const char* sym_name(int id) {
    if (id >= 0 && id < g_symbols.count) return g_symbols.names[id];
    static char buf[16];
    sprintf(buf, "%d", id);  /* Return numeric value for integers */
    return buf;
}

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
    if (idx >= 0 && idx < MAX_RELATIONS) bs[idx / 8] |= (1 << (idx % 8));
}

static inline int bitset_test(uint8_t* bs, int idx) {
    if (idx >= 0 && idx < MAX_RELATIONS) return (bs[idx / 8] >> (idx % 8)) & 1;
    return 0;
}

/* ============================================================
 * WORLD OPERATIONS
 * ============================================================ */

World* world_new(void) {
    World* w = calloc(1, sizeof(World));
    w->fact_capacity = INITIAL_FACTS;
    w->facts = malloc(sizeof(Fact) * w->fact_capacity);
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
    w->ephemeral_matched_capacity = INITIAL_FACTS;
    w->ephemeral_matched = malloc(sizeof(int) * w->ephemeral_matched_capacity);
    return w;
}

void world_free(World* w) {
    free(w->facts);
    free(w->sro_hash);
    free(w->ro_head);
    free(w->sr_head);
    free(w->ro_next);
    free(w->sr_next);
    free(w->ephemeral_matched);
    free(w);
}

void world_declare_functional(World* w, int rel) { bitset_set(w->functional_rels, rel); }
void world_declare_ephemeral(World* w, int rel) { bitset_set(w->ephemeral_rels, rel); }
int is_functional(World* w, int rel) { return bitset_test(w->functional_rels, rel); }
int is_ephemeral(World* w, int rel) { return bitset_test(w->ephemeral_rels, rel); }

static void remove_from_indices(World* w, int idx) { w->facts[idx].alive = 0; }

int world_exists(World* w, int s, int r, int o) {
    uint32_t h = hash3(s, r, o);
    for (int probes = 0; w->sro_hash[h] >= 0 && probes < HASH_SIZE; h = (h + 1) % HASH_SIZE, probes++) {
        int idx = w->sro_hash[h];
        Fact* f = &w->facts[idx];
        if (f->s == s && f->r == r && f->o == o && f->alive) return 1;
    }
    return 0;
}

int world_find(World* w, int s, int r, int o) {
    uint32_t h = hash3(s, r, o);
    for (int probes = 0; w->sro_hash[h] >= 0 && probes < HASH_SIZE; h = (h + 1) % HASH_SIZE, probes++) {
        int idx = w->sro_hash[h];
        Fact* f = &w->facts[idx];
        if (f->s == s && f->r == r && f->o == o && f->alive) return idx;
    }
    return -1;
}

int world_retract(World* w, int s, int r, int o) {
    int idx = world_find(w, s, r, o);
    if (idx >= 0) { remove_from_indices(w, idx); return 1; }
    return 0;
}

int world_assert(World* w, int s, int r, int o) {
    if (world_exists(w, s, r, o)) return 0;

    /* FUNCTIONAL auto-retract */
    if (is_functional(w, r)) {
        uint32_t h = hash2(s, r);
        for (int idx = w->sr_head[h]; idx >= 0; idx = w->sr_next[idx]) {
            Fact* f = &w->facts[idx];
            if (f->s == s && f->r == r && f->alive && f->o != o) {
                remove_from_indices(w, idx);
                break;
            }
        }
    }

    if (w->fact_count >= w->fact_capacity) {
        w->fact_capacity *= 2;
        w->facts = realloc(w->facts, sizeof(Fact) * w->fact_capacity);
        w->ro_next = realloc(w->ro_next, sizeof(int) * w->fact_capacity);
        w->sr_next = realloc(w->sr_next, sizeof(int) * w->fact_capacity);
    }

    int idx = w->fact_count++;
    w->facts[idx] = (Fact){s, r, o, 1, w->micro_iter};

    uint32_t h = hash3(s, r, o);
    while (w->sro_hash[h] >= 0) h = (h + 1) % HASH_SIZE;
    w->sro_hash[h] = idx;

    uint32_t hro = hash2(r, o);
    w->ro_next[idx] = w->ro_head[hro];
    w->ro_head[hro] = idx;

    uint32_t hsr = hash2(s, r);
    w->sr_next[idx] = w->sr_head[hsr];
    w->sr_head[hsr] = idx;

    return 1;
}

/* ============================================================
 * TRACKING
 * ============================================================ */

static int has_fired_this_tick(World* w, int rule_idx, int* key_values, int key_count) {
    for (int i = 0; i < w->fired_count; i++) {
        FiredKey* k = &w->fired_this_tick[i];
        if (k->rule_idx == rule_idx && k->key_count == key_count) {
            int match = 1;
            for (int j = 0; j < key_count; j++) if (k->key_values[j] != key_values[j]) { match = 0; break; }
            if (match) return 1;
        }
    }
    return 0;
}

static void mark_fired_this_tick(World* w, int rule_idx, int* key_values, int key_count) {
    if (w->fired_count >= MAX_FIRED) return;
    FiredKey* k = &w->fired_this_tick[w->fired_count++];
    k->rule_idx = rule_idx;
    k->key_count = key_count;
    for (int i = 0; i < key_count; i++) k->key_values[i] = key_values[i];
}

static void queue_deferred(World* w, int s, int r, int o, int is_retraction) {
    if (w->deferred_count >= MAX_DEFERRED) return;
    for (int i = 0; i < w->deferred_count; i++) {
        DeferredEffect* e = &w->deferred_queue[i];
        if (e->s == s && e->r == r && e->o == o && e->is_retraction == is_retraction) return;
    }
    w->deferred_queue[w->deferred_count++] = (DeferredEffect){s, r, o, is_retraction};
}

static int is_retraction_queued(World* w, int s, int r, int o) {
    for (int i = 0; i < w->deferred_count; i++) {
        DeferredEffect* e = &w->deferred_queue[i];
        if (e->s == s && e->r == r && e->o == o && e->is_retraction) return 1;
    }
    return 0;
}

static void apply_deferred(World* w) {
    int next_micro = w->micro_iter + 1;
    for (int i = 0; i < w->deferred_count; i++) {
        DeferredEffect* e = &w->deferred_queue[i];
        if (e->is_retraction) world_retract(w, e->s, e->r, e->o);
        else { int old = w->micro_iter; w->micro_iter = next_micro; world_assert(w, e->s, e->r, e->o); w->micro_iter = old; }
    }
    w->deferred_count = 0;
}

static void mark_ephemeral_matched(World* w, int idx) {
    for (int i = 0; i < w->ephemeral_matched_count; i++) if (w->ephemeral_matched[i] == idx) return;
    if (w->ephemeral_matched_count >= w->ephemeral_matched_capacity) {
        w->ephemeral_matched_capacity *= 2;
        w->ephemeral_matched = realloc(w->ephemeral_matched, sizeof(int) * w->ephemeral_matched_capacity);
    }
    w->ephemeral_matched[w->ephemeral_matched_count++] = idx;
}

static void consume_ephemeral(World* w) {
    for (int i = 0; i < w->ephemeral_matched_count; i++) {
        if (w->facts[w->ephemeral_matched[i]].alive) remove_from_indices(w, w->ephemeral_matched[i]);
    }
    w->ephemeral_matched_count = 0;
}

/* ============================================================
 * PATTERN MATCHING
 * ============================================================ */

static int match_pattern(Pattern* p, Fact* f, Binding* b) {
    if (!f->alive) return 0;
    if (IS_VAR(p->s)) { int vi = VAR_INDEX(p->s); if (b->bound[vi]) { if (b->values[vi] != f->s) return 0; } else { b->values[vi] = f->s; b->bound[vi] = 1; } }
    else if (p->s != f->s) return 0;
    if (IS_VAR(p->r)) { int vi = VAR_INDEX(p->r); if (b->bound[vi]) { if (b->values[vi] != f->r) return 0; } else { b->values[vi] = f->r; b->bound[vi] = 1; } }
    else if (p->r != f->r) return 0;
    if (IS_VAR(p->o)) { int vi = VAR_INDEX(p->o); if (b->bound[vi]) { if (b->values[vi] != f->o) return 0; } else { b->values[vi] = f->o; b->bound[vi] = 1; } }
    else if (p->o != f->o) return 0;
    return 1;
}

static int resolve(int v, Binding* b) { return IS_VAR(v) ? b->values[VAR_INDEX(v)] : v; }

static int eval_guard(Guard* g, Binding* b) {
    if (g->op == GUARD_NONE) return 1;
    int val = b->values[g->var_idx];
    switch (g->op) {
        case GUARD_GT: return val > g->value;
        case GUARD_LT: return val < g->value;
        case GUARD_GE: return val >= g->value;
        case GUARD_LE: return val <= g->value;
        case GUARD_EQ: return val == g->value;
        case GUARD_NE: return val != g->value;
    }
    return 1;
}

static int eval_expr(Expr* e, Binding* b) {
    int a1 = e->arg1_is_var ? b->values[e->arg1] : e->arg1;
    int a2 = e->arg2_is_var ? b->values[e->arg2] : e->arg2;
    switch (e->op) {
        case EXPR_SUB: return a1 - a2;
        case EXPR_ADD: return a1 + a2;
    }
    return 0;
}

/* ============================================================
 * RULE APPLICATION
 * ============================================================ */

typedef struct {
    Binding bindings[MAX_BINDINGS];
    int matched_facts[MAX_BINDINGS][MAX_PATTERNS_PER_RULE];
    int count;
} BindingStack;

static void match_patterns_recursive(World* w, Rule* rule, int pat_idx, Binding* cur, int* mf, BindingStack* res) {
    if (pat_idx >= rule->pattern_count) {
        if (res->count < MAX_BINDINGS) {
            res->bindings[res->count] = *cur;
            memcpy(res->matched_facts[res->count], mf, sizeof(int) * rule->pattern_count);
            res->count++;
        }
        return;
    }
    Pattern* p = &rule->patterns[pat_idx];
    int s = IS_VAR(p->s) && cur->bound[VAR_INDEX(p->s)] ? cur->values[VAR_INDEX(p->s)] : p->s;
    int r = IS_VAR(p->r) && cur->bound[VAR_INDEX(p->r)] ? cur->values[VAR_INDEX(p->r)] : p->r;
    int o = IS_VAR(p->o) && cur->bound[VAR_INDEX(p->o)] ? cur->values[VAR_INDEX(p->o)] : p->o;

    if (!IS_VAR(r) && !IS_VAR(o)) {
        uint32_t h = hash2(r, o);
        for (int idx = w->ro_head[h]; idx >= 0; idx = w->ro_next[idx]) {
            Fact* f = &w->facts[idx];
            if (f->alive && f->r == r && f->o == o) {
                Binding next = *cur;
                if (match_pattern(p, f, &next)) { mf[pat_idx] = idx; match_patterns_recursive(w, rule, pat_idx + 1, &next, mf, res); }
            }
        }
    } else if (!IS_VAR(s) && !IS_VAR(r)) {
        uint32_t h = hash2(s, r);
        for (int idx = w->sr_head[h]; idx >= 0; idx = w->sr_next[idx]) {
            Fact* f = &w->facts[idx];
            if (f->alive && f->s == s && f->r == r) {
                Binding next = *cur;
                if (match_pattern(p, f, &next)) { mf[pat_idx] = idx; match_patterns_recursive(w, rule, pat_idx + 1, &next, mf, res); }
            }
        }
    } else {
        for (int idx = 0; idx < w->fact_count; idx++) {
            Fact* f = &w->facts[idx];
            if (!f->alive) continue;
            Binding next = *cur;
            if (match_pattern(p, f, &next)) { mf[pat_idx] = idx; match_patterns_recursive(w, rule, pat_idx + 1, &next, mf, res); }
        }
    }
}

static int binding_still_valid(World* w, Rule* rule, int* mf) {
    for (int i = 0; i < rule->pattern_count; i++) if (!w->facts[mf[i]].alive) return 0;
    return 1;
}

static int apply_rule(World* w, int rule_idx) {
    Rule* rule = &w->rules[rule_idx];
    BindingStack results = {.count = 0};
    Binding initial = {0};
    int mf[MAX_PATTERNS_PER_RULE];
    match_patterns_recursive(w, rule, 0, &initial, mf, &results);

    int derived = 0;
    for (int i = 0; i < results.count; i++) {
        Binding* b = &results.bindings[i];
        int* matched = results.matched_facts[i];
        if (!binding_still_valid(w, rule, matched)) continue;
        if (!eval_guard(&rule->guard, b)) continue;

        if (rule->once_per_tick) {
            int key_values[8], key_count;
            if (rule->key_var_count > 0) {
                key_count = rule->key_var_count;
                for (int k = 0; k < key_count; k++) key_values[k] = b->values[rule->key_vars[k]];
            } else {
                key_count = 0;
                for (int k = 0; k < MAX_PATTERNS_PER_RULE * 3 && key_count < 8; k++)
                    if (b->bound[k]) key_values[key_count++] = b->values[k];
            }
            if (has_fired_this_tick(w, rule_idx, key_values, key_count)) continue;
            mark_fired_this_tick(w, rule_idx, key_values, key_count);
        }

        if (rule->deferred) {
            int should_skip = 0;
            for (int r = 0; r < rule->retraction_count; r++) {
                int rs = resolve(rule->retractions[r].s, b);
                int rr = resolve(rule->retractions[r].r, b);
                int ro = resolve(rule->retractions[r].o, b);
                if (is_retraction_queued(w, rs, rr, ro)) { should_skip = 1; break; }
            }
            if (should_skip) continue;

            for (int t = 0; t < rule->template_count; t++) {
                Template* tmpl = &rule->templates[t];
                int ts = resolve(tmpl->s, b);
                int tr = resolve(tmpl->r, b);
                int to = tmpl->use_expr ? eval_expr(&tmpl->expr, b) : resolve(tmpl->o, b);
                if (!world_exists(w, ts, tr, to)) { queue_deferred(w, ts, tr, to, 0); derived++; }
            }
            for (int r = 0; r < rule->retraction_count; r++) {
                int rs = resolve(rule->retractions[r].s, b);
                int rr = resolve(rule->retractions[r].r, b);
                int ro = resolve(rule->retractions[r].o, b);
                if (world_exists(w, rs, rr, ro)) { queue_deferred(w, rs, rr, ro, 1); derived++; }
            }
        } else {
            for (int t = 0; t < rule->template_count; t++) {
                Template* tmpl = &rule->templates[t];
                int ts = resolve(tmpl->s, b);
                int tr = resolve(tmpl->r, b);
                int to = tmpl->use_expr ? eval_expr(&tmpl->expr, b) : resolve(tmpl->o, b);
                if (world_assert(w, ts, tr, to)) derived++;
            }
            for (int r = 0; r < rule->retraction_count; r++) {
                int rs = resolve(rule->retractions[r].s, b);
                int rr = resolve(rule->retractions[r].r, b);
                int ro = resolve(rule->retractions[r].o, b);
                if (world_retract(w, rs, rr, ro)) derived++;
            }
        }

        for (int p = 0; p < rule->pattern_count; p++)
            if (is_ephemeral(w, w->facts[matched[p]].r)) mark_ephemeral_matched(w, matched[p]);
    }
    return derived;
}

int world_derive(World* w, int max_iter) {
    int total = 0;
    for (int micro = 0; micro < MAX_MICRO_ITERATIONS; micro++) {
        w->micro_iter = micro;
        for (int iter = 0; iter < max_iter; iter++) {
            int derived = 0;
            for (int i = 0; i < w->rule_count; i++) derived += apply_rule(w, i);
            consume_ephemeral(w);
            if (derived == 0) break;
            total += derived;
        }
        if (w->deferred_count == 0) break;
        apply_deferred(w);
    }
    return total;
}

void world_tick(World* w, int max_iter) {
    w->fired_count = 0;
    world_derive(w, max_iter);
    w->tick++;
}

/* ============================================================
 * NPC ADVENTURE SCENARIO
 * ============================================================ */

void setup_npc_adventure(World* w) {
    /* Symbols */
    int IS_A = sym("is_a");
    int HP = sym("hp");
    int LOCATION = sym("location");
    int IS_ALIVE = sym("is_alive");
    int GOLD = sym("gold");
    int BASE_DAMAGE = sym("base_damage");
    int PENDING_DAMAGE = sym("pending_damage");
    int CONNECTS_TO = sym("connects_to");
    int PATROL_TARGET = sym("patrol_target");
    int ATTACK_CMD = sym("attack_cmd");
    int MOVE_CMD = sym("move_cmd");
    int JOB = sym("job");
    int OUTPUT = sym("output");
    int TRADE_AVAILABLE = sym("trade_available");
    int LOOTED = sym("looted");
    int HITS = sym("hits");

    int PLAYER = sym("player");
    int COMBATANT = sym("combatant");
    int ENEMY = sym("enemy");
    int NPC = sym("npc");
    int HOSTILE = sym("hostile");
    int INPUT = sym("input");
    int TRUE = sym("true");

    int FOREST = sym("forest");
    int TOWN = sym("town");
    int MARKET = sym("market");
    int CAVE = sym("cave");

    int GUARD = sym("guard");
    int MERCHANT = sym("merchant");
    int WANDERER = sym("wanderer");
    int BANDIT = sym("bandit");
    int GOBLIN = sym("goblin");
    int WOLF = sym("wolf");

    int PATROL = sym("patrol");
    int IDLE = sym("idle");

    /* Declarations */
    world_declare_functional(w, HP);
    world_declare_functional(w, LOCATION);
    world_declare_functional(w, IS_ALIVE);
    world_declare_functional(w, GOLD);
    world_declare_functional(w, PATROL_TARGET);
    world_declare_ephemeral(w, ATTACK_CMD);
    world_declare_ephemeral(w, MOVE_CMD);

    /* World topology */
    world_assert(w, FOREST, CONNECTS_TO, TOWN);
    world_assert(w, TOWN, CONNECTS_TO, FOREST);
    world_assert(w, TOWN, CONNECTS_TO, MARKET);
    world_assert(w, MARKET, CONNECTS_TO, TOWN);
    world_assert(w, FOREST, CONNECTS_TO, CAVE);
    world_assert(w, CAVE, CONNECTS_TO, FOREST);
    world_assert(w, TOWN, IS_A, sym("safe"));
    world_assert(w, MARKET, IS_A, sym("safe"));

    /* Player */
    world_assert(w, PLAYER, IS_A, sym("player"));
    world_assert(w, PLAYER, IS_A, COMBATANT);
    world_assert(w, PLAYER, HP, 100);
    world_assert(w, PLAYER, BASE_DAMAGE, 15);
    world_assert(w, PLAYER, LOCATION, FOREST);
    world_assert(w, PLAYER, IS_ALIVE, TRUE);
    world_assert(w, PLAYER, GOLD, 50);

    /* Enemies */
    world_assert(w, GOBLIN, IS_A, ENEMY);
    world_assert(w, GOBLIN, IS_A, COMBATANT);
    world_assert(w, GOBLIN, HP, 25);
    world_assert(w, GOBLIN, BASE_DAMAGE, 8);
    world_assert(w, GOBLIN, LOCATION, FOREST);
    world_assert(w, GOBLIN, IS_ALIVE, TRUE);
    world_assert(w, GOBLIN, GOLD, 25);

    world_assert(w, WOLF, IS_A, ENEMY);
    world_assert(w, WOLF, IS_A, COMBATANT);
    world_assert(w, WOLF, HP, 30);
    world_assert(w, WOLF, BASE_DAMAGE, 6);
    world_assert(w, WOLF, LOCATION, FOREST);
    world_assert(w, WOLF, IS_ALIVE, TRUE);
    world_assert(w, WOLF, GOLD, 10);

    /* NPCs */
    world_assert(w, GUARD, IS_A, NPC);
    world_assert(w, GUARD, IS_A, COMBATANT);
    world_assert(w, GUARD, JOB, PATROL);
    world_assert(w, GUARD, HP, 80);
    world_assert(w, GUARD, BASE_DAMAGE, 12);
    world_assert(w, GUARD, LOCATION, TOWN);
    world_assert(w, GUARD, IS_ALIVE, TRUE);
    world_assert(w, GUARD, GOLD, 5);
    world_assert(w, GUARD, PATROL_TARGET, FOREST);

    world_assert(w, MERCHANT, IS_A, NPC);
    world_assert(w, MERCHANT, JOB, sym("merchant_job"));
    world_assert(w, MERCHANT, HP, 30);
    world_assert(w, MERCHANT, LOCATION, MARKET);
    world_assert(w, MERCHANT, IS_ALIVE, TRUE);
    world_assert(w, MERCHANT, GOLD, 100);

    world_assert(w, WANDERER, IS_A, NPC);
    world_assert(w, WANDERER, JOB, IDLE);
    world_assert(w, WANDERER, HP, 20);
    world_assert(w, WANDERER, LOCATION, TOWN);
    world_assert(w, WANDERER, IS_ALIVE, TRUE);
    world_assert(w, WANDERER, GOLD, 3);

    world_assert(w, BANDIT, IS_A, NPC);
    world_assert(w, BANDIT, IS_A, COMBATANT);
    world_assert(w, BANDIT, IS_A, HOSTILE);
    world_assert(w, BANDIT, JOB, sym("bandit_job"));
    world_assert(w, BANDIT, HP, 40);
    world_assert(w, BANDIT, BASE_DAMAGE, 10);
    world_assert(w, BANDIT, LOCATION, CAVE);
    world_assert(w, BANDIT, IS_ALIVE, TRUE);
    world_assert(w, BANDIT, GOLD, 50);

    /* === RULES === */

    /* Rule 1: Player attacks enemies (ONCE PER TICK per target) */
    Rule* r = &w->rules[w->rule_count++];
    r->pattern_count = 5;
    r->patterns[0] = (Pattern){INPUT, ATTACK_CMD, TRUE};
    r->patterns[1] = (Pattern){PLAYER, LOCATION, VAR(0)};       /* ?loc */
    r->patterns[2] = (Pattern){PLAYER, BASE_DAMAGE, VAR(1)};    /* ?dmg */
    r->patterns[3] = (Pattern){VAR(2), IS_A, ENEMY};            /* ?e is_a enemy */
    r->patterns[4] = (Pattern){VAR(2), LOCATION, VAR(0)};       /* ?e at same loc */
    r->template_count = 1;
    r->templates[0] = (Template){VAR(2), PENDING_DAMAGE, VAR(1), 0};
    r->once_per_tick = 1;
    r->key_var_count = 1;
    r->key_vars[0] = 2;  /* key on ?e */

    /* Rule 2: Guard attacks enemies (ONCE PER TICK per target) */
    r = &w->rules[w->rule_count++];
    r->pattern_count = 4;
    r->patterns[0] = (Pattern){GUARD, LOCATION, VAR(0)};
    r->patterns[1] = (Pattern){GUARD, BASE_DAMAGE, VAR(1)};
    r->patterns[2] = (Pattern){VAR(2), IS_A, ENEMY};
    r->patterns[3] = (Pattern){VAR(2), LOCATION, VAR(0)};
    r->template_count = 1;
    r->templates[0] = (Template){VAR(2), PENDING_DAMAGE, VAR(1), 0};
    r->once_per_tick = 1;
    r->key_var_count = 1;
    r->key_vars[0] = 2;

    /* Rule 3: Apply damage (DEFERRED) */
    r = &w->rules[w->rule_count++];
    r->pattern_count = 3;
    r->patterns[0] = (Pattern){VAR(0), PENDING_DAMAGE, VAR(1)};  /* ?e pending_damage ?dmg */
    r->patterns[1] = (Pattern){VAR(0), HP, VAR(2)};              /* ?e hp ?hp */
    r->patterns[2] = (Pattern){VAR(0), IS_ALIVE, TRUE};
    r->template_count = 1;
    r->templates[0] = (Template){VAR(0), HP, 0, 1, {EXPR_SUB, 2, 1, 1, 1}};  /* hp = hp - dmg */
    r->retraction_count = 1;
    r->retractions[0] = (Pattern){VAR(0), PENDING_DAMAGE, VAR(1)};
    r->deferred = 1;

    /* Rule 4: Check death (DEFERRED) */
    r = &w->rules[w->rule_count++];
    r->pattern_count = 2;
    r->patterns[0] = (Pattern){VAR(0), HP, VAR(1)};
    r->patterns[1] = (Pattern){VAR(0), IS_ALIVE, TRUE};
    r->template_count = 1;
    r->templates[0] = (Template){VAR(0), IS_ALIVE, sym("false"), 0};
    r->guard = (Guard){GUARD_LE, 1, 0};  /* hp <= 0 */
    r->deferred = 1;

    /* Rule 5: Enemy counterattacks (ONCE PER TICK) */
    r = &w->rules[w->rule_count++];
    r->pattern_count = 5;
    r->patterns[0] = (Pattern){INPUT, ATTACK_CMD, TRUE};
    r->patterns[1] = (Pattern){VAR(0), IS_A, ENEMY};
    r->patterns[2] = (Pattern){VAR(0), LOCATION, VAR(1)};
    r->patterns[3] = (Pattern){VAR(0), BASE_DAMAGE, VAR(2)};
    r->patterns[4] = (Pattern){PLAYER, LOCATION, VAR(1)};
    r->template_count = 1;
    r->templates[0] = (Template){PLAYER, PENDING_DAMAGE, VAR(2), 0};
    r->once_per_tick = 1;
    r->key_var_count = 1;
    r->key_vars[0] = 0;

    /* Rule 6: Bandit attacks player (ONCE PER TICK) */
    r = &w->rules[w->rule_count++];
    r->pattern_count = 4;
    r->patterns[0] = (Pattern){BANDIT, LOCATION, VAR(0)};
    r->patterns[1] = (Pattern){BANDIT, BASE_DAMAGE, VAR(1)};
    r->patterns[2] = (Pattern){BANDIT, IS_ALIVE, TRUE};
    r->patterns[3] = (Pattern){PLAYER, LOCATION, VAR(0)};
    r->template_count = 1;
    r->templates[0] = (Template){PLAYER, PENDING_DAMAGE, VAR(1), 0};
    r->once_per_tick = 1;

    /* Rule 7: Merchant offers trade */
    r = &w->rules[w->rule_count++];
    r->pattern_count = 3;
    r->patterns[0] = (Pattern){MERCHANT, LOCATION, VAR(0)};
    r->patterns[1] = (Pattern){MERCHANT, IS_ALIVE, TRUE};
    r->patterns[2] = (Pattern){PLAYER, LOCATION, VAR(0)};
    r->template_count = 1;
    r->templates[0] = (Template){OUTPUT, TRADE_AVAILABLE, MERCHANT, 0};
    r->once_per_tick = 1;

    /* Rule 8: Guard moves toward patrol target (ONCE PER TICK) */
    r = &w->rules[w->rule_count++];
    r->pattern_count = 3;
    r->patterns[0] = (Pattern){GUARD, LOCATION, VAR(0)};       /* ?loc */
    r->patterns[1] = (Pattern){GUARD, PATROL_TARGET, VAR(1)};  /* ?dest */
    r->patterns[2] = (Pattern){VAR(0), CONNECTS_TO, VAR(1)};   /* loc connects dest */
    r->template_count = 1;
    r->templates[0] = (Template){GUARD, LOCATION, VAR(1), 0};
    r->once_per_tick = 1;
}

/* ============================================================
 * BENCHMARK
 * ============================================================ */

void run_benchmark(void) {
    printf("NPC Adventure Benchmark — C Runtime\n");
    printf("====================================\n\n");

    World* w = world_new();
    setup_npc_adventure(w);

    int ATTACK_CMD = sym("attack_cmd");
    int INPUT = sym("input");
    int TRUE = sym("true");
    int HP = sym("hp");
    int PLAYER = sym("player");
    int GOBLIN = sym("goblin");
    int WOLF = sym("wolf");
    int GUARD = sym("guard");
    int BANDIT = sym("bandit");
    int IS_ALIVE = sym("is_alive");
    int GOLD = sym("gold");

    printf("Initial state:\n");
    printf("  Rules: %d\n", w->rule_count);
    printf("  Facts: %d\n", w->fact_count);

    double tick_times[20];
    int tick_count = 0;

    /* Tick 1: Player attacks */
    printf("\nTick 1: Player attacks (forest)\n");
    world_assert(w, INPUT, ATTACK_CMD, TRUE);
    clock_t start = clock();
    world_tick(w, 100);
    tick_times[tick_count++] = (double)(clock() - start) * 1000.0 / CLOCKS_PER_SEC;

    /* Report status */
    int player_hp = 0, goblin_hp = 0, wolf_hp = 0;
    for (int i = 0; i < w->fact_count; i++) {
        Fact* f = &w->facts[i];
        if (!f->alive) continue;
        if (f->s == sym("player") && f->r == HP) player_hp = f->o;
        if (f->s == sym("goblin") && f->r == HP) goblin_hp = f->o;
        if (f->s == sym("wolf") && f->r == HP) wolf_hp = f->o;
    }
    printf("  Player HP: %d, Goblin HP: %d, Wolf HP: %d\n", player_hp, goblin_hp, wolf_hp);
    printf("  Time: %.3f ms\n", tick_times[tick_count-1]);

    /* Tick 2: Player attacks again */
    printf("\nTick 2: Player attacks again\n");
    world_assert(w, INPUT, ATTACK_CMD, TRUE);
    start = clock();
    world_tick(w, 100);
    tick_times[tick_count++] = (double)(clock() - start) * 1000.0 / CLOCKS_PER_SEC;

    /* Check if enemies dead */
    int goblin_alive = 0, wolf_alive = 0;
    for (int i = 0; i < w->fact_count; i++) {
        Fact* f = &w->facts[i];
        if (!f->alive) continue;
        if (f->s == sym("goblin") && f->r == IS_ALIVE && f->o == TRUE) goblin_alive = 1;
        if (f->s == sym("wolf") && f->r == IS_ALIVE && f->o == TRUE) wolf_alive = 1;
    }
    printf("  Goblin: %s, Wolf: %s\n", goblin_alive ? "alive" : "DEAD", wolf_alive ? "alive" : "DEAD");
    printf("  Time: %.3f ms\n", tick_times[tick_count-1]);

    /* Tick 3-4: Continue combat */
    for (int i = 0; i < 2; i++) {
        printf("\nTick %d: Combat continues\n", tick_count + 1);
        world_assert(w, INPUT, ATTACK_CMD, TRUE);
        start = clock();
        world_tick(w, 100);
        tick_times[tick_count++] = (double)(clock() - start) * 1000.0 / CLOCKS_PER_SEC;
        printf("  Time: %.3f ms\n", tick_times[tick_count-1]);
    }

    /* Summary */
    printf("\n====================================\n");
    printf("SUMMARY\n");
    printf("====================================\n");

    player_hp = 0;
    int player_gold = 0;
    for (int i = 0; i < w->fact_count; i++) {
        Fact* f = &w->facts[i];
        if (!f->alive) continue;
        if (f->s == PLAYER && f->r == HP) player_hp = f->o;
        if (f->s == PLAYER && f->r == GOLD) player_gold = f->o;
    }

    printf("  Player HP: %d\n", player_hp);
    printf("  Player Gold: %d\n", player_gold);
    printf("  Total Facts: %d (alive: ", w->fact_count);
    int alive_count = 0;
    for (int i = 0; i < w->fact_count; i++) if (w->facts[i].alive) alive_count++;
    printf("%d)\n", alive_count);

    double total_time = 0;
    for (int i = 0; i < tick_count; i++) total_time += tick_times[i];
    printf("\n  Tick times (ms):\n");
    for (int i = 0; i < tick_count; i++) printf("    Tick %d: %.3f\n", i + 1, tick_times[i]);
    printf("  Average: %.3f ms\n", total_time / tick_count);
    printf("  Total: %.3f ms\n", total_time);
    printf("\n  600ms budget: %s\n", (total_time / tick_count < 600) ? "PASS" : "FAIL");

    world_free(w);
}

int main(void) {
    run_benchmark();
    return 0;
}
