/*
 * HERB v2 Freestanding Runtime — The Tension Resolution Engine
 *
 * Zero libc dependencies. Compiles with -ffreestanding -nostdlib.
 * Identical logic and data structures to herb_runtime_v2.c.
 *
 * The ONLY external dependency is herb_freestanding.h, which provides:
 *   - Arena allocator (bump pointer, no free)
 *   - String/memory primitives
 *   - Number parsing
 *   - Minimal string formatting
 *
 * The runtime needs exactly three things from the outside world:
 *   1. A block of memory (the arena)
 *   2. The program JSON (as bytes in memory)
 *   3. A way to deliver signals (function calls)
 *
 * After loading, the tension resolution hot path performs ZERO allocations
 * and calls ZERO external functions. It operates entirely on the pre-built
 * graph in the arena.
 *
 * Entry points (called by the external environment):
 *   herb_init()     — initialize the runtime with arena + error handler
 *   herb_load()     — load a .herb.json program from memory
 *   herb_run()      — resolve tensions to fixpoint
 *   herb_step()     — one tension resolution cycle
 *   herb_create()   — create entity at runtime (for signals)
 *   herb_state()    — write state to a buffer
 */

#include "herb_freestanding.h"

/* ============================================================
 * CONFIGURATION
 * ============================================================ */

#define MAX_ENTITIES      1024
#define MAX_CONTAINERS    256
#define MAX_MOVE_TYPES    64
#define MAX_TENSIONS      64
#define MAX_MATCH_CLAUSES 8
#define MAX_EMIT_CLAUSES  8
#define MAX_STRINGS       2048
#define MAX_STRING_LEN    128
#define MAX_ENTITY_PER_CONTAINER 64
#define MAX_PROPERTIES    16
#define MAX_FROM_TO       16
#ifndef HERB_BINARY_ONLY
#define MAX_BINDINGS      32
#define MAX_BINDING_SETS  128
#define MAX_INTENDED_MOVES 128
#endif
#define MAX_STEPS         100
#define MAX_OPS           2048
#define MAX_SCOPE_TEMPLATES 16
#define MAX_CHANNELS      16
#define MAX_POOLS         16
#define MAX_TRANSFERS     16
#define MAX_EXPR_POOL     4096

/* ============================================================
 * GLOBAL ARENA
 *
 * All dynamic allocations (JSON parser, string duplication)
 * go through this arena. Set by herb_init().
 * ============================================================ */

static HerbArena* g_arena = HERB_NULL;


/* ============================================================
 * STRING INTERN TABLE
 * ============================================================ */

/* Non-static: accessible from assembly (boot/herb_graph.asm) */
char g_strings[MAX_STRINGS][MAX_STRING_LEN];
int g_string_count = 0;

#ifdef HERB_BINARY_ONLY
/* Assembly implementations in boot/herb_graph.asm */
extern int intern(const char* s);
extern const char* str_of(int id);
extern void container_add(int ci, int ei);
extern void container_remove(int ci, int ei);
#else
static int intern(const char* s) {
    for (int i = 0; i < g_string_count; i++) {
        if (herb_strcmp(g_strings[i], s) == 0) return i;
    }
    if (g_string_count >= MAX_STRINGS) {
        herb_error(HERB_ERR_FATAL, "string table full");
        return -1;
    }
    herb_strncpy(g_strings[g_string_count], s, MAX_STRING_LEN - 1);
    g_strings[g_string_count][MAX_STRING_LEN - 1] = '\0';
    return g_string_count++;
}

static const char* str_of(int id) {
    if (id >= 0 && id < g_string_count) return g_strings[id];
    return "?";
}
#endif /* !HERB_BINARY_ONLY — end of C intern/str_of */

/* ============================================================
 * PROPERTY VALUE
 * ============================================================ */

typedef enum { PV_NONE, PV_INT, PV_FLOAT, PV_STRING } PropType;

typedef struct {
    PropType type;
    union {
        int64_t i;
        double f;
        int s;  /* interned string */
    };
} PropVal;

/* entity_get_prop: always static C (inlinable).
 * Making this function non-inlinable (extern, noinline, or wrapper-to-extern)
 * causes 48 test failures. The assembly version returns correct values but GCC's caller
 * optimization changes when the function can't be inlined. */

#ifdef HERB_BINARY_ONLY
/* Assembly implementation in boot/herb_graph.asm — void return, PropVal by pointer (safe ABI) */
extern void entity_set_prop(int ei, int prop_id, PropVal val);
#endif

static PropVal pv_none(void) { PropVal v; v.type = PV_NONE; return v; }
static PropVal pv_int(int64_t i) { PropVal v; v.type = PV_INT; v.i = i; return v; }
static PropVal pv_float(double f) { PropVal v; v.type = PV_FLOAT; v.f = f; return v; }
static PropVal pv_string(int s) { PropVal v; v.type = PV_STRING; v.s = s; return v; }

static double pv_as_number(PropVal v) {
    if (v.type == PV_INT) return (double)v.i;
    if (v.type == PV_FLOAT) return v.f;
    return 0.0;
}

static int pv_is_truthy(PropVal v) {
    if (v.type == PV_NONE) return 0;
    if (v.type == PV_INT) return v.i != 0;
    if (v.type == PV_FLOAT) return v.f != 0.0;
    if (v.type == PV_STRING) return 1;
    return 0;
}

static int pv_equal(PropVal a, PropVal b) {
    if (a.type != b.type) {
        if ((a.type == PV_INT || a.type == PV_FLOAT) &&
            (b.type == PV_INT || b.type == PV_FLOAT))
            return pv_as_number(a) == pv_as_number(b);
        return 0;
    }
    if (a.type == PV_INT) return a.i == b.i;
    if (a.type == PV_FLOAT) return a.f == b.f;
    if (a.type == PV_STRING) return a.s == b.s;
    if (a.type == PV_NONE) return 1;
    return 0;
}

/* ============================================================
 * ENTITY
 * ============================================================ */

typedef struct {
    int id;
    int type_id;     /* interned type name */
    int name_id;     /* interned entity name */
    int prop_keys[MAX_PROPERTIES];
    PropVal prop_vals[MAX_PROPERTIES];
    int prop_count;
} Entity;

/* ============================================================
 * CONTAINER
 * ============================================================ */

typedef enum { CK_SIMPLE, CK_SLOT } ContainerKind;

typedef struct {
    int id;
    int name_id;        /* interned */
    ContainerKind kind;
    int entity_type;    /* interned type name, -1 if any */
    int entities[MAX_ENTITY_PER_CONTAINER];
    int entity_count;
    int owner;          /* entity index that owns this container, -1 = global */
} Container;

/* ============================================================
 * SCOPE TEMPLATE (defined on entity types)
 * ============================================================ */

typedef struct {
    int name_id;        /* interned scope container name */
    ContainerKind kind;
    int entity_type;    /* interned, -1 if any */
} ScopeTemplate;

/* ============================================================
 * MOVE TYPE
 * ============================================================ */

typedef struct {
    int name_id;
    int from_containers[MAX_FROM_TO];
    int from_count;
    int to_containers[MAX_FROM_TO];
    int to_count;
    int entity_type;    /* interned type name, -1 if any */
    /* Scoped move support */
    int is_scoped;
    int scoped_from_names[MAX_FROM_TO]; /* interned scope container names */
    int scoped_from_count;
    int scoped_to_names[MAX_FROM_TO];
    int scoped_to_count;
} MoveType;

/* ============================================================
 * EXPRESSION TREE
 * ============================================================ */

typedef enum {
    EX_INT, EX_FLOAT, EX_STRING, EX_BOOL,
    EX_PROP, EX_COUNT, EX_BINARY, EX_UNARY,
    EX_IN_OF,  /* {"in": "container", "of": "entity"} */
} ExprKind;

typedef struct Expr {
    ExprKind kind;
    union {
        int64_t int_val;
        double float_val;
        int string_id;
        int bool_val;
        struct { int prop_id; int of_id; } prop;
        struct {
            int container_idx;      /* -1 if scoped or channel */
            int is_scoped;
            int scope_bind_id;
            int scope_cname_id;
            int is_channel;
            int channel_idx;
        } count;
        struct { int op_id; struct Expr* left; struct Expr* right; } binary;
        struct { struct Expr* arg; } unary;
        struct { int container_idx; int entity_ref_id; } in_of;
    };
} Expr;

static Expr g_expr_pool[MAX_EXPR_POOL];
static int g_expr_count = 0;

static Expr* alloc_expr(void) {
    if (g_expr_count >= MAX_EXPR_POOL) {
        herb_error(HERB_ERR_FATAL, "expr pool full");
        return HERB_NULL;
    }
    Expr* e = &g_expr_pool[g_expr_count++];
    herb_memset(e, 0, sizeof(Expr));
    return e;
}

/* ============================================================
 * MATCH CLAUSE
 * ============================================================ */

typedef enum {
    MC_ENTITY_IN,
    MC_EMPTY_IN,
    MC_CONTAINER_IS,
    MC_GUARD,
} MatchKind;

typedef enum {
    SEL_FIRST, SEL_EACH, SEL_MAX_BY, SEL_MIN_BY,
} SelectMode;

typedef struct {
    MatchKind kind;
    int bind_id;
    int container_idx;      /* for MC_ENTITY_IN: graph container index, -1 if scoped/channel */
    int containers[MAX_FROM_TO];
    int container_count;
    SelectMode select;
    int key_prop_id;
    int required;
    int is_empty;
    int guard_container_idx;
    Expr* where_expr;
    Expr* guard_expr;
    /* Scoped container reference */
    int scope_bind_id;      /* -1 = not scoped */
    int scope_cname_id;     /* interned scope container name */
    /* Channel reference */
    int channel_idx;        /* -1 = not channel */
} MatchClause;

/* ============================================================
 * EMIT CLAUSE
 * ============================================================ */

typedef enum {
    EC_MOVE, EC_SET, EC_SEND, EC_RECEIVE, EC_TRANSFER, EC_DUPLICATE,
} EmitKind;

typedef struct {
    EmitKind kind;
    /* EC_MOVE */
    int move_type_idx;
    int entity_ref;
    int to_ref;             /* -1 if scoped to */
    int to_scope_bind_id;   /* -1 = not scoped */
    int to_scope_cname_id;
    /* EC_SET */
    int set_entity_ref;
    int set_prop_id;
    Expr* value_expr;
    /* EC_SEND */
    int send_channel_idx;
    int send_entity_ref;
    /* EC_RECEIVE */
    int recv_channel_idx;
    int recv_entity_ref;
    int recv_to_ref;            /* -1 if scoped */
    int recv_to_scope_bind_id;  /* -1 = not scoped */
    int recv_to_scope_cname_id;
    /* EC_TRANSFER */
    int transfer_type_idx;
    int transfer_from_ref;
    int transfer_to_ref;
    Expr* transfer_amount_expr;
    /* EC_DUPLICATE */
    int dup_entity_ref;
    int dup_in_ref;             /* -1 if scoped */
    int dup_in_scope_bind_id;   /* -1 = not scoped */
    int dup_in_scope_cname_id;
} EmitClause;

/* ============================================================
 * TENSION
 * ============================================================ */

typedef struct {
    int name_id;
    int priority;
    int enabled;    /* 1 = active (default), 0 = skipped during resolution */
    int owner;              /* -1 = system tension, >= 0 = entity index that owns this tension */
    int owner_run_container; /* -1 = no location check, >= 0 = owner must be in this container to fire */
    MatchClause matches[MAX_MATCH_CLAUSES];
    int match_count;
    EmitClause emits[MAX_EMIT_CLAUSES];
    int emit_count;
    int pair_mode;  /* 0 = zip, 1 = cross */
} Tension;

#ifndef HERB_BINARY_ONLY
/* ============================================================
 * INTENDED ACTION
 * ============================================================ */

typedef enum { IA_MOVE, IA_SET, IA_SEND, IA_RECEIVE, IA_TRANSFER, IA_DUPLICATE } IntendedKind;

typedef struct {
    IntendedKind kind;
    int move_type_idx;
    int entity_id;
    int to_container_idx;
    /* IA_SET */
    int set_entity_id;
    int set_prop_id;
    PropVal set_value;
    /* IA_SEND */
    int send_channel_idx;
    int send_entity_id;
    /* IA_RECEIVE */
    int recv_channel_idx;
    int recv_entity_id;
    int recv_to_container_idx;
    /* IA_TRANSFER */
    int transfer_type_idx;
    int transfer_from_entity;
    int transfer_to_entity;
    int64_t transfer_amount;
    /* IA_DUPLICATE */
    int dup_source_entity;
    int dup_container_idx;
} IntendedAction;
#endif

/* ============================================================
 * CHANNEL
 * ============================================================ */

typedef struct {
    int name_id;
    int sender_entity_idx;
    int receiver_entity_idx;
    int entity_type;        /* -1 if any */
    int buffer_container_idx;
} Channel;

/* ============================================================
 * CONSERVATION POOL
 * ============================================================ */

typedef struct {
    int name_id;
    int property_id;    /* interned property name */
} Pool;

/* ============================================================
 * TRANSFER TYPE
 * ============================================================ */

typedef struct {
    int name_id;
    int pool_idx;
    int entity_type;    /* -1 if any */
} TransferType;

/* ============================================================
 * THE GRAPH
 * ============================================================ */

typedef struct {
    Entity entities[MAX_ENTITIES];
    int entity_count;

    Container containers[MAX_CONTAINERS];
    int container_count;

    MoveType move_types[MAX_MOVE_TYPES];
    int move_type_count;

    Tension tensions[MAX_TENSIONS];
    int tension_count;

    int entity_location[MAX_ENTITIES];

    int type_names[64];
    int type_count;

    /* Scope templates per entity type */
    int type_scope_type_ids[64];
    ScopeTemplate type_scope_templates[64][MAX_SCOPE_TEMPLATES];
    int type_scope_counts[64];
    int type_scope_count;

    /* Entity scoped containers */
    int entity_scope_names[MAX_ENTITIES][MAX_SCOPE_TEMPLATES];
    int entity_scope_cids[MAX_ENTITIES][MAX_SCOPE_TEMPLATES];
    int entity_scope_count[MAX_ENTITIES];

    /* Channels */
    Channel channels[MAX_CHANNELS];
    int channel_count;

    /* Pools */
    Pool pools[MAX_POOLS];
    int pool_count;

    /* Transfers */
    TransferType transfer_types[MAX_TRANSFERS];
    int transfer_type_count;

    /* Nesting depth */
    int max_nesting_depth;  /* -1 = unlimited */

    /* Duplicate counter */
    int dup_counter;

    int op_count;
} Graph;

/* Non-static: accessible from assembly (boot/herb_graph.asm) */
Graph g_graph;

/* ============================================================
 * GRAPH OPERATIONS
 * ============================================================ */

static int graph_find_container_by_name(int name_id) {
    for (int i = 0; i < g_graph.container_count; i++) {
        if (g_graph.containers[i].name_id == name_id) return i;
    }
    return -1;
}

static int graph_find_entity_by_name(int name_id) {
    for (int i = 0; i < g_graph.entity_count; i++) {
        if (g_graph.entities[i].name_id == name_id) return i;
    }
    return -1;
}

static int graph_find_move_type_by_name(int name_id) {
    for (int i = 0; i < g_graph.move_type_count; i++) {
        if (g_graph.move_types[i].name_id == name_id) return i;
    }
    return -1;
}

static int graph_find_channel_by_name(int name_id) {
    for (int i = 0; i < g_graph.channel_count; i++) {
        if (g_graph.channels[i].name_id == name_id) return i;
    }
    return -1;
}

static int graph_find_transfer_by_name(int name_id) {
    for (int i = 0; i < g_graph.transfer_type_count; i++) {
        if (g_graph.transfer_types[i].name_id == name_id) return i;
    }
    return -1;
}

#ifndef HERB_BINARY_ONLY
static void container_add(int ci, int ei) {
    Container* c = &g_graph.containers[ci];
    if (c->entity_count < MAX_ENTITY_PER_CONTAINER) {
        c->entities[c->entity_count++] = ei;
    }
}

static void container_remove(int ci, int ei) {
    Container* c = &g_graph.containers[ci];
    for (int i = 0; i < c->entity_count; i++) {
        if (c->entities[i] == ei) {
            c->entities[i] = c->entities[--c->entity_count];
            return;
        }
    }
}
#endif /* container_add/remove guard */

static PropVal entity_get_prop(int ei, int prop_id) {
    Entity* e = &g_graph.entities[ei];
    for (int i = 0; i < e->prop_count; i++) {
        if (e->prop_keys[i] == prop_id) return e->prop_vals[i];
    }
    return pv_none();
}

#ifndef HERB_BINARY_ONLY
static void entity_set_prop(int ei, int prop_id, PropVal val) {
    Entity* e = &g_graph.entities[ei];
    for (int i = 0; i < e->prop_count; i++) {
        if (e->prop_keys[i] == prop_id) {
            e->prop_vals[i] = val;
            return;
        }
    }
    if (e->prop_count < MAX_PROPERTIES) {
        e->prop_keys[e->prop_count] = prop_id;
        e->prop_vals[e->prop_count] = val;
        e->prop_count++;
    }
}
#endif

/* Get scoped container for an entity by scope name */
static int get_scoped_container(int entity_idx, int scope_name_id) {
    if (entity_idx < 0 || entity_idx >= g_graph.entity_count) return -1;
    for (int i = 0; i < g_graph.entity_scope_count[entity_idx]; i++) {
        if (g_graph.entity_scope_names[entity_idx][i] == scope_name_id)
            return g_graph.entity_scope_cids[entity_idx][i];
    }
    return -1;
}

/* Get scope templates for an entity type */
static int get_type_scope_idx(int type_name_id) {
    for (int i = 0; i < g_graph.type_scope_count; i++) {
        if (g_graph.type_scope_type_ids[i] == type_name_id) return i;
    }
    return -1;
}

/* Create entity with auto-scoped container creation */
static int create_entity(int type_name_id, int name_id, int container_idx) {
    int ei = g_graph.entity_count++;
    Entity* e = &g_graph.entities[ei];
    e->id = ei;
    e->type_id = type_name_id;
    e->name_id = name_id;
    e->prop_count = 0;
    g_graph.entity_location[ei] = container_idx;
    g_graph.entity_scope_count[ei] = 0;

    if (container_idx >= 0) {
        container_add(container_idx, ei);
    }

    /* Auto-create scoped containers */
    int tsi = get_type_scope_idx(type_name_id);
    if (tsi >= 0) {
        const char* ent_name = str_of(name_id);
        int count = g_graph.type_scope_counts[tsi];
        for (int i = 0; i < count; i++) {
            ScopeTemplate* st = &g_graph.type_scope_templates[tsi][i];
            /* Create container with name "entity_name::scope_name" */
            char cname[256];
            herb_snprintf(cname, sizeof(cname), "%s::%s", ent_name, str_of(st->name_id));
            int ci = g_graph.container_count++;
            Container* c = &g_graph.containers[ci];
            c->id = ci;
            c->name_id = intern(cname);
            c->kind = st->kind;
            c->entity_type = st->entity_type;
            c->entity_count = 0;
            c->owner = ei;

            /* Track scope on entity */
            int si = g_graph.entity_scope_count[ei]++;
            g_graph.entity_scope_names[ei][si] = st->name_id;
            g_graph.entity_scope_cids[ei][si] = ci;
        }
    }

    return ei;
}

/* Check if a property is conserved (in a pool) */
static int is_property_pooled(int prop_id) {
    for (int i = 0; i < g_graph.pool_count; i++) {
        if (g_graph.pools[i].property_id == prop_id) return 1;
    }
    return 0;
}

/* Regular move: returns 1 if executed */
static int try_move(int mt_idx, int entity_idx, int to_container_idx) {
    MoveType* mt = &g_graph.move_types[mt_idx];
    Entity* e = &g_graph.entities[entity_idx];

    if (mt->is_scoped) {
        /* === SCOPED MOVE === */
        if (mt->entity_type >= 0 && e->type_id != mt->entity_type) return 0;

        int from = g_graph.entity_location[entity_idx];
        if (from < 0) return 0;

        /* Source must be in a scoped container */
        int from_owner = g_graph.containers[from].owner;
        if (from_owner < 0) return 0;

        /* Find source scope name */
        int from_scope_name = -1;
        for (int i = 0; i < g_graph.entity_scope_count[from_owner]; i++) {
            if (g_graph.entity_scope_cids[from_owner][i] == from) {
                from_scope_name = g_graph.entity_scope_names[from_owner][i];
                break;
            }
        }

        /* Check source scope name is in scoped_from */
        int from_ok = 0;
        for (int i = 0; i < mt->scoped_from_count; i++) {
            if (mt->scoped_from_names[i] == from_scope_name) { from_ok = 1; break; }
        }
        if (!from_ok) return 0;

        /* Target must be owned by SAME entity (isolation enforcement) */
        int to_owner = g_graph.containers[to_container_idx].owner;
        if (to_owner != from_owner) return 0;

        /* Find target scope name */
        int to_scope_name = -1;
        for (int i = 0; i < g_graph.entity_scope_count[to_owner]; i++) {
            if (g_graph.entity_scope_cids[to_owner][i] == to_container_idx) {
                to_scope_name = g_graph.entity_scope_names[to_owner][i];
                break;
            }
        }

        /* Check target scope name is in scoped_to */
        int to_ok = 0;
        for (int i = 0; i < mt->scoped_to_count; i++) {
            if (mt->scoped_to_names[i] == to_scope_name) { to_ok = 1; break; }
        }
        if (!to_ok) return 0;

        /* Slot constraint */
        Container* to = &g_graph.containers[to_container_idx];
        if (to->kind == CK_SLOT && to->entity_count > 0) return 0;
        if (to->entity_type >= 0 && e->type_id != to->entity_type) return 0;

        /* Execute */
        container_remove(from, entity_idx);
        container_add(to_container_idx, entity_idx);
        g_graph.entity_location[entity_idx] = to_container_idx;
        g_graph.op_count++;
        return 1;
    }

    /* === REGULAR MOVE === */
    if (mt->entity_type >= 0 && e->type_id != mt->entity_type) return 0;

    int from = g_graph.entity_location[entity_idx];
    if (from < 0) return 0;

    int from_ok = 0;
    for (int i = 0; i < mt->from_count; i++) {
        if (mt->from_containers[i] == from) { from_ok = 1; break; }
    }
    if (!from_ok) return 0;

    int to_ok = 0;
    for (int i = 0; i < mt->to_count; i++) {
        if (mt->to_containers[i] == to_container_idx) { to_ok = 1; break; }
    }
    if (!to_ok) return 0;

    Container* to = &g_graph.containers[to_container_idx];
    if (to->kind == CK_SLOT && to->entity_count > 0) return 0;
    if (to->entity_type >= 0 && e->type_id != to->entity_type) return 0;

    container_remove(from, entity_idx);
    container_add(to_container_idx, entity_idx);
    g_graph.entity_location[entity_idx] = to_container_idx;
    g_graph.op_count++;
    return 1;
}

/* Channel send: move entity from sender's scope to channel buffer */
static int do_channel_send(int ch_idx, int entity_idx) {
    Channel* ch = &g_graph.channels[ch_idx];

    if (ch->entity_type >= 0 &&
        g_graph.entities[entity_idx].type_id != ch->entity_type)
        return 0;

    int from = g_graph.entity_location[entity_idx];
    if (from < 0) return 0;

    /* Entity must be in a container owned by the sender */
    int from_owner = g_graph.containers[from].owner;
    if (from_owner != ch->sender_entity_idx) return 0;

    /* Move to channel buffer */
    container_remove(from, entity_idx);
    container_add(ch->buffer_container_idx, entity_idx);
    g_graph.entity_location[entity_idx] = ch->buffer_container_idx;
    g_graph.op_count++;
    return 1;
}

/* Channel receive: move entity from channel buffer to receiver's scope */
static int do_channel_receive(int ch_idx, int entity_idx, int to_container_idx) {
    Channel* ch = &g_graph.channels[ch_idx];

    /* Entity must be in channel buffer */
    int from = g_graph.entity_location[entity_idx];
    if (from != ch->buffer_container_idx) return 0;

    /* Target must be owned by receiver */
    int to_owner = g_graph.containers[to_container_idx].owner;
    if (to_owner != ch->receiver_entity_idx) return 0;

    /* Slot constraint */
    Container* to = &g_graph.containers[to_container_idx];
    if (to->kind == CK_SLOT && to->entity_count > 0) return 0;
    if (to->entity_type >= 0 &&
        g_graph.entities[entity_idx].type_id != to->entity_type) return 0;

    container_remove(from, entity_idx);
    container_add(to_container_idx, entity_idx);
    g_graph.entity_location[entity_idx] = to_container_idx;
    g_graph.op_count++;
    return 1;
}

#ifndef HERB_BINARY_ONLY
/* Quantity transfer */
static int do_transfer(int tt_idx, int from_entity, int to_entity, int64_t amount) {
    TransferType* tt = &g_graph.transfer_types[tt_idx];
    Pool* pool = &g_graph.pools[tt->pool_idx];

    if (tt->entity_type >= 0) {
        if (g_graph.entities[from_entity].type_id != tt->entity_type) return 0;
        if (g_graph.entities[to_entity].type_id != tt->entity_type) return 0;
    }

    if (from_entity == to_entity) return 0;
    if (amount <= 0) return 0;

    PropVal from_val = entity_get_prop(from_entity, pool->property_id);
    int64_t from_amount = (from_val.type == PV_INT) ? from_val.i :
                          (from_val.type == PV_FLOAT) ? (int64_t)from_val.f : 0;
    if (from_amount < amount) return 0;

    PropVal to_val = entity_get_prop(to_entity, pool->property_id);
    int64_t to_amount = (to_val.type == PV_INT) ? to_val.i :
                        (to_val.type == PV_FLOAT) ? (int64_t)to_val.f : 0;

    entity_set_prop(from_entity, pool->property_id, pv_int(from_amount - amount));
    entity_set_prop(to_entity, pool->property_id, pv_int(to_amount + amount));
    g_graph.op_count++;
    return 1;
}

/* Entity duplication */
static int do_duplicate(int source_idx, int container_idx) {
    Entity* src = &g_graph.entities[source_idx];

    g_graph.dup_counter++;
    char dup_name[64];
    herb_snprintf(dup_name, sizeof(dup_name), "_dup_%d", g_graph.dup_counter);

    int ei = g_graph.entity_count++;
    Entity* e = &g_graph.entities[ei];
    e->id = ei;
    e->type_id = src->type_id;
    e->name_id = intern(dup_name);
    e->prop_count = src->prop_count;
    herb_memcpy(e->prop_keys, src->prop_keys, sizeof(int) * src->prop_count);
    herb_memcpy(e->prop_vals, src->prop_vals, sizeof(PropVal) * src->prop_count);

    g_graph.entity_location[ei] = container_idx;
    g_graph.entity_scope_count[ei] = 0;
    if (container_idx >= 0) {
        container_add(container_idx, ei);
    }
    g_graph.op_count++;
    return ei;
}
#endif

#ifndef HERB_BINARY_ONLY
/* ============================================================
 * EXPRESSION EVALUATOR
 * ============================================================ */

typedef struct {
    int names[MAX_BINDINGS];
    int values[MAX_BINDINGS];
    int count;
    int unbound[MAX_BINDINGS];
    int unbound_count;
} Bindings;

static int bindings_get(Bindings* b, int name_id) {
    for (int i = 0; i < b->count; i++) {
        if (b->names[i] == name_id) return b->values[i];
    }
    return -1;
}

static int bindings_is_unbound(Bindings* b, int name_id) {
    for (int i = 0; i < b->unbound_count; i++) {
        if (b->unbound[i] == name_id) return 1;
    }
    return 0;
}

static int resolve_ref(int ref_id, Bindings* b) {
    int val = bindings_get(b, ref_id);
    if (val >= 0) return val;
    val = graph_find_entity_by_name(ref_id);
    if (val >= 0) return val;
    val = graph_find_container_by_name(ref_id);
    if (val >= 0) return val;
    return -1;
}

static int resolve_container_ref(int ref_id, Bindings* b) {
    int val = bindings_get(b, ref_id);
    if (val >= 0) return val;
    return graph_find_container_by_name(ref_id);
}

/* Resolve a scoped container reference from bindings */
static int resolve_scoped_ref(int scope_bind_id, int scope_cname_id, Bindings* b) {
    int scope_entity = bindings_get(b, scope_bind_id);
    if (scope_entity < 0) {
        scope_entity = graph_find_entity_by_name(scope_bind_id);
    }
    if (scope_entity < 0) return -1;
    return get_scoped_container(scope_entity, scope_cname_id);
}

static PropVal eval_expr(Expr* expr, Bindings* b) {
    if (!expr) return pv_none();

    switch (expr->kind) {
        case EX_INT:    return pv_int(expr->int_val);
        case EX_FLOAT:  return pv_float(expr->float_val);
        case EX_STRING: return pv_string(expr->string_id);
        case EX_BOOL:   return pv_int(expr->bool_val ? 1 : 0);

        case EX_PROP: {
            int of_ref = expr->prop.of_id;
            int ei = resolve_ref(of_ref, b);
            if (ei < 0) return pv_none();
            return entity_get_prop(ei, expr->prop.prop_id);
        }

        case EX_COUNT: {
            int ci = -1;
            if (expr->count.is_scoped) {
                ci = resolve_scoped_ref(expr->count.scope_bind_id,
                                        expr->count.scope_cname_id, b);
            } else if (expr->count.is_channel) {
                int ch_idx = expr->count.channel_idx;
                if (ch_idx >= 0 && ch_idx < g_graph.channel_count)
                    ci = g_graph.channels[ch_idx].buffer_container_idx;
            } else {
                ci = expr->count.container_idx;
            }
            if (ci < 0 || ci >= g_graph.container_count) return pv_none();
            return pv_int(g_graph.containers[ci].entity_count);
        }

        case EX_BINARY: {
            PropVal left = eval_expr(expr->binary.left, b);
            PropVal right = eval_expr(expr->binary.right, b);
            int op = expr->binary.op_id;

            if (left.type == PV_NONE || right.type == PV_NONE) return pv_none();

            double l = pv_as_number(left);
            double r = pv_as_number(right);

            static int op_add = -1, op_sub = -1, op_mul = -1;
            static int op_gt = -1, op_lt = -1, op_gte = -1, op_lte = -1;
            static int op_eq = -1, op_neq = -1, op_and = -1, op_or = -1;
            if (op_add < 0) {
                op_add = intern("+"); op_sub = intern("-"); op_mul = intern("*");
                op_gt = intern(">"); op_lt = intern("<");
                op_gte = intern(">="); op_lte = intern("<=");
                op_eq = intern("=="); op_neq = intern("!=");
                op_and = intern("and"); op_or = intern("or");
            }

            if (op == op_add) return pv_int((int64_t)(l + r));
            if (op == op_sub) return pv_int((int64_t)(l - r));
            if (op == op_mul) return pv_int((int64_t)(l * r));
            if (op == op_gt)  return pv_int(l > r ? 1 : 0);
            if (op == op_lt)  return pv_int(l < r ? 1 : 0);
            if (op == op_gte) return pv_int(l >= r ? 1 : 0);
            if (op == op_lte) return pv_int(l <= r ? 1 : 0);
            if (op == op_eq)  return pv_int(pv_equal(left, right) ? 1 : 0);
            if (op == op_neq) return pv_int(!pv_equal(left, right) ? 1 : 0);
            if (op == op_and) return pv_int((pv_is_truthy(left) && pv_is_truthy(right)) ? 1 : 0);
            if (op == op_or)  return pv_int((pv_is_truthy(left) || pv_is_truthy(right)) ? 1 : 0);

            return pv_none();
        }

        case EX_UNARY: {
            PropVal arg = eval_expr(expr->unary.arg, b);
            return pv_int(!pv_is_truthy(arg) ? 1 : 0);
        }

        case EX_IN_OF: {
            int ci = expr->in_of.container_idx;
            int ei = resolve_ref(expr->in_of.entity_ref_id, b);
            if (ei < 0 || ci < 0) return pv_int(0);
            Container* c = &g_graph.containers[ci];
            for (int i = 0; i < c->entity_count; i++) {
                if (c->entities[i] == ei) return pv_int(1);
            }
            return pv_int(0);
        }
    }

    return pv_none();
}

/* ============================================================
 * TENSION EVALUATOR
 * ============================================================ */

typedef struct {
    Bindings sets[MAX_BINDING_SETS];
    int count;
} BindingSetList;

static int evaluate_tension(Tension* t, IntendedAction* out, int max_out) {
    int action_count = 0;

    Bindings scalars;
    scalars.count = 0;
    scalars.unbound_count = 0;

    int vec_bind_ids[8];
    int vec_values[8][MAX_ENTITY_PER_CONTAINER];
    int vec_counts[8];
    int vec_count = 0;

    Expr* guards[8];
    int guard_count = 0;

    int failed = 0;

    for (int ci = 0; ci < t->match_count && !failed; ci++) {
        MatchClause* mc = &t->matches[ci];

        if (mc->kind == MC_GUARD) {
            guards[guard_count++] = mc->guard_expr;
            continue;
        }

        if (mc->kind == MC_CONTAINER_IS) {
            Container* c = &g_graph.containers[mc->guard_container_idx];
            if (mc->is_empty) {
                if (c->entity_count > 0) { if (mc->required) failed = 1; }
            } else {
                if (c->entity_count == 0) { if (mc->required) failed = 1; }
            }
            continue;
        }

        if (mc->kind == MC_ENTITY_IN) {
            /* Resolve container (may be scoped or channel) */
            int cid = mc->container_idx;
            if (mc->scope_bind_id >= 0) {
                cid = resolve_scoped_ref(mc->scope_bind_id, mc->scope_cname_id, &scalars);
                if (cid < 0) {
                    if (mc->required) { failed = 1; continue; }
                    if (mc->bind_id >= 0) {
                        scalars.unbound[scalars.unbound_count++] = mc->bind_id;
                    }
                    continue;
                }
            } else if (mc->channel_idx >= 0) {
                cid = g_graph.channels[mc->channel_idx].buffer_container_idx;
            }

            if (cid < 0 || cid >= g_graph.container_count) {
                if (mc->required) { failed = 1; continue; }
                if (mc->bind_id >= 0) {
                    scalars.unbound[scalars.unbound_count++] = mc->bind_id;
                }
                continue;
            }

            Container* c = &g_graph.containers[cid];
            int results[MAX_ENTITY_PER_CONTAINER];
            int rcount = 0;

            for (int i = 0; i < c->entity_count && rcount < MAX_ENTITY_PER_CONTAINER; i++) {
                results[rcount++] = c->entities[i];
            }
            /* Sort by entity index for determinism */
            for (int i = 0; i < rcount - 1; i++)
                for (int j = i + 1; j < rcount; j++)
                    if (results[i] > results[j]) {
                        int tmp = results[i]; results[i] = results[j]; results[j] = tmp;
                    }

            /* Apply "where" filter */
            if (mc->where_expr && mc->bind_id >= 0) {
                int filtered[MAX_ENTITY_PER_CONTAINER];
                int fcount = 0;
                for (int i = 0; i < rcount; i++) {
                    Bindings test_b;
                    herb_memcpy(&test_b, &scalars, sizeof(Bindings));
                    test_b.names[test_b.count] = mc->bind_id;
                    test_b.values[test_b.count] = results[i];
                    test_b.count++;
                    PropVal result = eval_expr(mc->where_expr, &test_b);
                    if (pv_is_truthy(result)) {
                        filtered[fcount++] = results[i];
                    }
                }
                rcount = fcount;
                herb_memcpy(results, filtered, sizeof(int) * fcount);
            }

            if (rcount == 0) {
                if (mc->required) { failed = 1; continue; }
                if (mc->bind_id >= 0) {
                    scalars.unbound[scalars.unbound_count++] = mc->bind_id;
                }
                continue;
            }

            if (mc->bind_id >= 0) {
                if (mc->select == SEL_FIRST) {
                    scalars.names[scalars.count] = mc->bind_id;
                    scalars.values[scalars.count] = results[0];
                    scalars.count++;
                } else if (mc->select == SEL_EACH) {
                    vec_bind_ids[vec_count] = mc->bind_id;
                    vec_counts[vec_count] = rcount;
                    herb_memcpy(vec_values[vec_count], results, sizeof(int) * rcount);
                    vec_count++;
                } else if (mc->select == SEL_MAX_BY || mc->select == SEL_MIN_BY) {
                    int best = results[0];
                    double best_val = pv_as_number(entity_get_prop(results[0], mc->key_prop_id));
                    for (int i = 1; i < rcount; i++) {
                        double v = pv_as_number(entity_get_prop(results[i], mc->key_prop_id));
                        if (mc->select == SEL_MAX_BY ? v > best_val : v < best_val) {
                            best = results[i];
                            best_val = v;
                        }
                    }
                    scalars.names[scalars.count] = mc->bind_id;
                    scalars.values[scalars.count] = best;
                    scalars.count++;
                }
            }
            continue;
        }

        if (mc->kind == MC_EMPTY_IN) {
            int empty[MAX_FROM_TO];
            int ecount = 0;
            for (int i = 0; i < mc->container_count; i++) {
                Container* c = &g_graph.containers[mc->containers[i]];
                if (c->entity_count == 0) {
                    empty[ecount++] = mc->containers[i];
                }
            }

            if (ecount == 0) {
                if (mc->required) { failed = 1; continue; }
                if (mc->bind_id >= 0) {
                    scalars.unbound[scalars.unbound_count++] = mc->bind_id;
                }
                continue;
            }

            if (mc->bind_id >= 0) {
                if (mc->select == SEL_FIRST) {
                    scalars.names[scalars.count] = mc->bind_id;
                    scalars.values[scalars.count] = empty[0];
                    scalars.count++;
                } else if (mc->select == SEL_EACH) {
                    vec_bind_ids[vec_count] = mc->bind_id;
                    vec_counts[vec_count] = ecount;
                    herb_memcpy(vec_values[vec_count], empty, sizeof(int) * ecount);
                    vec_count++;
                }
            }
            continue;
        }
    }

    if (failed) return 0;

    /* Build binding sets */
    BindingSetList bsl;
    bsl.count = 0;

    if (vec_count == 0) {
        bsl.sets[0] = scalars;
        bsl.count = 1;
    } else if (t->pair_mode == 0) {
        int min_len = vec_counts[0];
        for (int v = 1; v < vec_count; v++)
            if (vec_counts[v] < min_len) min_len = vec_counts[v];
        for (int i = 0; i < min_len && bsl.count < MAX_BINDING_SETS; i++) {
            Bindings bs;
            herb_memcpy(&bs, &scalars, sizeof(Bindings));
            for (int v = 0; v < vec_count; v++) {
                bs.names[bs.count] = vec_bind_ids[v];
                bs.values[bs.count] = vec_values[v][i];
                bs.count++;
            }
            bsl.sets[bsl.count++] = bs;
        }
    } else {
        if (vec_count == 1) {
            for (int i = 0; i < vec_counts[0] && bsl.count < MAX_BINDING_SETS; i++) {
                Bindings bs;
                herb_memcpy(&bs, &scalars, sizeof(Bindings));
                bs.names[bs.count] = vec_bind_ids[0];
                bs.values[bs.count] = vec_values[0][i];
                bs.count++;
                bsl.sets[bsl.count++] = bs;
            }
        } else if (vec_count == 2) {
            for (int i = 0; i < vec_counts[0]; i++)
                for (int j = 0; j < vec_counts[1] && bsl.count < MAX_BINDING_SETS; j++) {
                    Bindings bs;
                    herb_memcpy(&bs, &scalars, sizeof(Bindings));
                    bs.names[bs.count] = vec_bind_ids[0];
                    bs.values[bs.count] = vec_values[0][i];
                    bs.count++;
                    bs.names[bs.count] = vec_bind_ids[1];
                    bs.values[bs.count] = vec_values[1][j];
                    bs.count++;
                    bsl.sets[bsl.count++] = bs;
                }
        }
    }

    /* Filter by expression guards */
    if (guard_count > 0) {
        BindingSetList filtered;
        filtered.count = 0;
        for (int i = 0; i < bsl.count; i++) {
            int pass = 1;
            for (int g = 0; g < guard_count; g++) {
                PropVal result = eval_expr(guards[g], &bsl.sets[i]);
                if (!pv_is_truthy(result)) { pass = 0; break; }
            }
            if (pass) filtered.sets[filtered.count++] = bsl.sets[i];
        }
        bsl = filtered;
    }

    /* Generate actions from emit clauses */
    for (int si = 0; si < bsl.count; si++) {
        Bindings* b = &bsl.sets[si];

        for (int ei = 0; ei < t->emit_count && action_count < max_out; ei++) {
            EmitClause* ec = &t->emits[ei];

            if (ec->kind == EC_MOVE) {
                int entity_idx = resolve_ref(ec->entity_ref, b);
                if (entity_idx < 0) continue;
                if (bindings_is_unbound(b, ec->entity_ref)) continue;

                int to_idx;
                if (ec->to_scope_bind_id >= 0) {
                    to_idx = resolve_scoped_ref(ec->to_scope_bind_id,
                                                ec->to_scope_cname_id, b);
                } else {
                    to_idx = resolve_container_ref(ec->to_ref, b);
                }
                if (to_idx < 0) continue;

                IntendedAction* ia = &out[action_count++];
                herb_memset(ia, 0, sizeof(IntendedAction));
                ia->kind = IA_MOVE;
                ia->move_type_idx = ec->move_type_idx;
                ia->entity_id = entity_idx;
                ia->to_container_idx = to_idx;
            }
            else if (ec->kind == EC_SET) {
                int entity_idx = resolve_ref(ec->set_entity_ref, b);
                if (entity_idx < 0) continue;
                if (bindings_is_unbound(b, ec->set_entity_ref)) continue;

                PropVal val = eval_expr(ec->value_expr, b);
                if (val.type == PV_NONE) continue;

                IntendedAction* ia = &out[action_count++];
                herb_memset(ia, 0, sizeof(IntendedAction));
                ia->kind = IA_SET;
                ia->set_entity_id = entity_idx;
                ia->set_prop_id = ec->set_prop_id;
                ia->set_value = val;
            }
            else if (ec->kind == EC_SEND) {
                int entity_idx = resolve_ref(ec->send_entity_ref, b);
                if (entity_idx < 0) continue;
                if (bindings_is_unbound(b, ec->send_entity_ref)) continue;

                IntendedAction* ia = &out[action_count++];
                herb_memset(ia, 0, sizeof(IntendedAction));
                ia->kind = IA_SEND;
                ia->send_channel_idx = ec->send_channel_idx;
                ia->send_entity_id = entity_idx;
            }
            else if (ec->kind == EC_RECEIVE) {
                int entity_idx = resolve_ref(ec->recv_entity_ref, b);
                if (entity_idx < 0) continue;
                if (bindings_is_unbound(b, ec->recv_entity_ref)) continue;

                int to_idx;
                if (ec->recv_to_scope_bind_id >= 0) {
                    to_idx = resolve_scoped_ref(ec->recv_to_scope_bind_id,
                                                ec->recv_to_scope_cname_id, b);
                } else {
                    to_idx = resolve_container_ref(ec->recv_to_ref, b);
                }
                if (to_idx < 0) continue;

                IntendedAction* ia = &out[action_count++];
                herb_memset(ia, 0, sizeof(IntendedAction));
                ia->kind = IA_RECEIVE;
                ia->recv_channel_idx = ec->recv_channel_idx;
                ia->recv_entity_id = entity_idx;
                ia->recv_to_container_idx = to_idx;
            }
            else if (ec->kind == EC_TRANSFER) {
                int from_idx = resolve_ref(ec->transfer_from_ref, b);
                if (from_idx < 0) continue;
                int to_idx = resolve_ref(ec->transfer_to_ref, b);
                if (to_idx < 0) continue;

                PropVal amt = eval_expr(ec->transfer_amount_expr, b);
                if (amt.type == PV_NONE) continue;

                IntendedAction* ia = &out[action_count++];
                herb_memset(ia, 0, sizeof(IntendedAction));
                ia->kind = IA_TRANSFER;
                ia->transfer_type_idx = ec->transfer_type_idx;
                ia->transfer_from_entity = from_idx;
                ia->transfer_to_entity = to_idx;
                ia->transfer_amount = (int64_t)pv_as_number(amt);
            }
            else if (ec->kind == EC_DUPLICATE) {
                int entity_idx = resolve_ref(ec->dup_entity_ref, b);
                if (entity_idx < 0) continue;
                if (bindings_is_unbound(b, ec->dup_entity_ref)) continue;

                int in_idx;
                if (ec->dup_in_scope_bind_id >= 0) {
                    in_idx = resolve_scoped_ref(ec->dup_in_scope_bind_id,
                                                ec->dup_in_scope_cname_id, b);
                } else {
                    in_idx = resolve_container_ref(ec->dup_in_ref, b);
                }
                if (in_idx < 0) continue;

                IntendedAction* ia = &out[action_count++];
                herb_memset(ia, 0, sizeof(IntendedAction));
                ia->kind = IA_DUPLICATE;
                ia->dup_source_entity = entity_idx;
                ia->dup_container_idx = in_idx;
            }
        }
    }

    return action_count;
}

/* ============================================================
 * STEP / RUN — THE HOT PATH
 *
 * After this point, ZERO libc calls occur. The tension resolution
 * loop operates entirely on the pre-built graph using only
 * herb_memset and herb_memcpy from the freestanding layer.
 * ============================================================ */

int herb_step(void) {
    int order[MAX_TENSIONS];
    for (int i = 0; i < g_graph.tension_count; i++) order[i] = i;
    for (int i = 0; i < g_graph.tension_count - 1; i++)
        for (int j = i + 1; j < g_graph.tension_count; j++)
            if (g_graph.tensions[order[i]].priority < g_graph.tensions[order[j]].priority) {
                int tmp = order[i]; order[i] = order[j]; order[j] = tmp;
            }

    int total_executed = 0;
    IntendedAction actions[MAX_INTENDED_MOVES];

    for (int ti = 0; ti < g_graph.tension_count; ti++) {
        int idx = order[ti];
        if (!g_graph.tensions[idx].enabled) continue;
        /* Owner check: process-owned tensions only fire when owner is in run container */
        if (g_graph.tensions[idx].owner >= 0) {
            int ownr = g_graph.tensions[idx].owner;
            int run_c = g_graph.tensions[idx].owner_run_container;
            if (run_c >= 0 && g_graph.entity_location[ownr] != run_c) continue;
        }
        int count = evaluate_tension(&g_graph.tensions[idx], actions, MAX_INTENDED_MOVES);

        for (int ai = 0; ai < count; ai++) {
            IntendedAction* ia = &actions[ai];
            if (ia->kind == IA_MOVE) {
                if (try_move(ia->move_type_idx, ia->entity_id, ia->to_container_idx)) {
                    total_executed++;
                }
            } else if (ia->kind == IA_SET) {
                /* Pool protection: conserved properties only change via transfer */
                if (is_property_pooled(ia->set_prop_id)) continue;
                entity_set_prop(ia->set_entity_id, ia->set_prop_id, ia->set_value);
                g_graph.op_count++;
                total_executed++;
            } else if (ia->kind == IA_SEND) {
                if (do_channel_send(ia->send_channel_idx, ia->send_entity_id)) {
                    total_executed++;
                }
            } else if (ia->kind == IA_RECEIVE) {
                if (do_channel_receive(ia->recv_channel_idx, ia->recv_entity_id,
                                       ia->recv_to_container_idx)) {
                    total_executed++;
                }
            } else if (ia->kind == IA_TRANSFER) {
                if (do_transfer(ia->transfer_type_idx, ia->transfer_from_entity,
                                ia->transfer_to_entity, ia->transfer_amount)) {
                    total_executed++;
                }
            } else if (ia->kind == IA_DUPLICATE) {
                if (do_duplicate(ia->dup_source_entity, ia->dup_container_idx) >= 0) {
                    total_executed++;
                }
            }
        }
    }

    return total_executed;
}

int herb_run(int max_steps) {
    int total = 0;
    for (int i = 0; i < max_steps; i++) {
        int executed = herb_step();
        if (executed == 0) break;
        total += executed;
    }
    return total;
}

/* ============================================================
 * MINIMAL JSON PARSER (arena-allocated)
 *
 * Identical logic to the libc version, but all allocations
 * go through the arena instead of malloc/calloc/realloc.
 * The JSON tree is parse-time-only — after load_program()
 * processes it, the arena memory it consumed is still
 * allocated but no longer referenced (the graph has been
 * built in static arrays).
 *
 * Compile with -DHERB_BINARY_ONLY to exclude this entire
 * section and the JSON load path. The binary loader handles
 * everything the bare-metal build needs.
 * ============================================================ */

typedef enum {
    JT_NULL, JT_BOOL, JT_INT, JT_FLOAT, JT_STRING,
    JT_ARRAY, JT_OBJECT,
} JsonType;

typedef struct JsonValue {
    JsonType type;
    union {
        int bool_val;
        int64_t int_val;
        double float_val;
        char* string_val;
        struct { struct JsonValue** items; int count; int cap; } array;
        struct { char** keys; struct JsonValue** values; int count; int cap; } object;
    };
} JsonValue;

static const char* json_skip_ws(const char* p) {
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    return p;
}

static JsonValue* json_alloc(void) {
    JsonValue* v = (JsonValue*)herb_arena_calloc(g_arena, 1, sizeof(JsonValue));
    return v;
}

static const char* json_parse_value(const char* p, JsonValue** out);

static const char* json_parse_string_raw(const char* p, char** out) {
    if (*p != '"') return HERB_NULL;
    p++;
    char buf[4096];
    int bi = 0;
    while (*p && *p != '"' && bi < 4095) {
        if (*p == '\\') {
            p++;
            if (*p == '"') buf[bi++] = '"';
            else if (*p == '\\') buf[bi++] = '\\';
            else if (*p == 'n') buf[bi++] = '\n';
            else if (*p == 't') buf[bi++] = '\t';
            else if (*p == '/') buf[bi++] = '/';
            else buf[bi++] = *p;
            p++;
        } else {
            buf[bi++] = *p++;
        }
    }
    buf[bi] = '\0';
    if (*p == '"') p++;
    *out = herb_strdup(g_arena, buf);
    return p;
}

static const char* json_parse_number(const char* p, JsonValue** out) {
    JsonValue* v = json_alloc();
    char buf[64];
    int bi = 0;
    int is_float = 0;
    if (*p == '-') buf[bi++] = *p++;
    while (*p >= '0' && *p <= '9') buf[bi++] = *p++;
    if (*p == '.') { is_float = 1; buf[bi++] = *p++; while (*p >= '0' && *p <= '9') buf[bi++] = *p++; }
    if (*p == 'e' || *p == 'E') { is_float = 1; buf[bi++] = *p++; if (*p == '+' || *p == '-') buf[bi++] = *p++; while (*p >= '0' && *p <= '9') buf[bi++] = *p++; }
    buf[bi] = '\0';
    if (is_float) { v->type = JT_FLOAT; v->float_val = herb_atof(buf); }
    else { v->type = JT_INT; v->int_val = herb_atoll(buf); }
    *out = v;
    return p;
}

static const char* json_parse_value(const char* p, JsonValue** out) {
    p = json_skip_ws(p);
    if (!*p) return HERB_NULL;

    if (*p == '"') {
        JsonValue* v = json_alloc();
        v->type = JT_STRING;
        p = json_parse_string_raw(p, &v->string_val);
        *out = v;
        return p;
    }

    if (*p == '-' || (*p >= '0' && *p <= '9')) {
        return json_parse_number(p, out);
    }

    if (herb_strncmp(p, "true", 4) == 0) {
        JsonValue* v = json_alloc();
        v->type = JT_BOOL; v->bool_val = 1;
        *out = v; return p + 4;
    }
    if (herb_strncmp(p, "false", 5) == 0) {
        JsonValue* v = json_alloc();
        v->type = JT_BOOL; v->bool_val = 0;
        *out = v; return p + 5;
    }
    if (herb_strncmp(p, "null", 4) == 0) {
        JsonValue* v = json_alloc();
        v->type = JT_NULL;
        *out = v; return p + 4;
    }

    if (*p == '[') {
        p++;
        JsonValue* v = json_alloc();
        v->type = JT_ARRAY;
        v->array.cap = 16;
        v->array.items = (JsonValue**)herb_arena_calloc(g_arena, v->array.cap, sizeof(JsonValue*));
        v->array.count = 0;
        p = json_skip_ws(p);
        if (*p != ']') {
            while (1) {
                JsonValue* item;
                p = json_parse_value(p, &item);
                if (!p) return HERB_NULL;
                if (v->array.count >= v->array.cap) {
                    int new_cap = v->array.cap * 2;
                    JsonValue** new_items = (JsonValue**)herb_arena_alloc(g_arena, sizeof(JsonValue*) * new_cap);
                    if (!new_items) return HERB_NULL;
                    herb_memcpy(new_items, v->array.items, sizeof(JsonValue*) * v->array.count);
                    /* Old items are in the arena — no free needed, just abandoned */
                    v->array.items = new_items;
                    v->array.cap = new_cap;
                }
                v->array.items[v->array.count++] = item;
                p = json_skip_ws(p);
                if (*p == ',') { p++; continue; }
                break;
            }
        }
        p = json_skip_ws(p);
        if (*p == ']') p++;
        *out = v;
        return p;
    }

    if (*p == '{') {
        p++;
        JsonValue* v = json_alloc();
        v->type = JT_OBJECT;
        v->object.cap = 16;
        v->object.keys = (char**)herb_arena_alloc(g_arena, sizeof(char*) * v->object.cap);
        v->object.values = (JsonValue**)herb_arena_alloc(g_arena, sizeof(JsonValue*) * v->object.cap);
        v->object.count = 0;
        p = json_skip_ws(p);
        if (*p != '}') {
            while (1) {
                p = json_skip_ws(p);
                char* key;
                p = json_parse_string_raw(p, &key);
                if (!p) return HERB_NULL;
                p = json_skip_ws(p);
                if (*p == ':') p++;
                JsonValue* val;
                p = json_parse_value(p, &val);
                if (!p) return HERB_NULL;
                if (v->object.count >= v->object.cap) {
                    int new_cap = v->object.cap * 2;
                    char** new_keys = (char**)herb_arena_alloc(g_arena, sizeof(char*) * new_cap);
                    JsonValue** new_vals = (JsonValue**)herb_arena_alloc(g_arena, sizeof(JsonValue*) * new_cap);
                    if (!new_keys || !new_vals) return HERB_NULL;
                    herb_memcpy(new_keys, v->object.keys, sizeof(char*) * v->object.count);
                    herb_memcpy(new_vals, v->object.values, sizeof(JsonValue*) * v->object.count);
                    v->object.keys = new_keys;
                    v->object.values = new_vals;
                    v->object.cap = new_cap;
                }
                v->object.keys[v->object.count] = key;
                v->object.values[v->object.count] = val;
                v->object.count++;
                p = json_skip_ws(p);
                if (*p == ',') { p++; continue; }
                break;
            }
        }
        p = json_skip_ws(p);
        if (*p == '}') p++;
        *out = v;
        return p;
    }

    return HERB_NULL;
}

static JsonValue* json_get(JsonValue* obj, const char* key) {
    if (!obj || obj->type != JT_OBJECT) return HERB_NULL;
    for (int i = 0; i < obj->object.count; i++) {
        if (herb_strcmp(obj->object.keys[i], key) == 0)
            return obj->object.values[i];
    }
    return HERB_NULL;
}

static const char* json_str(JsonValue* v) {
    if (!v || v->type != JT_STRING) return HERB_NULL;
    return v->string_val;
}

static int64_t json_int(JsonValue* v) {
    if (!v) return 0;
    if (v->type == JT_INT) return v->int_val;
    if (v->type == JT_FLOAT) return (int64_t)v->float_val;
    return 0;
}

static int json_array_len(JsonValue* v) {
    if (!v || v->type != JT_ARRAY) return 0;
    return v->array.count;
}

static JsonValue* json_array_get(JsonValue* v, int i) {
    if (!v || v->type != JT_ARRAY || i < 0 || i >= v->array.count) return HERB_NULL;
    return v->array.items[i];
}

static int json_bool(JsonValue* v) {
    if (!v) return 1;
    if (v->type == JT_BOOL) return v->bool_val;
    if (v->type == JT_INT) return v->int_val != 0;
    return 1;
}

/* ============================================================
 * BUILD EXPRESSION FROM JSON
 * ============================================================ */

static Expr* build_expr(JsonValue* jv) {
    if (!jv) return HERB_NULL;

    if (jv->type == JT_INT) {
        Expr* e = alloc_expr();
        e->kind = EX_INT; e->int_val = jv->int_val; return e;
    }
    if (jv->type == JT_FLOAT) {
        Expr* e = alloc_expr();
        e->kind = EX_FLOAT; e->float_val = jv->float_val; return e;
    }
    if (jv->type == JT_STRING) {
        Expr* e = alloc_expr();
        e->kind = EX_STRING; e->string_id = intern(jv->string_val); return e;
    }
    if (jv->type == JT_BOOL) {
        Expr* e = alloc_expr();
        e->kind = EX_BOOL; e->bool_val = jv->bool_val; return e;
    }

    if (jv->type == JT_OBJECT) {
        /* Property access: {"prop": "name", "of": "ref"} */
        JsonValue* prop = json_get(jv, "prop");
        if (prop) {
            Expr* e = alloc_expr();
            e->kind = EX_PROP;
            e->prop.prop_id = intern(json_str(prop));
            JsonValue* of = json_get(jv, "of");
            e->prop.of_id = of ? intern(json_str(of)) : -1;
            return e;
        }

        /* Count: {"count": "name"} or {"count": {"scope":..}} or {"count": {"channel":..}} */
        JsonValue* count = json_get(jv, "count");
        if (count) {
            Expr* e = alloc_expr();
            e->kind = EX_COUNT;
            e->count.container_idx = -1;
            e->count.is_scoped = 0;
            e->count.is_channel = 0;

            if (count->type == JT_OBJECT) {
                JsonValue* scope = json_get(count, "scope");
                JsonValue* channel = json_get(count, "channel");
                if (scope) {
                    e->count.is_scoped = 1;
                    e->count.scope_bind_id = intern(json_str(scope));
                    JsonValue* sc = json_get(count, "container");
                    e->count.scope_cname_id = sc ? intern(json_str(sc)) : -1;
                } else if (channel) {
                    e->count.is_channel = 1;
                    e->count.channel_idx = graph_find_channel_by_name(intern(json_str(channel)));
                }
            } else if (count->type == JT_STRING) {
                e->count.container_idx = graph_find_container_by_name(intern(count->string_val));
            }
            return e;
        }

        /* Dimensional check: {"in": "container", "of": "entity"} */
        JsonValue* in_check = json_get(jv, "in");
        JsonValue* of_check = json_get(jv, "of");
        if (in_check && of_check && in_check->type == JT_STRING && of_check->type == JT_STRING) {
            /* Only if no "op" key — distinguish from other uses of "in" */
            if (!json_get(jv, "op")) {
                Expr* e = alloc_expr();
                e->kind = EX_IN_OF;
                e->in_of.container_idx = graph_find_container_by_name(intern(in_check->string_val));
                e->in_of.entity_ref_id = intern(of_check->string_val);
                return e;
            }
        }

        /* Binary/unary: {"op": "...", ...} */
        JsonValue* op = json_get(jv, "op");
        if (op) {
            const char* op_str = json_str(op);
            if (herb_strcmp(op_str, "not") == 0) {
                Expr* e = alloc_expr();
                e->kind = EX_UNARY;
                e->unary.arg = build_expr(json_get(jv, "arg"));
                return e;
            }
            Expr* e = alloc_expr();
            e->kind = EX_BINARY;
            e->binary.op_id = intern(op_str);
            e->binary.left = build_expr(json_get(jv, "left"));
            e->binary.right = build_expr(json_get(jv, "right"));
            return e;
        }
    }

    return HERB_NULL;
}

/* ============================================================
 * LOAD PROGRAM FROM JSON
 * ============================================================ */

static void load_program(JsonValue* root) {
    herb_memset(&g_graph, 0, sizeof(Graph));
    for (int i = 0; i < MAX_ENTITIES; i++) g_graph.entity_location[i] = -1;
    g_graph.max_nesting_depth = -1;

    /* Initialize all container owners to -1 (global) */
    for (int i = 0; i < MAX_CONTAINERS; i++) g_graph.containers[i].owner = -1;

    /* 1. Entity types */
    JsonValue* types = json_get(root, "entity_types");
    for (int i = 0; i < json_array_len(types); i++) {
        JsonValue* et = json_array_get(types, i);
        const char* name = json_str(json_get(et, "name"));
        int tid = intern(name);
        g_graph.type_names[g_graph.type_count++] = tid;

        /* Scoped container templates */
        JsonValue* scoped = json_get(et, "scoped_containers");
        if (scoped && json_array_len(scoped) > 0) {
            int tsi = g_graph.type_scope_count++;
            g_graph.type_scope_type_ids[tsi] = tid;
            g_graph.type_scope_counts[tsi] = 0;
            for (int j = 0; j < json_array_len(scoped); j++) {
                JsonValue* sc = json_array_get(scoped, j);
                ScopeTemplate* st = &g_graph.type_scope_templates[tsi][g_graph.type_scope_counts[tsi]++];
                st->name_id = intern(json_str(json_get(sc, "name")));
                const char* kind_str = json_str(json_get(sc, "kind"));
                st->kind = CK_SIMPLE;
                if (kind_str && herb_strcmp(kind_str, "slot") == 0) st->kind = CK_SLOT;
                const char* et_name = json_str(json_get(sc, "entity_type"));
                st->entity_type = et_name ? intern(et_name) : -1;
            }
        }
    }

    /* 2. Containers */
    JsonValue* containers = json_get(root, "containers");
    for (int i = 0; i < json_array_len(containers); i++) {
        JsonValue* jc = json_array_get(containers, i);
        const char* name = json_str(json_get(jc, "name"));
        const char* kind_str = json_str(json_get(jc, "kind"));
        const char* et_name = json_str(json_get(jc, "entity_type"));

        int ci = g_graph.container_count++;
        Container* c = &g_graph.containers[ci];
        c->id = ci;
        c->name_id = intern(name);
        c->kind = CK_SIMPLE;
        if (kind_str && herb_strcmp(kind_str, "slot") == 0) c->kind = CK_SLOT;
        c->entity_type = et_name ? intern(et_name) : -1;
        c->entity_count = 0;
        c->owner = -1;
    }

    /* 3. Moves (regular and scoped) */
    JsonValue* moves = json_get(root, "moves");
    for (int i = 0; i < json_array_len(moves); i++) {
        JsonValue* jm = json_array_get(moves, i);
        const char* name = json_str(json_get(jm, "name"));
        const char* et_name = json_str(json_get(jm, "entity_type"));

        int mi = g_graph.move_type_count++;
        MoveType* mt = &g_graph.move_types[mi];
        herb_memset(mt, 0, sizeof(MoveType));
        mt->name_id = intern(name);
        mt->entity_type = et_name ? intern(et_name) : -1;

        JsonValue* scoped_from = json_get(jm, "scoped_from");
        JsonValue* scoped_to = json_get(jm, "scoped_to");

        if (scoped_from || scoped_to) {
            /* Scoped move */
            mt->is_scoped = 1;
            mt->scoped_from_count = 0;
            for (int j = 0; j < json_array_len(scoped_from); j++) {
                mt->scoped_from_names[mt->scoped_from_count++] =
                    intern(json_str(json_array_get(scoped_from, j)));
            }
            mt->scoped_to_count = 0;
            for (int j = 0; j < json_array_len(scoped_to); j++) {
                mt->scoped_to_names[mt->scoped_to_count++] =
                    intern(json_str(json_array_get(scoped_to, j)));
            }
        } else {
            /* Regular move */
            JsonValue* from = json_get(jm, "from");
            mt->from_count = 0;
            for (int j = 0; j < json_array_len(from); j++) {
                const char* cn = json_str(json_array_get(from, j));
                int ci = graph_find_container_by_name(intern(cn));
                if (ci >= 0) mt->from_containers[mt->from_count++] = ci;
            }
            JsonValue* to = json_get(jm, "to");
            mt->to_count = 0;
            for (int j = 0; j < json_array_len(to); j++) {
                const char* cn = json_str(json_array_get(to, j));
                int ci = graph_find_container_by_name(intern(cn));
                if (ci >= 0) mt->to_containers[mt->to_count++] = ci;
            }
        }
    }

    /* 4. Pools */
    JsonValue* pools = json_get(root, "pools");
    for (int i = 0; i < json_array_len(pools); i++) {
        JsonValue* jp = json_array_get(pools, i);
        int pi = g_graph.pool_count++;
        g_graph.pools[pi].name_id = intern(json_str(json_get(jp, "name")));
        g_graph.pools[pi].property_id = intern(json_str(json_get(jp, "property")));
    }

    /* 5. Transfers */
    JsonValue* transfers = json_get(root, "transfers");
    for (int i = 0; i < json_array_len(transfers); i++) {
        JsonValue* jt = json_array_get(transfers, i);
        int ti = g_graph.transfer_type_count++;
        TransferType* tt = &g_graph.transfer_types[ti];
        tt->name_id = intern(json_str(json_get(jt, "name")));
        const char* pool_name = json_str(json_get(jt, "pool"));
        tt->pool_idx = -1;
        if (pool_name) {
            int pn = intern(pool_name);
            for (int j = 0; j < g_graph.pool_count; j++) {
                if (g_graph.pools[j].name_id == pn) { tt->pool_idx = j; break; }
            }
        }
        const char* et_name = json_str(json_get(jt, "entity_type"));
        tt->entity_type = et_name ? intern(et_name) : -1;
    }

    /* 6. Entities (with scoped placement support) */
    JsonValue* entities = json_get(root, "entities");
    for (int i = 0; i < json_array_len(entities); i++) {
        JsonValue* je = json_array_get(entities, i);
        const char* name = json_str(json_get(je, "name"));
        const char* type_name = json_str(json_get(je, "type"));

        JsonValue* in_spec = json_get(je, "in");
        int ci = -1;
        if (in_spec) {
            if (in_spec->type == JT_STRING) {
                ci = graph_find_container_by_name(intern(in_spec->string_val));
            } else if (in_spec->type == JT_OBJECT) {
                /* Scoped placement: {"scope": "entity_name", "container": "scope_name"} */
                JsonValue* scope = json_get(in_spec, "scope");
                JsonValue* sc_name = json_get(in_spec, "container");
                if (scope && sc_name) {
                    int scope_eid = graph_find_entity_by_name(intern(json_str(scope)));
                    if (scope_eid >= 0) {
                        ci = get_scoped_container(scope_eid, intern(json_str(sc_name)));
                    }
                }
            }
        }

        int ei = create_entity(intern(type_name), intern(name), ci);

        /* Properties */
        JsonValue* props = json_get(je, "properties");
        if (props && props->type == JT_OBJECT) {
            for (int j = 0; j < props->object.count; j++) {
                int pk = intern(props->object.keys[j]);
                JsonValue* pv = props->object.values[j];
                if (pv->type == JT_INT)
                    entity_set_prop(ei, pk, pv_int(pv->int_val));
                else if (pv->type == JT_FLOAT)
                    entity_set_prop(ei, pk, pv_float(pv->float_val));
                else if (pv->type == JT_STRING)
                    entity_set_prop(ei, pk, pv_string(intern(pv->string_val)));
            }
        }
    }

    /* 7. Channels (after entities — channels reference entity names) */
    JsonValue* channels = json_get(root, "channels");
    for (int i = 0; i < json_array_len(channels); i++) {
        JsonValue* jch = json_array_get(channels, i);
        const char* ch_name = json_str(json_get(jch, "name"));
        const char* from_name = json_str(json_get(jch, "from"));
        const char* to_name = json_str(json_get(jch, "to"));
        const char* et_name = json_str(json_get(jch, "entity_type"));

        int chi = g_graph.channel_count++;
        Channel* ch = &g_graph.channels[chi];
        ch->name_id = intern(ch_name);
        ch->sender_entity_idx = graph_find_entity_by_name(intern(from_name));
        ch->receiver_entity_idx = graph_find_entity_by_name(intern(to_name));
        ch->entity_type = et_name ? intern(et_name) : -1;

        /* Create buffer container */
        char buf_name[256];
        herb_snprintf(buf_name, sizeof(buf_name), "channel:%s", ch_name);
        int buf_ci = g_graph.container_count++;
        Container* bc = &g_graph.containers[buf_ci];
        bc->id = buf_ci;
        bc->name_id = intern(buf_name);
        bc->kind = CK_SIMPLE;
        bc->entity_type = ch->entity_type;
        bc->entity_count = 0;
        bc->owner = -1;
        ch->buffer_container_idx = buf_ci;
    }

    /* 8. Nesting depth bound */
    JsonValue* max_depth = json_get(root, "max_nesting_depth");
    if (max_depth && max_depth->type == JT_INT) {
        g_graph.max_nesting_depth = (int)max_depth->int_val;
    }

    /* 9. Tensions */
    JsonValue* tensions = json_get(root, "tensions");
    for (int i = 0; i < json_array_len(tensions); i++) {
        JsonValue* jt = json_array_get(tensions, i);
        int ti = g_graph.tension_count++;
        Tension* t = &g_graph.tensions[ti];
        herb_memset(t, 0, sizeof(Tension));
        t->enabled = 1;
        t->owner = -1;
        t->owner_run_container = -1;

        const char* tname = json_str(json_get(jt, "name"));
        t->name_id = intern(tname);
        t->priority = (int)json_int(json_get(jt, "priority"));

        const char* pair = json_str(json_get(jt, "pair"));
        t->pair_mode = (pair && herb_strcmp(pair, "cross") == 0) ? 1 : 0;

        /* Match clauses */
        JsonValue* jmatches = json_get(jt, "match");
        t->match_count = 0;
        for (int j = 0; j < json_array_len(jmatches); j++) {
            JsonValue* jmc = json_array_get(jmatches, j);
            MatchClause* mc = &t->matches[t->match_count++];
            herb_memset(mc, 0, sizeof(MatchClause));
            mc->required = 1;
            mc->bind_id = -1;
            mc->container_idx = -1;
            mc->scope_bind_id = -1;
            mc->scope_cname_id = -1;
            mc->channel_idx = -1;
            mc->key_prop_id = -1;

            JsonValue* req = json_get(jmc, "required");
            if (req) mc->required = json_bool(req);

            const char* bind = json_str(json_get(jmc, "bind"));
            if (bind) mc->bind_id = intern(bind);

            /* Guard expression */
            JsonValue* guard = json_get(jmc, "guard");
            if (guard) {
                mc->kind = MC_GUARD;
                mc->guard_expr = build_expr(guard);
                continue;
            }

            /* Container is empty/occupied */
            JsonValue* container = json_get(jmc, "container");
            if (container && container->type == JT_STRING) {
                mc->kind = MC_CONTAINER_IS;
                mc->guard_container_idx = graph_find_container_by_name(intern(container->string_val));
                const char* is_val = json_str(json_get(jmc, "is"));
                mc->is_empty = (is_val && herb_strcmp(is_val, "empty") == 0) ? 1 : 0;
                continue;
            }

            /* Entity in container (regular, scoped, or channel) */
            JsonValue* in_spec = json_get(jmc, "in");
            if (in_spec) {
                mc->kind = MC_ENTITY_IN;

                if (in_spec->type == JT_OBJECT) {
                    JsonValue* scope = json_get(in_spec, "scope");
                    JsonValue* channel = json_get(in_spec, "channel");
                    if (scope) {
                        mc->scope_bind_id = intern(json_str(scope));
                        JsonValue* sc = json_get(in_spec, "container");
                        mc->scope_cname_id = intern(json_str(sc));
                    } else if (channel) {
                        mc->channel_idx = graph_find_channel_by_name(intern(json_str(channel)));
                    }
                } else if (in_spec->type == JT_STRING) {
                    mc->container_idx = graph_find_container_by_name(intern(in_spec->string_val));
                }

                const char* sel = json_str(json_get(jmc, "select"));
                mc->select = SEL_FIRST;
                if (sel) {
                    if (herb_strcmp(sel, "each") == 0) mc->select = SEL_EACH;
                    else if (herb_strcmp(sel, "max_by") == 0) mc->select = SEL_MAX_BY;
                    else if (herb_strcmp(sel, "min_by") == 0) mc->select = SEL_MIN_BY;
                }

                const char* key = json_str(json_get(jmc, "key"));
                mc->key_prop_id = key ? intern(key) : -1;

                mc->where_expr = build_expr(json_get(jmc, "where"));
                continue;
            }

            /* Empty in container list */
            JsonValue* empty_in = json_get(jmc, "empty_in");
            if (empty_in && empty_in->type == JT_ARRAY) {
                mc->kind = MC_EMPTY_IN;
                mc->container_count = 0;
                for (int k = 0; k < json_array_len(empty_in); k++) {
                    const char* cn = json_str(json_array_get(empty_in, k));
                    int cci = graph_find_container_by_name(intern(cn));
                    if (cci >= 0) mc->containers[mc->container_count++] = cci;
                }
                const char* sel = json_str(json_get(jmc, "select"));
                mc->select = SEL_FIRST;
                if (sel && herb_strcmp(sel, "each") == 0) mc->select = SEL_EACH;
                continue;
            }
        }

        /* Emit clauses */
        JsonValue* jemits = json_get(jt, "emit");
        t->emit_count = 0;
        for (int j = 0; j < json_array_len(jemits); j++) {
            JsonValue* jem = json_array_get(jemits, j);
            EmitClause* ec = &t->emits[t->emit_count++];
            herb_memset(ec, 0, sizeof(EmitClause));
            ec->to_ref = -1;
            ec->to_scope_bind_id = -1;
            ec->recv_to_ref = -1;
            ec->recv_to_scope_bind_id = -1;
            ec->dup_in_ref = -1;
            ec->dup_in_scope_bind_id = -1;

            /* Move emit */
            JsonValue* move = json_get(jem, "move");
            if (move) {
                ec->kind = EC_MOVE;
                ec->move_type_idx = graph_find_move_type_by_name(intern(json_str(move)));
                const char* entity = json_str(json_get(jem, "entity"));
                ec->entity_ref = entity ? intern(entity) : -1;

                JsonValue* to = json_get(jem, "to");
                if (to) {
                    if (to->type == JT_OBJECT) {
                        JsonValue* scope = json_get(to, "scope");
                        if (scope) {
                            ec->to_scope_bind_id = intern(json_str(scope));
                            JsonValue* sc = json_get(to, "container");
                            ec->to_scope_cname_id = intern(json_str(sc));
                        }
                    } else if (to->type == JT_STRING) {
                        ec->to_ref = intern(to->string_val);
                    }
                }
                continue;
            }

            /* Set emit */
            JsonValue* set = json_get(jem, "set");
            if (set) {
                ec->kind = EC_SET;
                ec->set_entity_ref = intern(json_str(set));
                const char* prop = json_str(json_get(jem, "property"));
                ec->set_prop_id = prop ? intern(prop) : -1;
                ec->value_expr = build_expr(json_get(jem, "value"));
                continue;
            }

            /* Send emit */
            JsonValue* send = json_get(jem, "send");
            if (send) {
                ec->kind = EC_SEND;
                ec->send_channel_idx = graph_find_channel_by_name(intern(json_str(send)));
                const char* entity = json_str(json_get(jem, "entity"));
                ec->send_entity_ref = entity ? intern(entity) : -1;
                continue;
            }

            /* Receive emit */
            JsonValue* receive = json_get(jem, "receive");
            if (receive) {
                ec->kind = EC_RECEIVE;
                ec->recv_channel_idx = graph_find_channel_by_name(intern(json_str(receive)));
                const char* entity = json_str(json_get(jem, "entity"));
                ec->recv_entity_ref = entity ? intern(entity) : -1;

                JsonValue* to = json_get(jem, "to");
                if (to) {
                    if (to->type == JT_OBJECT) {
                        JsonValue* scope = json_get(to, "scope");
                        if (scope) {
                            ec->recv_to_scope_bind_id = intern(json_str(scope));
                            JsonValue* sc = json_get(to, "container");
                            ec->recv_to_scope_cname_id = intern(json_str(sc));
                        }
                    } else if (to->type == JT_STRING) {
                        ec->recv_to_ref = intern(to->string_val);
                    }
                }
                continue;
            }

            /* Transfer emit */
            JsonValue* transfer = json_get(jem, "transfer");
            if (transfer) {
                ec->kind = EC_TRANSFER;
                ec->transfer_type_idx = graph_find_transfer_by_name(intern(json_str(transfer)));
                const char* from_ref = json_str(json_get(jem, "from"));
                ec->transfer_from_ref = from_ref ? intern(from_ref) : -1;
                const char* to_ref = json_str(json_get(jem, "to"));
                ec->transfer_to_ref = to_ref ? intern(to_ref) : -1;
                ec->transfer_amount_expr = build_expr(json_get(jem, "amount"));
                continue;
            }

            /* Duplicate emit */
            JsonValue* dup = json_get(jem, "duplicate");
            if (dup) {
                ec->kind = EC_DUPLICATE;
                ec->dup_entity_ref = intern(json_str(dup));

                JsonValue* in_ref = json_get(jem, "in");
                if (in_ref) {
                    if (in_ref->type == JT_OBJECT) {
                        JsonValue* scope = json_get(in_ref, "scope");
                        if (scope) {
                            ec->dup_in_scope_bind_id = intern(json_str(scope));
                            JsonValue* sc = json_get(in_ref, "container");
                            ec->dup_in_scope_cname_id = intern(json_str(sc));
                        }
                    } else if (in_ref->type == JT_STRING) {
                        ec->dup_in_ref = intern(in_ref->string_val);
                    }
                }
                continue;
            }
        }
    }
}
#endif /* HERB_BINARY_ONLY */

/* ============================================================
 * STATE OUTPUT (writes to buffer instead of stdout)
 *
 * Writes the same JSON format as the libc version's
 * output_state() function, but into a caller-provided buffer.
 * Returns the number of characters written.
 * ============================================================ */

int herb_state(char* buf, int buf_size) {
    int pos = 0;

    /* Helper macro for safe buffer append */
    #define EMIT(c) do { if (pos < buf_size - 1) buf[pos] = (c); pos++; } while(0)
    #define EMITS(s) do { const char* _s = (s); while (*_s) { EMIT(*_s); _s++; } } while(0)

    EMITS("{\n");
    int first_entity = 1;
    for (int i = 0; i < g_graph.entity_count; i++) {
        Entity* e = &g_graph.entities[i];
        int loc = g_graph.entity_location[i];
        const char* loc_name = loc >= 0 ? str_of(g_graph.containers[loc].name_id) : "null";

        if (!first_entity) { EMITS(",\n"); }
        first_entity = 0;

        EMITS("  \"");
        EMITS(str_of(e->name_id));
        EMITS("\": {\"location\": \"");
        EMITS(loc_name);
        EMIT('"');

        for (int j = 0; j < e->prop_count; j++) {
            EMITS(", \"");
            EMITS(str_of(e->prop_keys[j]));
            EMITS("\": ");
            PropVal v = e->prop_vals[j];
            if (v.type == PV_INT) {
                char tmp[24];
                herb_snprintf(tmp, sizeof(tmp), "%lld", v.i);
                EMITS(tmp);
            } else if (v.type == PV_FLOAT) {
                char tmp[32];
                herb_snprintf(tmp, sizeof(tmp), "%g", v.f);
                EMITS(tmp);
            } else if (v.type == PV_STRING) {
                EMIT('"');
                EMITS(str_of(v.s));
                EMIT('"');
            } else {
                EMITS("null");
            }
        }

        EMIT('}');
    }
    EMITS("\n}\n");

    #undef EMIT
    #undef EMITS

    if (pos < buf_size) buf[pos] = '\0';
    else if (buf_size > 0) buf[buf_size - 1] = '\0';

    return pos;
}

/* ============================================================
 * BINARY FORMAT LOADER
 *
 * Loads .herb binary programs — HERB's native format.
 * Dramatically simpler than the JSON path: no parsing,
 * no tree building, just sequential reads into the graph.
 *
 * Section tags (must appear in dependency order):
 *   0x01 entity_types, 0x02 containers, 0x03 moves,
 *   0x04 pools, 0x05 transfers, 0x06 entities,
 *   0x07 channels, 0x08 config, 0x09 tensions, 0xFF end
 * ============================================================ */

typedef struct {
    const uint8_t* data;
    herb_size_t len;
    herb_size_t pos;
} BinReader;

static uint8_t br_u8(BinReader* r) {
    if (r->pos >= r->len) return 0;
    return r->data[r->pos++];
}

static uint16_t br_u16(BinReader* r) {
    if (r->pos + 2 > r->len) return 0;
    uint16_t v = (uint16_t)r->data[r->pos] | ((uint16_t)r->data[r->pos+1] << 8);
    r->pos += 2;
    return v;
}

static int16_t br_i16(BinReader* r) { return (int16_t)br_u16(r); }

static int64_t br_i64(BinReader* r) {
    if (r->pos + 8 > r->len) return 0;
    int64_t v = 0;
    for (int i = 0; i < 8; i++)
        v |= ((int64_t)r->data[r->pos + i]) << (i * 8);
    r->pos += 8;
    return v;
}

static double br_f64(BinReader* r) {
    int64_t bits = br_i64(r);
    double v;
    herb_memcpy(&v, &bits, 8);
    return v;
}

/* Binary string table → interned string IDs */
static int g_bin_str_ids[MAX_STRINGS];
static int g_bin_str_count = 0;

static int bstr(uint16_t idx) {
    if (idx == 0xFFFF) return -1;
    if ((int)idx < g_bin_str_count) return g_bin_str_ids[idx];
    return -1;
}

static Expr* br_expr(BinReader* r) {
    uint8_t kind = br_u8(r);
    if (kind == 0xFF) return HERB_NULL;
    Expr* e = alloc_expr();
    switch (kind) {
        case 0x00: /* INT */
            e->kind = EX_INT;
            e->int_val = br_i64(r);
            break;
        case 0x01: /* FLOAT */
            e->kind = EX_FLOAT;
            e->float_val = br_f64(r);
            break;
        case 0x02: /* STRING */
            e->kind = EX_STRING;
            e->string_id = bstr(br_u16(r));
            break;
        case 0x03: /* BOOL */
            e->kind = EX_BOOL;
            e->bool_val = br_u8(r);
            break;
        case 0x04: /* PROP */
            e->kind = EX_PROP;
            e->prop.prop_id = bstr(br_u16(r));
            e->prop.of_id = bstr(br_u16(r));
            break;
        case 0x05: /* COUNT_CONTAINER */
            e->kind = EX_COUNT;
            e->count.container_idx = graph_find_container_by_name(bstr(br_u16(r)));
            e->count.is_scoped = 0;
            e->count.is_channel = 0;
            break;
        case 0x06: /* COUNT_SCOPED */
            e->kind = EX_COUNT;
            e->count.is_scoped = 1;
            e->count.is_channel = 0;
            e->count.container_idx = -1;
            e->count.scope_bind_id = bstr(br_u16(r));
            e->count.scope_cname_id = bstr(br_u16(r));
            break;
        case 0x07: /* COUNT_CHANNEL */
            e->kind = EX_COUNT;
            e->count.is_channel = 1;
            e->count.is_scoped = 0;
            e->count.container_idx = -1;
            e->count.channel_idx = graph_find_channel_by_name(bstr(br_u16(r)));
            break;
        case 0x08: /* BINARY */
            e->kind = EX_BINARY;
            e->binary.op_id = bstr(br_u16(r));
            e->binary.left = br_expr(r);
            e->binary.right = br_expr(r);
            break;
        case 0x09: /* UNARY_NOT */
            e->kind = EX_UNARY;
            e->unary.arg = br_expr(r);
            break;
        case 0x0A: /* IN_OF */
            e->kind = EX_IN_OF;
            e->in_of.container_idx = graph_find_container_by_name(bstr(br_u16(r)));
            e->in_of.entity_ref_id = bstr(br_u16(r));
            break;
        default:
            return HERB_NULL;
    }
    return e;
}

static void br_to_ref(BinReader* r, int* out_ref, int* out_scope_bind, int* out_scope_cname) {
    *out_ref = -1;
    *out_scope_bind = -1;
    *out_scope_cname = -1;
    uint8_t kind = br_u8(r);
    if (kind == 0x00) {         /* NORMAL */
        *out_ref = bstr(br_u16(r));
    } else if (kind == 0x01) {  /* SCOPED */
        *out_scope_bind = bstr(br_u16(r));
        *out_scope_cname = bstr(br_u16(r));
    }
    /* kind == 0x02 = NONE — no data to read */
}

static int load_program_binary(const uint8_t* data, herb_size_t len) {
    BinReader reader = { data, len, 0 };
    BinReader* r = &reader;

    /* Header: magic(4) + version(1) + flags(1) + string_count(2) = 8 bytes */
    if (len < 8) { herb_error(HERB_ERR_FATAL, "binary too short"); return -1; }
    if (data[0] != 'H' || data[1] != 'E' || data[2] != 'R' || data[3] != 'B') {
        herb_error(HERB_ERR_FATAL, "bad magic"); return -1;
    }
    r->pos = 4;
    uint8_t version = br_u8(r);
    if (version != 1) { herb_error(HERB_ERR_FATAL, "unsupported version"); return -1; }
    br_u8(r); /* flags — reserved */
    uint16_t str_count = br_u16(r);

    /* String table: intern all strings */
    g_bin_str_count = 0;
    for (uint16_t i = 0; i < str_count; i++) {
        uint8_t slen = br_u8(r);
        char tmp[256];
        for (int j = 0; j < slen && j < 255; j++) tmp[j] = (char)br_u8(r);
        tmp[slen < 255 ? slen : 255] = '\0';
        g_bin_str_ids[g_bin_str_count++] = intern(tmp);
    }

    /* Initialize graph */
    herb_memset(&g_graph, 0, sizeof(Graph));
    for (int i = 0; i < MAX_ENTITIES; i++) g_graph.entity_location[i] = -1;
    g_graph.max_nesting_depth = -1;
    for (int i = 0; i < MAX_CONTAINERS; i++) g_graph.containers[i].owner = -1;

    /* Process sections */
    while (r->pos < r->len) {
        uint8_t sec = br_u8(r);
        if (sec == 0xFF) break; /* SEC_END */

        switch (sec) {

        case 0x01: { /* Entity types */
            uint16_t count = br_u16(r);
            for (uint16_t i = 0; i < count; i++) {
                int tid = bstr(br_u16(r));
                g_graph.type_names[g_graph.type_count++] = tid;
                uint8_t sc_count = br_u8(r);
                if (sc_count > 0) {
                    int tsi = g_graph.type_scope_count++;
                    g_graph.type_scope_type_ids[tsi] = tid;
                    g_graph.type_scope_counts[tsi] = 0;
                    for (uint8_t j = 0; j < sc_count; j++) {
                        ScopeTemplate* st = &g_graph.type_scope_templates[tsi][g_graph.type_scope_counts[tsi]++];
                        st->name_id = bstr(br_u16(r));
                        st->kind = br_u8(r) ? CK_SLOT : CK_SIMPLE;
                        st->entity_type = bstr(br_u16(r));
                    }
                }
            }
            break;
        }

        case 0x02: { /* Containers */
            uint16_t count = br_u16(r);
            for (uint16_t i = 0; i < count; i++) {
                int ci = g_graph.container_count++;
                Container* c = &g_graph.containers[ci];
                c->id = ci;
                c->name_id = bstr(br_u16(r));
                c->kind = br_u8(r) ? CK_SLOT : CK_SIMPLE;
                c->entity_type = bstr(br_u16(r));
                c->entity_count = 0;
                c->owner = -1;
            }
            break;
        }

        case 0x03: { /* Moves */
            uint16_t count = br_u16(r);
            for (uint16_t i = 0; i < count; i++) {
                int mi = g_graph.move_type_count++;
                MoveType* mt = &g_graph.move_types[mi];
                herb_memset(mt, 0, sizeof(MoveType));
                mt->name_id = bstr(br_u16(r));
                mt->entity_type = bstr(br_u16(r));
                mt->is_scoped = br_u8(r);
                uint8_t fc = br_u8(r);
                if (mt->is_scoped) {
                    mt->scoped_from_count = fc;
                    for (uint8_t j = 0; j < fc; j++)
                        mt->scoped_from_names[j] = bstr(br_u16(r));
                } else {
                    mt->from_count = fc;
                    for (uint8_t j = 0; j < fc; j++) {
                        int cid = graph_find_container_by_name(bstr(br_u16(r)));
                        if (cid >= 0) mt->from_containers[mt->from_count > 0 ? j : j] = cid;
                    }
                    mt->from_count = fc;
                }
                uint8_t tc = br_u8(r);
                if (mt->is_scoped) {
                    mt->scoped_to_count = tc;
                    for (uint8_t j = 0; j < tc; j++)
                        mt->scoped_to_names[j] = bstr(br_u16(r));
                } else {
                    mt->to_count = tc;
                    for (uint8_t j = 0; j < tc; j++) {
                        int cid = graph_find_container_by_name(bstr(br_u16(r)));
                        if (cid >= 0) mt->to_containers[j] = cid;
                    }
                }
            }
            break;
        }

        case 0x04: { /* Pools */
            uint16_t count = br_u16(r);
            for (uint16_t i = 0; i < count; i++) {
                int pi = g_graph.pool_count++;
                g_graph.pools[pi].name_id = bstr(br_u16(r));
                g_graph.pools[pi].property_id = bstr(br_u16(r));
            }
            break;
        }

        case 0x05: { /* Transfers */
            uint16_t count = br_u16(r);
            for (uint16_t i = 0; i < count; i++) {
                int ti = g_graph.transfer_type_count++;
                TransferType* tt = &g_graph.transfer_types[ti];
                tt->name_id = bstr(br_u16(r));
                int pool_name = bstr(br_u16(r));
                tt->pool_idx = -1;
                if (pool_name >= 0) {
                    for (int j = 0; j < g_graph.pool_count; j++) {
                        if (g_graph.pools[j].name_id == pool_name) { tt->pool_idx = j; break; }
                    }
                }
                tt->entity_type = bstr(br_u16(r));
            }
            break;
        }

        case 0x06: { /* Entities */
            uint16_t count = br_u16(r);
            for (uint16_t i = 0; i < count; i++) {
                int name_id = bstr(br_u16(r));
                int type_id = bstr(br_u16(r));
                uint8_t in_kind = br_u8(r);
                int ci = -1;
                if (in_kind == 0) { /* normal */
                    int cname = bstr(br_u16(r));
                    if (cname >= 0) ci = graph_find_container_by_name(cname);
                } else if (in_kind == 1) { /* scoped */
                    int scope_eid = graph_find_entity_by_name(bstr(br_u16(r)));
                    int scope_cname = bstr(br_u16(r));
                    if (scope_eid >= 0 && scope_cname >= 0)
                        ci = get_scoped_container(scope_eid, scope_cname);
                }
                int ei = create_entity(type_id, name_id, ci);
                uint8_t pc = br_u8(r);
                for (uint8_t j = 0; j < pc; j++) {
                    int pk = bstr(br_u16(r));
                    uint8_t vk = br_u8(r);
                    if (vk == 0)      entity_set_prop(ei, pk, pv_int(br_i64(r)));
                    else if (vk == 1) entity_set_prop(ei, pk, pv_float(br_f64(r)));
                    else if (vk == 2) entity_set_prop(ei, pk, pv_string(bstr(br_u16(r))));
                }
            }
            break;
        }

        case 0x07: { /* Channels */
            uint16_t count = br_u16(r);
            for (uint16_t i = 0; i < count; i++) {
                int chi = g_graph.channel_count++;
                Channel* ch = &g_graph.channels[chi];
                ch->name_id = bstr(br_u16(r));
                ch->sender_entity_idx = graph_find_entity_by_name(bstr(br_u16(r)));
                ch->receiver_entity_idx = graph_find_entity_by_name(bstr(br_u16(r)));
                ch->entity_type = bstr(br_u16(r));
                /* Create buffer container */
                char buf_name[256];
                herb_snprintf(buf_name, sizeof(buf_name), "channel:%s", str_of(ch->name_id));
                int buf_ci = g_graph.container_count++;
                Container* bc = &g_graph.containers[buf_ci];
                bc->id = buf_ci;
                bc->name_id = intern(buf_name);
                bc->kind = CK_SIMPLE;
                bc->entity_type = ch->entity_type;
                bc->entity_count = 0;
                bc->owner = -1;
                ch->buffer_container_idx = buf_ci;
            }
            break;
        }

        case 0x08: { /* Config */
            g_graph.max_nesting_depth = (int)br_i16(r);
            break;
        }

        case 0x09: { /* Tensions */
            uint16_t count = br_u16(r);
            for (uint16_t i = 0; i < count; i++) {
                int ti = g_graph.tension_count++;
                Tension* t = &g_graph.tensions[ti];
                herb_memset(t, 0, sizeof(Tension));
                t->enabled = 1;
                t->owner = -1;
                t->owner_run_container = -1;
                t->name_id = bstr(br_u16(r));
                t->priority = (int)br_i16(r);
                t->pair_mode = br_u8(r);

                /* Match clauses */
                t->match_count = br_u8(r);
                for (int j = 0; j < t->match_count; j++) {
                    MatchClause* mc = &t->matches[j];
                    herb_memset(mc, 0, sizeof(MatchClause));
                    mc->required = 1;
                    mc->bind_id = -1;
                    mc->container_idx = -1;
                    mc->scope_bind_id = -1;
                    mc->scope_cname_id = -1;
                    mc->channel_idx = -1;
                    mc->key_prop_id = -1;

                    uint8_t mk = br_u8(r);
                    switch (mk) {
                        case 0x00: { /* ENTITY_IN */
                            mc->kind = MC_ENTITY_IN;
                            mc->bind_id = bstr(br_u16(r));
                            mc->required = br_u8(r);
                            uint8_t sel = br_u8(r);
                            mc->select = (sel == 1) ? SEL_EACH : (sel == 2) ? SEL_MAX_BY : (sel == 3) ? SEL_MIN_BY : SEL_FIRST;
                            mc->key_prop_id = bstr(br_u16(r));
                            uint8_t ik = br_u8(r);
                            if (ik == 0) {
                                mc->container_idx = graph_find_container_by_name(bstr(br_u16(r)));
                            } else if (ik == 1) {
                                mc->scope_bind_id = bstr(br_u16(r));
                                mc->scope_cname_id = bstr(br_u16(r));
                            } else if (ik == 2) {
                                mc->channel_idx = graph_find_channel_by_name(bstr(br_u16(r)));
                            }
                            if (br_u8(r)) mc->where_expr = br_expr(r);
                            break;
                        }
                        case 0x01: { /* EMPTY_IN */
                            mc->kind = MC_EMPTY_IN;
                            mc->bind_id = bstr(br_u16(r));
                            uint8_t sel = br_u8(r);
                            mc->select = (sel == 1) ? SEL_EACH : SEL_FIRST;
                            mc->container_count = br_u8(r);
                            for (int k = 0; k < mc->container_count; k++)
                                mc->containers[k] = graph_find_container_by_name(bstr(br_u16(r)));
                            break;
                        }
                        case 0x02: { /* CONTAINER_IS */
                            mc->kind = MC_CONTAINER_IS;
                            mc->guard_container_idx = graph_find_container_by_name(bstr(br_u16(r)));
                            mc->is_empty = br_u8(r);
                            break;
                        }
                        case 0x03: { /* GUARD */
                            mc->kind = MC_GUARD;
                            mc->guard_expr = br_expr(r);
                            break;
                        }
                    }
                }

                /* Emit clauses */
                t->emit_count = br_u8(r);
                for (int j = 0; j < t->emit_count; j++) {
                    EmitClause* ec = &t->emits[j];
                    herb_memset(ec, 0, sizeof(EmitClause));
                    ec->to_ref = -1;
                    ec->to_scope_bind_id = -1;
                    ec->recv_to_ref = -1;
                    ec->recv_to_scope_bind_id = -1;
                    ec->dup_in_ref = -1;
                    ec->dup_in_scope_bind_id = -1;

                    uint8_t ek = br_u8(r);
                    switch (ek) {
                        case 0x00: { /* MOVE */
                            ec->kind = EC_MOVE;
                            ec->move_type_idx = graph_find_move_type_by_name(bstr(br_u16(r)));
                            ec->entity_ref = bstr(br_u16(r));
                            br_to_ref(r, &ec->to_ref, &ec->to_scope_bind_id, &ec->to_scope_cname_id);
                            break;
                        }
                        case 0x01: { /* SET */
                            ec->kind = EC_SET;
                            ec->set_entity_ref = bstr(br_u16(r));
                            ec->set_prop_id = bstr(br_u16(r));
                            ec->value_expr = br_expr(r);
                            break;
                        }
                        case 0x02: { /* SEND */
                            ec->kind = EC_SEND;
                            ec->send_channel_idx = graph_find_channel_by_name(bstr(br_u16(r)));
                            ec->send_entity_ref = bstr(br_u16(r));
                            break;
                        }
                        case 0x03: { /* RECEIVE */
                            ec->kind = EC_RECEIVE;
                            ec->recv_channel_idx = graph_find_channel_by_name(bstr(br_u16(r)));
                            ec->recv_entity_ref = bstr(br_u16(r));
                            br_to_ref(r, &ec->recv_to_ref, &ec->recv_to_scope_bind_id, &ec->recv_to_scope_cname_id);
                            break;
                        }
                        case 0x04: { /* TRANSFER */
                            ec->kind = EC_TRANSFER;
                            ec->transfer_type_idx = graph_find_transfer_by_name(bstr(br_u16(r)));
                            ec->transfer_from_ref = bstr(br_u16(r));
                            ec->transfer_to_ref = bstr(br_u16(r));
                            ec->transfer_amount_expr = br_expr(r);
                            break;
                        }
                        case 0x05: { /* DUPLICATE */
                            ec->kind = EC_DUPLICATE;
                            ec->dup_entity_ref = bstr(br_u16(r));
                            br_to_ref(r, &ec->dup_in_ref, &ec->dup_in_scope_bind_id, &ec->dup_in_scope_cname_id);
                            break;
                        }
                    }
                }
            }
            break;
        }

        default:
            /* Unknown section — skip to end */
            herb_error(HERB_ERR_WARN, "unknown binary section");
            r->pos = r->len;
            break;
        }
    }

    return 0;
}

/* ============================================================
 * PUBLIC API
 *
 * These are the entry points that the external environment
 * (bootloader, test harness, assembly bootstrap) calls.
 * ============================================================ */

/* Initialize the runtime. Must be called before herb_load(). */
void herb_init(void* arena_memory, herb_size_t arena_size, HerbErrorFn error_fn) {
    static HerbArena arena_storage;
    g_arena = &arena_storage;
    herb_arena_init(g_arena, arena_memory, arena_size);

    herb_set_error_handler(error_fn);

    g_string_count = 0;
    g_expr_count = 0;
}

/* Load a HERB program from a memory buffer.
 * Auto-detects format: .herb binary (HERB magic) or .herb.json (JSON text).
 * Returns 0 on success, -1 on error. */
int herb_load(const char* buf, herb_size_t len) {
    /* Auto-detect: binary format starts with "HERB" magic bytes */
    if (len >= 4 && buf[0] == 'H' && buf[1] == 'E' && buf[2] == 'R' && buf[3] == 'B') {
        return load_program_binary((const uint8_t*)buf, len);
    }

#ifdef HERB_BINARY_ONLY
    herb_error(HERB_ERR_FATAL, "JSON loading disabled (HERB_BINARY_ONLY)");
    return -1;
#else
    /* Fall through to JSON parsing */
    JsonValue* root;
    const char* end = json_parse_value(buf, &root);
    if (!end || !root) {
        herb_error(HERB_ERR_FATAL, "JSON parse error");
        return -1;
    }

    /* Reject composition specs — must be pre-composed */
    if (json_get(root, "compose")) {
        herb_error(HERB_ERR_FATAL, "composition specs must be pre-composed");
        return -1;
    }

    load_program(root);
    return 0;
#endif
}

/* Create a runtime entity (for delivering signals).
 * Returns entity index, or -1 on error. */
int herb_create(const char* name, const char* type, const char* container) {
    int ci = graph_find_container_by_name(intern(container));
    if (ci < 0) return -1;
    return create_entity(intern(type), intern(name), ci);
}

/* Set an integer property on an entity.
 * If the property already exists, update it. Otherwise add it.
 * Returns 0 on success, -1 on error. */
int herb_set_prop_int(int entity_id, const char* property, int64_t value) {
    if (entity_id < 0 || entity_id >= g_graph.entity_count) return -1;
    Entity* e = &g_graph.entities[entity_id];
    int key = intern(property);
    for (int i = 0; i < e->prop_count; i++) {
        if (e->prop_keys[i] == key) {
            e->prop_vals[i] = pv_int(value);
            return 0;
        }
    }
    if (e->prop_count >= MAX_PROPERTIES) return -1;
    e->prop_keys[e->prop_count] = key;
    e->prop_vals[e->prop_count] = pv_int(value);
    e->prop_count++;
    return 0;
}


/* Get the number of entities in a container.
 * Returns -1 if container not found. */
int herb_container_count(const char* container) {
    int ci = graph_find_container_by_name(intern(container));
    if (ci < 0) return -1;
    return g_graph.containers[ci].entity_count;
}

/* Get the entity ID at index `idx` within a container.
 * Returns -1 if out of bounds. */
int herb_container_entity(const char* container, int idx) {
    int ci = graph_find_container_by_name(intern(container));
    if (ci < 0) return -1;
    if (idx < 0 || idx >= g_graph.containers[ci].entity_count) return -1;
    return g_graph.containers[ci].entities[idx];
}

/* Get entity name by ID. Returns "?" if invalid. */
const char* herb_entity_name(int entity_id) {
    if (entity_id < 0 || entity_id >= g_graph.entity_count) return "?";
    return str_of(g_graph.entities[entity_id].name_id);
}

/* Get integer property from entity. Returns default_val if not found. */
int64_t herb_entity_prop_int(int entity_id, const char* property, int64_t default_val) {
    if (entity_id < 0 || entity_id >= g_graph.entity_count) return default_val;
    Entity* e = &g_graph.entities[entity_id];
    int key = intern(property);
    for (int i = 0; i < e->prop_count; i++) {
        if (e->prop_keys[i] == key && e->prop_vals[i].type == PV_INT) {
            return e->prop_vals[i].i;
        }
    }
    return default_val;
}

/* Get a string property value from an entity. Returns default if missing or wrong type. */
const char* herb_entity_prop_str(int entity_id, const char* property, const char* default_val) {
    if (entity_id < 0 || entity_id >= g_graph.entity_count) return default_val;
    Entity* e = &g_graph.entities[entity_id];
    int key = intern(property);
    for (int i = 0; i < e->prop_count; i++) {
        if (e->prop_keys[i] == key && e->prop_vals[i].type == PV_STRING) {
            return str_of(e->prop_vals[i].s);
        }
    }
    return default_val;
}

/* Get the container name where an entity is located. */
const char* herb_entity_location(int entity_id) {
    if (entity_id < 0 || entity_id >= g_graph.entity_count) return "?";
    int loc = g_graph.entity_location[entity_id];
    if (loc < 0) return "null";
    return str_of(g_graph.containers[loc].name_id);
}

/* Get total entity count in the graph. */
int herb_entity_total(void) {
    return g_graph.entity_count;
}

/* Get arena usage statistics */
herb_size_t herb_arena_usage(void) {
    return g_arena ? herb_arena_used(g_arena) : 0;
}

herb_size_t herb_arena_total(void) {
    return g_arena ? g_arena->size : 0;
}

/* ============================================================
 * TENSION QUERY / TOGGLE API
 *
 * Tensions are the energy gradients of the system. These APIs
 * make them inspectable and controllable at runtime — enabling
 * live manipulation of the OS's behavioral rules.
 * ============================================================ */

int herb_tension_count(void) {
    return g_graph.tension_count;
}

const char* herb_tension_name(int idx) {
    if (idx < 0 || idx >= g_graph.tension_count) return "";
    return str_of(g_graph.tensions[idx].name_id);
}

int herb_tension_priority(int idx) {
    if (idx < 0 || idx >= g_graph.tension_count) return 0;
    return g_graph.tensions[idx].priority;
}

int herb_tension_enabled(int idx) {
    if (idx < 0 || idx >= g_graph.tension_count) return 0;
    return g_graph.tensions[idx].enabled;
}

void herb_tension_set_enabled(int idx, int enabled) {
    if (idx < 0 || idx >= g_graph.tension_count) return;
    g_graph.tensions[idx].enabled = enabled ? 1 : 0;
}

int herb_tension_owner(int idx) {
    if (idx < 0 || idx >= g_graph.tension_count) return -1;
    return g_graph.tensions[idx].owner;
}

/* Dirty flag — defined after HAM compiler when HERB_BINARY_ONLY,
 * no-op stub otherwise (test builds don't have HAM) */
#ifdef HERB_BINARY_ONLY
void ham_mark_dirty(void);
#else
static inline void ham_mark_dirty(void) {}
#endif

/* ============================================================
 * RUNTIME TENSION CREATION API
 *
 * These functions allow the kernel to create tensions at runtime,
 * enabling loadable behavioral programs. A process IS its tensions:
 * loading a program means injecting tensions into the runtime.
 * ============================================================ */

int herb_tension_create(const char* name, int priority, int owner_entity,
                         const char* run_container_name) {
    if (g_graph.tension_count >= MAX_TENSIONS) return -1;
    int ti = g_graph.tension_count++;
    Tension* t = &g_graph.tensions[ti];
    herb_memset(t, 0, sizeof(Tension));
    t->name_id = intern(name);
    t->priority = priority;
    t->enabled = 1;
    t->owner = owner_entity;
    if (run_container_name && run_container_name[0]) {
        t->owner_run_container = graph_find_container_by_name(intern(run_container_name));
    } else {
        t->owner_run_container = -1;
    }
    /* Initialize match/emit refs to safe defaults */
    for (int i = 0; i < MAX_MATCH_CLAUSES; i++) {
        t->matches[i].scope_bind_id = -1;
        t->matches[i].channel_idx = -1;
        t->matches[i].container_idx = -1;
    }
    for (int i = 0; i < MAX_EMIT_CLAUSES; i++) {
        t->emits[i].to_ref = -1;
        t->emits[i].to_scope_bind_id = -1;
        t->emits[i].send_channel_idx = -1;
        t->emits[i].recv_channel_idx = -1;
        t->emits[i].recv_to_scope_bind_id = -1;
        t->emits[i].dup_in_scope_bind_id = -1;
    }
    ham_mark_dirty();  /* recompile HAM bytecode */
    return ti;
}

/* Add match: entity in container (select: 0=first, 1=each, 2=max_by, 3=min_by) */
int herb_tension_match_in(int tidx, const char* bind_name, const char* container,
                           int select_mode) {
    if (tidx < 0 || tidx >= g_graph.tension_count) return -1;
    Tension* t = &g_graph.tensions[tidx];
    if (t->match_count >= MAX_MATCH_CLAUSES) return -1;
    MatchClause* mc = &t->matches[t->match_count++];
    herb_memset(mc, 0, sizeof(MatchClause));
    mc->kind = MC_ENTITY_IN;
    mc->bind_id = intern(bind_name);
    mc->container_idx = graph_find_container_by_name(intern(container));
    mc->select = (SelectMode)select_mode;
    mc->required = 1;
    mc->scope_bind_id = -1;
    mc->channel_idx = -1;
    return 0;
}

/* Add match: entity in container with where expression */
int herb_tension_match_in_where(int tidx, const char* bind_name, const char* container,
                                  int select_mode, void* where_expr) {
    int rc = herb_tension_match_in(tidx, bind_name, container, select_mode);
    if (rc < 0) return rc;
    Tension* t = &g_graph.tensions[tidx];
    t->matches[t->match_count - 1].where_expr = (Expr*)where_expr;
    return 0;
}

/* Add emit: set property to expression value */
int herb_tension_emit_set(int tidx, const char* entity_bind, const char* property,
                            void* value_expr) {
    if (tidx < 0 || tidx >= g_graph.tension_count) return -1;
    Tension* t = &g_graph.tensions[tidx];
    if (t->emit_count >= MAX_EMIT_CLAUSES) return -1;
    EmitClause* ec = &t->emits[t->emit_count++];
    herb_memset(ec, 0, sizeof(EmitClause));
    ec->kind = EC_SET;
    ec->set_entity_ref = intern(entity_bind);
    ec->set_prop_id = intern(property);
    ec->value_expr = (Expr*)value_expr;
    ec->to_ref = -1;
    ec->to_scope_bind_id = -1;
    ec->send_channel_idx = -1;
    ec->recv_channel_idx = -1;
    ec->recv_to_scope_bind_id = -1;
    ec->dup_in_scope_bind_id = -1;
    return 0;
}

/* Add emit: move entity to container */
int herb_tension_emit_move(int tidx, const char* move_type, const char* entity_bind,
                            const char* to_container) {
    if (tidx < 0 || tidx >= g_graph.tension_count) return -1;
    Tension* t = &g_graph.tensions[tidx];
    if (t->emit_count >= MAX_EMIT_CLAUSES) return -1;
    EmitClause* ec = &t->emits[t->emit_count++];
    herb_memset(ec, 0, sizeof(EmitClause));
    ec->kind = EC_MOVE;
    ec->move_type_idx = graph_find_move_type_by_name(intern(move_type));
    ec->entity_ref = intern(entity_bind);
    ec->to_ref = graph_find_container_by_name(intern(to_container));
    ec->to_scope_bind_id = -1;
    ec->send_channel_idx = -1;
    ec->recv_channel_idx = -1;
    ec->recv_to_scope_bind_id = -1;
    ec->dup_in_scope_bind_id = -1;
    return 0;
}

/* Expression builders — allocate from the static expression pool */
void* herb_expr_int(int64_t val) {
    Expr* e = alloc_expr();
    if (!e) return HERB_NULL;
    e->kind = EX_INT;
    e->int_val = val;
    return e;
}

void* herb_expr_prop(const char* prop_name, const char* of_bind) {
    Expr* e = alloc_expr();
    if (!e) return HERB_NULL;
    e->kind = EX_PROP;
    e->prop.prop_id = intern(prop_name);
    e->prop.of_id = intern(of_bind);
    return e;
}

void* herb_expr_binary(const char* op, void* left, void* right) {
    Expr* e = alloc_expr();
    if (!e) return HERB_NULL;
    e->kind = EX_BINARY;
    e->binary.op_id = intern(op);
    e->binary.left = (Expr*)left;
    e->binary.right = (Expr*)right;
    return e;
}

/* Remove all tensions owned by an entity. Returns count removed. */
int herb_remove_owner_tensions(int owner_entity) {
    int removed = 0;
    int write = 0;
    for (int read = 0; read < g_graph.tension_count; read++) {
        if (g_graph.tensions[read].owner == owner_entity) {
            removed++;
            continue;
        }
        if (write != read) {
            g_graph.tensions[write] = g_graph.tensions[read];
        }
        write++;
    }
    g_graph.tension_count = write;
    if (removed > 0) ham_mark_dirty();  /* recompile HAM bytecode */
    return removed;
}

/* Remove a single tension by name. Returns 1 if removed, 0 if not found. */
int herb_remove_tension_by_name(const char* name) {
    int name_id = intern(name);
    int write = 0;
    int removed = 0;
    for (int read = 0; read < g_graph.tension_count; read++) {
        if (g_graph.tensions[read].name_id == name_id && removed == 0) {
            removed = 1;
            continue;
        }
        if (write != read) {
            g_graph.tensions[write] = g_graph.tensions[read];
        }
        write++;
    }
    g_graph.tension_count = write;
    if (removed > 0) ham_mark_dirty();  /* recompile HAM bytecode */
    return removed;
}

/* ============================================================
 * RUNTIME CONTAINER CREATION API
 * ============================================================ */

int herb_create_container(const char* name, int kind) {
    if (g_graph.container_count >= MAX_CONTAINERS) return -1;
    int ci = g_graph.container_count++;
    Container* c = &g_graph.containers[ci];
    c->id = ci;
    c->name_id = intern(name);
    c->kind = (ContainerKind)kind;
    c->entity_type = -1;  /* accept any entity type */
    c->entity_count = 0;
    c->owner = -1;        /* global container */
    return ci;
}

/* ============================================================
 * PROGRAM FRAGMENT LOADING
 *
 * Loads a .herb binary as a process program into the running
 * system. The binary contains tensions that reference containers
 * already in the graph. Each tension is created with the given
 * owner entity and run container.
 *
 * This is the mechanism that makes "programs as data" real:
 * the C kernel no longer constructs tensions by hand. A .herb
 * binary IS the program. Loading it injects behavioral rules.
 * ============================================================ */

int herb_load_program(const uint8_t* data, herb_size_t len,
                       int owner_entity, const char* run_container) {
    BinReader reader = { data, len, 0 };
    BinReader* r = &reader;

    /* Header: magic(4) + version(1) + flags(1) + string_count(2) */
    if (len < 8) return -1;
    if (data[0] != 'H' || data[1] != 'E' || data[2] != 'R' || data[3] != 'B') return -1;
    r->pos = 4;
    if (br_u8(r) != 1) return -1;  /* version */
    br_u8(r);  /* flags */
    uint16_t str_count = br_u16(r);

    /* String table: map fragment's strings to main system's intern table */
    g_bin_str_count = 0;
    for (uint16_t i = 0; i < str_count; i++) {
        uint8_t slen = br_u8(r);
        char tmp[256];
        for (int j = 0; j < slen && j < 255; j++) tmp[j] = (char)br_u8(r);
        tmp[slen < 255 ? slen : 255] = '\0';
        g_bin_str_ids[g_bin_str_count++] = intern(tmp);
    }

    /* Resolve the run container */
    int run_cidx = -1;
    if (run_container && run_container[0]) {
        run_cidx = graph_find_container_by_name(intern(run_container));
    }

    /* Owner entity name for tension name prefixing */
    const char* owner_name = "";
    if (owner_entity >= 0 && owner_entity < g_graph.entity_count) {
        owner_name = str_of(g_graph.entities[owner_entity].name_id);
    }

    int loaded = 0;

    /* Process sections */
    while (r->pos < r->len) {
        uint8_t sec = br_u8(r);
        if (sec == 0xFF) break;  /* SEC_END */

        switch (sec) {
        /* Infrastructure sections: read count, skip if empty, error if not */
        case 0x01: case 0x02: case 0x03: case 0x04:
        case 0x05: case 0x06: case 0x07: {
            uint16_t count = br_u16(r);
            if (count > 0) {
                herb_error(HERB_ERR_WARN, "program fragment has non-empty infrastructure section");
                return -1;
            }
            break;
        }

        case 0x08: { /* Config — always 2 bytes */
            br_i16(r);
            break;
        }

        case 0x09: { /* Tensions — the payload */
            uint16_t count = br_u16(r);
            for (uint16_t i = 0; i < count; i++) {
                if (g_graph.tension_count >= MAX_TENSIONS) break;

                int ti = g_graph.tension_count++;
                Tension* t = &g_graph.tensions[ti];
                herb_memset(t, 0, sizeof(Tension));
                t->enabled = 1;
                t->owner = owner_entity;
                t->owner_run_container = run_cidx;

                /* Tension name: prefix with owner name if owned, use base name if system */
                {
                    int base_name_id = bstr(br_u16(r));
                    if (owner_entity >= 0 && owner_name[0]) {
                        const char* base_name = str_of(base_name_id);
                        char full_name[128];
                        herb_snprintf(full_name, sizeof(full_name), "%s.%s",
                                      owner_name, base_name);
                        t->name_id = intern(full_name);
                    } else {
                        t->name_id = base_name_id;
                    }
                }

                t->priority = (int)br_i16(r);
                t->pair_mode = br_u8(r);

                /* Match clauses — same parsing as load_program_binary */
                t->match_count = br_u8(r);
                for (int j = 0; j < t->match_count; j++) {
                    MatchClause* mc = &t->matches[j];
                    herb_memset(mc, 0, sizeof(MatchClause));
                    mc->required = 1;
                    mc->bind_id = -1;
                    mc->container_idx = -1;
                    mc->scope_bind_id = -1;
                    mc->scope_cname_id = -1;
                    mc->channel_idx = -1;
                    mc->key_prop_id = -1;

                    uint8_t mk = br_u8(r);
                    switch (mk) {
                        case 0x00: { /* ENTITY_IN */
                            mc->kind = MC_ENTITY_IN;
                            mc->bind_id = bstr(br_u16(r));
                            mc->required = br_u8(r);
                            uint8_t sel = br_u8(r);
                            mc->select = (sel == 1) ? SEL_EACH :
                                         (sel == 2) ? SEL_MAX_BY :
                                         (sel == 3) ? SEL_MIN_BY : SEL_FIRST;
                            mc->key_prop_id = bstr(br_u16(r));
                            uint8_t ik = br_u8(r);
                            if (ik == 0) {
                                mc->container_idx = graph_find_container_by_name(bstr(br_u16(r)));
                            } else if (ik == 1) {
                                mc->scope_bind_id = bstr(br_u16(r));
                                mc->scope_cname_id = bstr(br_u16(r));
                            } else if (ik == 2) {
                                mc->channel_idx = graph_find_channel_by_name(bstr(br_u16(r)));
                            }
                            if (br_u8(r)) mc->where_expr = br_expr(r);
                            break;
                        }
                        case 0x01: { /* EMPTY_IN */
                            mc->kind = MC_EMPTY_IN;
                            mc->bind_id = bstr(br_u16(r));
                            uint8_t sel = br_u8(r);
                            mc->select = (sel == 1) ? SEL_EACH : SEL_FIRST;
                            mc->container_count = br_u8(r);
                            for (int k = 0; k < mc->container_count; k++)
                                mc->containers[k] = graph_find_container_by_name(bstr(br_u16(r)));
                            break;
                        }
                        case 0x02: { /* CONTAINER_IS */
                            mc->kind = MC_CONTAINER_IS;
                            mc->guard_container_idx = graph_find_container_by_name(bstr(br_u16(r)));
                            mc->is_empty = br_u8(r);
                            break;
                        }
                        case 0x03: { /* GUARD */
                            mc->kind = MC_GUARD;
                            mc->guard_expr = br_expr(r);
                            break;
                        }
                    }
                }

                /* Emit clauses — same parsing as load_program_binary */
                t->emit_count = br_u8(r);
                for (int j = 0; j < t->emit_count; j++) {
                    EmitClause* ec = &t->emits[j];
                    herb_memset(ec, 0, sizeof(EmitClause));
                    ec->to_ref = -1;
                    ec->to_scope_bind_id = -1;
                    ec->recv_to_ref = -1;
                    ec->recv_to_scope_bind_id = -1;
                    ec->dup_in_ref = -1;
                    ec->dup_in_scope_bind_id = -1;

                    uint8_t ek = br_u8(r);
                    switch (ek) {
                        case 0x00: { /* MOVE */
                            ec->kind = EC_MOVE;
                            ec->move_type_idx = graph_find_move_type_by_name(bstr(br_u16(r)));
                            ec->entity_ref = bstr(br_u16(r));
                            br_to_ref(r, &ec->to_ref, &ec->to_scope_bind_id, &ec->to_scope_cname_id);
                            break;
                        }
                        case 0x01: { /* SET */
                            ec->kind = EC_SET;
                            ec->set_entity_ref = bstr(br_u16(r));
                            ec->set_prop_id = bstr(br_u16(r));
                            ec->value_expr = br_expr(r);
                            break;
                        }
                        case 0x02: { /* SEND */
                            ec->kind = EC_SEND;
                            ec->send_channel_idx = graph_find_channel_by_name(bstr(br_u16(r)));
                            ec->send_entity_ref = bstr(br_u16(r));
                            break;
                        }
                        case 0x03: { /* RECEIVE */
                            ec->kind = EC_RECEIVE;
                            ec->recv_channel_idx = graph_find_channel_by_name(bstr(br_u16(r)));
                            ec->recv_entity_ref = bstr(br_u16(r));
                            br_to_ref(r, &ec->recv_to_ref, &ec->recv_to_scope_bind_id, &ec->recv_to_scope_cname_id);
                            break;
                        }
                        case 0x04: { /* TRANSFER */
                            ec->kind = EC_TRANSFER;
                            ec->transfer_type_idx = graph_find_transfer_by_name(bstr(br_u16(r)));
                            ec->transfer_from_ref = bstr(br_u16(r));
                            ec->transfer_to_ref = bstr(br_u16(r));
                            ec->transfer_amount_expr = br_expr(r);
                            break;
                        }
                        case 0x05: { /* DUPLICATE */
                            ec->kind = EC_DUPLICATE;
                            ec->dup_entity_ref = bstr(br_u16(r));
                            br_to_ref(r, &ec->dup_in_ref, &ec->dup_in_scope_bind_id, &ec->dup_in_scope_cname_id);
                            break;
                        }
                    }
                }
                loaded++;
            }
            break;
        }

        default:
            r->pos = r->len;
            break;
        }
    }

    if (loaded > 0) ham_mark_dirty();  /* recompile HAM bytecode */
    return loaded;
}

/* ============================================================
 * HAM (HERB Abstract Machine) BRIDGE FUNCTIONS
 *
 * Non-static C functions callable from herb_ham.asm.
 * The HAM's assembly engine calls these for graph data access
 * and mutation, avoiding fragile struct offset computation in
 * assembly while proving the architecture first.
 *
 * HAM bytecode interpreter
 * ============================================================ */

/* Fill buf with entity indices from container, returns count */
int ham_scan(int container_idx, int* buf, int max_count) {
    if (container_idx < 0 || container_idx >= g_graph.container_count)
        return 0;
    Container* c = &g_graph.containers[container_idx];
    int n = c->entity_count < max_count ? c->entity_count : max_count;
    for (int i = 0; i < n; i++)
        buf[i] = c->entities[i];
    return n;
}

/* Returns integer value of property on entity. 0 if not found. */
int64_t ham_eprop(int entity_idx, int prop_id) {
    if (entity_idx < 0 || entity_idx >= g_graph.entity_count)
        return 0;
    PropVal v = entity_get_prop(entity_idx, prop_id);
    if (v.type == PV_INT) return v.i;
    if (v.type == PV_FLOAT) return (int64_t)v.f;
    return 0;
}

/* Returns entity count of container */
int ham_ecnt(int container_idx) {
    if (container_idx < 0 || container_idx >= g_graph.container_count)
        return 0;
    return g_graph.containers[container_idx].entity_count;
}

/* Returns container index where entity resides */
int ham_entity_loc(int entity_idx) {
    if (entity_idx < 0 || entity_idx >= g_graph.entity_count)
        return -1;
    return g_graph.entity_location[entity_idx];
}

/* Wrapper around try_move(). Returns 1 if successful. */
int ham_try_move(int mt_idx, int entity_idx, int to_container_idx) {
    return try_move(mt_idx, entity_idx, to_container_idx);
}

/* Sets integer property on entity. Returns 1 if value changed, 0 if same. */
int ham_eset(int entity_idx, int prop_id, int64_t value) {
    if (entity_idx < 0 || entity_idx >= g_graph.entity_count)
        return 0;
    PropVal old = entity_get_prop(entity_idx, prop_id);
    if (old.type == PV_INT && old.i == value)
        return 0;  /* Value unchanged */
    entity_set_prop(entity_idx, prop_id, pv_int(value));
    return 1;
}

/* Resolve scoped container: entity_idx + scope_name → container_idx */
int ham_resolve_scope(int entity_idx, int scope_name_id) {
    return get_scoped_container(entity_idx, scope_name_id);
}

/* Try channel send: move entity from sender scope to channel buffer */
int ham_try_channel_send(int ch_idx, int entity_idx) {
    return do_channel_send(ch_idx, entity_idx);
}

/* Try channel receive: move entity from channel buffer to target container */
int ham_try_channel_recv(int ch_idx, int entity_idx, int to_container_idx) {
    return do_channel_receive(ch_idx, entity_idx, to_container_idx);
}

/* Non-static wrapper around intern() */
int ham_intern(const char* s) {
    return intern(s);
}

/* ============================================================
 * HAM BYTECODE COMPILER — General Purpose
 *
 * Walks g_graph.tensions[] and compiles each compilable tension
 * to HAM bytecode. Tensions are sorted by priority (descending)
 * for pre-sorted bytecode that eliminates O(n²) per-step sorting.
 *
 * Opcode encoding (from HERB Bible Section 3.3):
 *   THDR(0x40): pri(1) owner(2) run_ctnr(2) tension_len(2) = 8 bytes total
 *   TEND(0x41): 1 byte
 *   FAIL(0x42): 1 byte
 *   SCAN(0x01): ctnr(2) = 3 bytes total
 *   SEL_FIRST(0x03): bind(1) = 2 bytes total
 *   SEL_MAX(0x04): bind(1) prop(2) = 4 bytes total
 *   REQUIRE(0x14): 1 byte
 *   WHERE(0x10): bind(1) = 2 bytes total
 *   ENDWHERE(0x11): 1 byte
 *   GUARD(0x12): 1 byte
 *   ENDGUARD(0x13): 1 byte
 *   IPUSH(0x20): val(4) = 5 bytes total
 *   EPROP(0x21): bind(1) prop(2) = 4 bytes total
 *   ECNT(0x22): ctnr(2) = 3 bytes total
 *   ADD(0x24): 1 byte
 *   SUB(0x25): 1 byte
 *   GT(0x27): 1 byte
 *   LT(0x28): 1 byte
 *   GTE(0x29): 1 byte
 *   LTE(0x2A): 1 byte
 *   EQ(0x2B): 1 byte
 *   NEQ(0x2C): 1 byte
 *   AND(0x2D): 1 byte
 *   NOT(0x2F): 1 byte
 *   EMOV(0x30): mt(2) bind(1) to(2) = 6 bytes total
 *   ESET(0x32): bind(1) prop(2) = 4 bytes total
 * ============================================================ */

/* Helper: write u16 little-endian to buffer */
static void ham_put_u16(uint8_t* buf, int* pos, uint16_t val) {
    buf[(*pos)++] = (uint8_t)(val & 0xFF);
    buf[(*pos)++] = (uint8_t)((val >> 8) & 0xFF);
}

/* Helper: write i32 little-endian to buffer */
static void ham_put_i32(uint8_t* buf, int* pos, int32_t val) {
    buf[(*pos)++] = (uint8_t)(val & 0xFF);
    buf[(*pos)++] = (uint8_t)((val >> 8) & 0xFF);
    buf[(*pos)++] = (uint8_t)((val >> 16) & 0xFF);
    buf[(*pos)++] = (uint8_t)((val >> 24) & 0xFF);
}

/* ---- Intern IDs for binary operators (cached) ---- */
static int ham_op_ids_init = 0;
static int ham_id_add, ham_id_sub, ham_id_mul;
static int ham_id_gt, ham_id_lt, ham_id_gte, ham_id_lte;
static int ham_id_eq, ham_id_neq, ham_id_and, ham_id_or;

static void ham_init_op_ids(void) {
    if (ham_op_ids_init) return;
    ham_id_add = intern("+");  ham_id_sub = intern("-");  ham_id_mul = intern("*");
    ham_id_gt  = intern(">");  ham_id_lt  = intern("<");
    ham_id_gte = intern(">="); ham_id_lte = intern("<=");
    ham_id_eq  = intern("=="); ham_id_neq = intern("!=");
    ham_id_and = intern("and"); ham_id_or = intern("or");
    ham_op_ids_init = 1;
}

/* ---- Expression compilability check (recursive) ---- */
static int ham_expr_compilable(Expr* e) {
    if (!e) return 0;
    switch (e->kind) {
        case EX_INT:  return 1;
        case EX_BOOL: return 1;
        case EX_PROP: return 1;
        case EX_COUNT:
            return !e->count.is_scoped && !e->count.is_channel
                   && e->count.container_idx >= 0;
        case EX_BINARY: {
            ham_init_op_ids();
            int op = e->binary.op_id;
            if (op == ham_id_mul || op == ham_id_or) return 0;
            return ham_expr_compilable(e->binary.left)
                && ham_expr_compilable(e->binary.right);
        }
        case EX_UNARY:
            return ham_expr_compilable(e->unary.arg);
        default: return 0; /* EX_FLOAT, EX_STRING, EX_IN_OF unsupported */
    }
}

/* ---- Tension compilability check ---- */
static int ham_tension_compilable(Tension* t) {
    if (!t->enabled) return 0;
    /* owner gate removed — all tensions compilable regardless of ownership */

    for (int i = 0; i < t->match_count; i++) {
        MatchClause* mc = &t->matches[i];
        if (mc->kind == MC_ENTITY_IN) {
            if (mc->where_expr && !ham_expr_compilable(mc->where_expr)) return 0;
        } else if (mc->kind == MC_EMPTY_IN) {
            if (mc->container_count != 1) return 0;
        } else if (mc->kind == MC_GUARD) {
            if (!mc->guard_expr || !ham_expr_compilable(mc->guard_expr)) return 0;
        } else if (mc->kind == MC_CONTAINER_IS) {
            /* Always compilable */
        } else {
            return 0;
        }
    }

    for (int i = 0; i < t->emit_count; i++) {
        EmitClause* ec = &t->emits[i];
        if (ec->kind == EC_MOVE) {
            /* Scoped and non-scoped both supported */
        } else if (ec->kind == EC_SET) {
            if (!ec->value_expr || !ham_expr_compilable(ec->value_expr)) return 0;
        } else if (ec->kind == EC_SEND) {
            /* Supported */
        } else if (ec->kind == EC_RECEIVE) {
            /* Supported (scoped target) */
        } else {
            return 0; /* EC_TRANSFER, EC_DUPLICATE */
        }
    }

    return 1;
}

/* ---- Binding register map ---- */
#define HAM_MAX_BINDS 4
typedef struct {
    int ids[HAM_MAX_BINDS];    /* interned bind name */
    int regs[HAM_MAX_BINDS];   /* register index 0=B0, 1=B1, 2=B2, 3=B3 */
    int count;
} HamBindMap;

static int ham_bind_lookup(HamBindMap* m, int bind_id) {
    for (int i = 0; i < m->count; i++)
        if (m->ids[i] == bind_id) return m->regs[i];
    return -1;
}

static int ham_bind_alloc(HamBindMap* m, int bind_id) {
    int r = ham_bind_lookup(m, bind_id);
    if (r >= 0) return r;
    if (m->count >= HAM_MAX_BINDS) return -1;
    int reg = m->count;
    m->ids[m->count] = bind_id;
    m->regs[m->count] = reg;
    m->count++;
    return reg;
}

/* ---- Expression compiler (recursive) ---- */
static int ham_compile_expr(Expr* e, uint8_t* buf, int* pos,
                            HamBindMap* bm, int buf_size) {
    if (!e || *pos >= buf_size - 10) return 0;

    switch (e->kind) {
        case EX_INT:
            buf[(*pos)++] = 0x20;  /* IPUSH */
            ham_put_i32(buf, pos, (int32_t)e->int_val);
            return 1;

        case EX_BOOL:
            buf[(*pos)++] = 0x20;  /* IPUSH */
            ham_put_i32(buf, pos, e->bool_val ? 1 : 0);
            return 1;

        case EX_PROP: {
            int reg = ham_bind_lookup(bm, e->prop.of_id);
            if (reg < 0) return 0;
            buf[(*pos)++] = 0x21;  /* EPROP */
            buf[(*pos)++] = (uint8_t)reg;
            ham_put_u16(buf, pos, (uint16_t)e->prop.prop_id);
            return 1;
        }

        case EX_COUNT:
            buf[(*pos)++] = 0x22;  /* ECNT */
            ham_put_u16(buf, pos, (uint16_t)e->count.container_idx);
            return 1;

        case EX_BINARY: {
            if (!ham_compile_expr(e->binary.left, buf, pos, bm, buf_size)) return 0;
            if (!ham_compile_expr(e->binary.right, buf, pos, bm, buf_size)) return 0;
            ham_init_op_ids();
            int op = e->binary.op_id;
            if      (op == ham_id_add) buf[(*pos)++] = 0x24;
            else if (op == ham_id_sub) buf[(*pos)++] = 0x25;
            else if (op == ham_id_gt)  buf[(*pos)++] = 0x27;
            else if (op == ham_id_lt)  buf[(*pos)++] = 0x28;
            else if (op == ham_id_gte) buf[(*pos)++] = 0x29;
            else if (op == ham_id_lte) buf[(*pos)++] = 0x2A;
            else if (op == ham_id_eq)  buf[(*pos)++] = 0x2B;
            else if (op == ham_id_neq) buf[(*pos)++] = 0x2C;
            else if (op == ham_id_and) buf[(*pos)++] = 0x2D;
            else return 0;
            return 1;
        }

        case EX_UNARY:
            if (!ham_compile_expr(e->unary.arg, buf, pos, bm, buf_size)) return 0;
            buf[(*pos)++] = 0x2F;  /* NOT */
            return 1;

        default: return 0;
    }
}

/* ---- Compile a single tension ---- */
static int ham_compile_tension(Tension* t, uint8_t* buf, int* pos,
                               int buf_size) {
    HamBindMap bm;
    bm.count = 0;

    /* Pre-allocate bindings by scanning match clauses */
    for (int i = 0; i < t->match_count; i++) {
        MatchClause* mc = &t->matches[i];
        if (mc->bind_id >= 0) {
            if (ham_bind_alloc(&bm, mc->bind_id) < 0)
                return 0; /* Too many bindings */
        }
    }

    int t_start = *pos;

    /* THDR: priority(1) owner(2) run_container(2) tension_len(2) */
    buf[(*pos)++] = 0x40;
    buf[(*pos)++] = (uint8_t)(t->priority > 255 ? 255 : t->priority);
    ham_put_u16(buf, pos, t->owner >= 0 ? (uint16_t)t->owner : 0xFFFF);
    ham_put_u16(buf, pos, t->owner_run_container >= 0
                          ? (uint16_t)t->owner_run_container : 0xFFFF);
    int len_pos = *pos;
    ham_put_u16(buf, pos, 0); /* tension_len placeholder */

    /* Compile match clauses */
    for (int i = 0; i < t->match_count; i++) {
        MatchClause* mc = &t->matches[i];

        if (mc->kind == MC_ENTITY_IN) {
            /* SCAN container (may be scoped or channel) */
            if (mc->scope_bind_id >= 0) {
                /* Scoped: try binding register first, fallback to entity name */
                int scope_reg = ham_bind_lookup(&bm, mc->scope_bind_id);
                if (scope_reg >= 0) {
                    /* Owner is a bound entity — resolve at runtime */
                    buf[(*pos)++] = 0x02; /* SCAN_SCOPED */
                    buf[(*pos)++] = (uint8_t)scope_reg;
                    ham_put_u16(buf, pos, (uint16_t)mc->scope_cname_id);
                } else {
                    /* Owner is a global entity name — resolve at compile time */
                    int scope_eid = graph_find_entity_by_name(mc->scope_bind_id);
                    if (scope_eid < 0) return 0;
                    int scoped_ctnr = get_scoped_container(scope_eid, mc->scope_cname_id);
                    if (scoped_ctnr < 0) return 0;
                    buf[(*pos)++] = 0x01; /* SCAN (normal — into resolved scoped container) */
                    ham_put_u16(buf, pos, (uint16_t)scoped_ctnr);
                }
            } else if (mc->channel_idx >= 0) {
                /* Channel: resolve buffer container at compile time */
                int buffer_ctnr = g_graph.channels[mc->channel_idx].buffer_container_idx;
                buf[(*pos)++] = 0x01; /* SCAN (normal — into channel buffer) */
                ham_put_u16(buf, pos, (uint16_t)buffer_ctnr);
            } else {
                buf[(*pos)++] = 0x01; /* SCAN (normal) */
                ham_put_u16(buf, pos, (uint16_t)mc->container_idx);
            }

            /* WHERE filter (if any) */
            if (mc->where_expr && mc->bind_id >= 0) {
                int reg = ham_bind_lookup(&bm, mc->bind_id);
                if (reg < 0) return 0;
                buf[(*pos)++] = 0x10; /* WHERE */
                buf[(*pos)++] = (uint8_t)reg;
                if (!ham_compile_expr(mc->where_expr, buf, pos, &bm, buf_size))
                    return 0;
                buf[(*pos)++] = 0x11; /* ENDWHERE */
            }

            /* Select mode */
            if (mc->bind_id >= 0) {
                int reg = ham_bind_lookup(&bm, mc->bind_id);
                if (reg < 0) return 0;

                if (mc->select == SEL_FIRST) {
                    buf[(*pos)++] = 0x03; /* SEL_FIRST */
                    buf[(*pos)++] = (uint8_t)reg;
                } else if (mc->select == SEL_MAX_BY) {
                    buf[(*pos)++] = 0x04; /* SEL_MAX */
                    buf[(*pos)++] = (uint8_t)reg;
                    ham_put_u16(buf, pos, (uint16_t)mc->key_prop_id);
                } else if (mc->select == SEL_MIN_BY) {
                    buf[(*pos)++] = 0x05; /* SEL_MIN */
                    buf[(*pos)++] = (uint8_t)reg;
                    ham_put_u16(buf, pos, (uint16_t)mc->key_prop_id);
                } else if (mc->select == SEL_EACH) {
                    buf[(*pos)++] = 0x06; /* SEL_EACH */
                    buf[(*pos)++] = (uint8_t)reg;
                }
            }

            /* REQUIRE if needed */
            if (mc->required) {
                buf[(*pos)++] = 0x14;
            }

        } else if (mc->kind == MC_EMPTY_IN) {
            /* Check single container is empty:
             * ECNT(ctnr) + IPUSH(0) + EQ + GUARD + ENDGUARD */
            buf[(*pos)++] = 0x22; /* ECNT */
            ham_put_u16(buf, pos, (uint16_t)mc->containers[0]);
            buf[(*pos)++] = 0x20; /* IPUSH 0 */
            ham_put_i32(buf, pos, 0);
            buf[(*pos)++] = 0x2B; /* EQ */
            buf[(*pos)++] = 0x12; /* GUARD */
            buf[(*pos)++] = 0x13; /* ENDGUARD */

        } else if (mc->kind == MC_CONTAINER_IS) {
            /* Check container empty/non-empty */
            buf[(*pos)++] = 0x22; /* ECNT */
            ham_put_u16(buf, pos, (uint16_t)mc->guard_container_idx);
            buf[(*pos)++] = 0x20; /* IPUSH 0 */
            ham_put_i32(buf, pos, 0);
            if (mc->is_empty) {
                buf[(*pos)++] = 0x2B; /* EQ (count == 0) */
            } else {
                buf[(*pos)++] = 0x27; /* GT (count > 0) */
            }
            buf[(*pos)++] = 0x12; /* GUARD */
            buf[(*pos)++] = 0x13; /* ENDGUARD */

        } else if (mc->kind == MC_GUARD) {
            /* Compile guard expression + GUARD */
            if (!ham_compile_expr(mc->guard_expr, buf, pos, &bm, buf_size))
                return 0;
            buf[(*pos)++] = 0x12; /* GUARD */
            buf[(*pos)++] = 0x13; /* ENDGUARD */
        }

        if (*pos >= buf_size - 20) return 0; /* Buffer safety */
    }

    /* Compile emit clauses */
    for (int i = 0; i < t->emit_count; i++) {
        EmitClause* ec = &t->emits[i];

        if (ec->kind == EC_MOVE) {
            int reg = ham_bind_lookup(&bm, ec->entity_ref);
            if (reg < 0) return 0;

            if (ec->to_scope_bind_id >= 0) {
                /* Scoped move: try binding register first, fallback to entity name */
                int owner_reg = ham_bind_lookup(&bm, ec->to_scope_bind_id);
                if (owner_reg >= 0) {
                    /* Owner is bound — resolve at runtime */
                    buf[(*pos)++] = 0x31; /* EMOV_S */
                    ham_put_u16(buf, pos, (uint16_t)ec->move_type_idx);
                    buf[(*pos)++] = (uint8_t)reg;      /* entity bind */
                    buf[(*pos)++] = (uint8_t)owner_reg; /* scope owner bind */
                    ham_put_u16(buf, pos, (uint16_t)ec->to_scope_cname_id);
                } else {
                    /* Owner is a global entity — resolve at compile time */
                    int scope_eid = graph_find_entity_by_name(ec->to_scope_bind_id);
                    if (scope_eid < 0) return 0;
                    int to_ctnr = get_scoped_container(scope_eid, ec->to_scope_cname_id);
                    if (to_ctnr < 0) return 0;
                    buf[(*pos)++] = 0x30; /* EMOV (normal — resolved scoped target) */
                    ham_put_u16(buf, pos, (uint16_t)ec->move_type_idx);
                    buf[(*pos)++] = (uint8_t)reg;
                    ham_put_u16(buf, pos, (uint16_t)to_ctnr);
                }
            } else {
                /* Non-scoped: resolve container at compile time */
                int to_ctnr = graph_find_container_by_name(ec->to_ref);
                if (to_ctnr < 0) {
                    for (int mi = 0; mi < t->match_count; mi++) {
                        MatchClause* mc2 = &t->matches[mi];
                        if (mc2->kind == MC_EMPTY_IN && mc2->bind_id == ec->to_ref) {
                            to_ctnr = mc2->containers[0];
                            break;
                        }
                    }
                }
                if (to_ctnr < 0) return 0;
                buf[(*pos)++] = 0x30; /* EMOV */
                ham_put_u16(buf, pos, (uint16_t)ec->move_type_idx);
                buf[(*pos)++] = (uint8_t)reg;
                ham_put_u16(buf, pos, (uint16_t)to_ctnr);
            }

        } else if (ec->kind == EC_SET) {
            int reg = ham_bind_lookup(&bm, ec->set_entity_ref);
            if (reg < 0) return 0;
            /* Compile value expression */
            if (!ham_compile_expr(ec->value_expr, buf, pos, &bm, buf_size))
                return 0;
            buf[(*pos)++] = 0x32; /* ESET */
            buf[(*pos)++] = (uint8_t)reg;
            ham_put_u16(buf, pos, (uint16_t)ec->set_prop_id);

        } else if (ec->kind == EC_SEND) {
            int reg = ham_bind_lookup(&bm, ec->send_entity_ref);
            if (reg < 0) return 0;
            buf[(*pos)++] = 0x33; /* ESEND */
            ham_put_u16(buf, pos, (uint16_t)ec->send_channel_idx);
            buf[(*pos)++] = (uint8_t)reg;

        } else if (ec->kind == EC_RECEIVE) {
            int entity_reg = ham_bind_lookup(&bm, ec->recv_entity_ref);
            if (entity_reg < 0) return 0;
            if (ec->recv_to_scope_bind_id >= 0) {
                /* Scoped receive target — try binding, fallback to entity name */
                int owner_reg = ham_bind_lookup(&bm, ec->recv_to_scope_bind_id);
                if (owner_reg >= 0) {
                    buf[(*pos)++] = 0x35; /* ERECV_S */
                    ham_put_u16(buf, pos, (uint16_t)ec->recv_channel_idx);
                    buf[(*pos)++] = (uint8_t)entity_reg;
                    buf[(*pos)++] = (uint8_t)owner_reg;
                    ham_put_u16(buf, pos, (uint16_t)ec->recv_to_scope_cname_id);
                } else {
                    /* Owner is a global entity — not expected for RECV but handle */
                    return 0;
                }
            } else {
                return 0; /* Non-scoped receive not implemented (ERECV) */
            }
        }

        if (*pos >= buf_size - 10) return 0;
    }

    /* TEND */
    buf[(*pos)++] = 0x41;

    /* Patch tension_len */
    int t_len = *pos - t_start;
    buf[len_pos]     = (uint8_t)(t_len & 0xFF);
    buf[len_pos + 1] = (uint8_t)((t_len >> 8) & 0xFF);

    return 1;
}

/* ============================================================
 * ham_compile_all — Compile ALL tensions to bytecode
 *
 * compiles system, shell, and process tensions.
 * Walks g_graph.tensions[], sorts by priority (descending),
 * compiles each compilable tension. Returns total bytes written.
 * *out_count is set to the number of tensions compiled.
 * Warns on serial if any tension is skipped.
 * ============================================================ */

int ham_compile_all(uint8_t* buf, int buf_size, int* out_count) {
    ham_init_op_ids();

    /* Build priority-sorted order (descending) */
    int order[MAX_TENSIONS];
    int n = g_graph.tension_count;
    for (int i = 0; i < n; i++) order[i] = i;
    for (int i = 0; i < n - 1; i++)
        for (int j = i + 1; j < n; j++)
            if (g_graph.tensions[order[i]].priority <
                g_graph.tensions[order[j]].priority) {
                int tmp = order[i]; order[i] = order[j]; order[j] = tmp;
            }

    int pos = 0;
    int compiled = 0;

    for (int i = 0; i < n; i++) {
        Tension* t = &g_graph.tensions[order[i]];
        if (!ham_tension_compilable(t)) continue;

        int save_pos = pos;
        if (ham_compile_tension(t, buf, &pos, buf_size)) {
            compiled++;
        } else {
            pos = save_pos; /* Rollback on failure */
        }
    }

    if (out_count) *out_count = compiled;
    return pos;
}

#ifdef HERB_BINARY_ONLY
/* ============================================================
 * Global HAM bytecode buffer + lazy recompilation
 *
 * All tension resolution goes through ham_run_ham(). The global
 * bytecode buffer is recompiled only when tensions change
 * (dirty flag set by mutation functions).
 *
 * Only compiled for bare metal (HERB_BINARY_ONLY) where
 * herb_ham.asm provides ham_run(). Test builds use herb_run().
 * ============================================================ */

#define HAM_BYTECODE_SIZE 8192
static uint8_t g_ham_bytecode[HAM_BYTECODE_SIZE];
static int g_ham_bytecode_len = 0;
static int g_ham_compiled_count = 0;
static int g_ham_dirty = 1;  /* start dirty — must compile before first run */

void ham_mark_dirty(void) { g_ham_dirty = 1; }

static void ham_ensure_compiled(void) {
    if (!g_ham_dirty) return;
    g_ham_bytecode_len = ham_compile_all(g_ham_bytecode, HAM_BYTECODE_SIZE, &g_ham_compiled_count);
    g_ham_dirty = 0;
}

/* ham_run is in herb_ham.asm */
extern int ham_run(uint8_t* bytecode_ptr, int bytecode_len);

int ham_run_ham(int max_steps) {
    ham_ensure_compiled();
    if (g_ham_bytecode_len <= 0) return 0;  /* no bytecode = no ops */
    return ham_run(g_ham_bytecode, g_ham_bytecode_len);
}

int ham_get_compiled_count(void) { return g_ham_compiled_count; }
int ham_get_bytecode_len(void) { return g_ham_bytecode_len; }
#endif /* HERB_BINARY_ONLY */
