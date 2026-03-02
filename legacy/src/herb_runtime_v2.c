/*
 * HERB v2 Native Runtime — The Tension Resolution Engine
 *
 * Loads a .herb.json program, builds the container/entity/move graph in C,
 * evaluates tension patterns, and executes the step/run loop.
 *
 * This is NOT a compiler. This is a native engine that interprets HERB
 * programs at native speed. The program is data; the engine makes it live.
 *
 * Scope:
 *   - Containers (SIMPLE, SLOT) with entity types
 *   - Entities with properties (int, float, string)
 *   - Moves (regular and scoped)
 *   - Scoped containers: per-entity isolated namespaces
 *   - Channels: cross-scope send/receive with buffer containers
 *   - Conservation pools and quantity transfers
 *   - Entity duplication (Zircon handle_duplicate)
 *   - Nesting depth bound
 *   - Tensions with full match/emit interpretation
 *   - Expression evaluation (prop, count, binary/unary, in/of)
 *   - step() / run() loop
 *   - Runtime entity creation (for signals)
 *
 * Usage:
 *   herb_runtime_v2 program.herb.json
 *
 * Accepts commands on stdin:
 *   run                              — resolve tensions to fixpoint
 *   create <name> <type> <container> — create entity at runtime
 *   state                            — output final state as JSON
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ============================================================
 * CONFIGURATION
 * ============================================================ */

#define MAX_ENTITIES      512
#define MAX_CONTAINERS    256
#define MAX_MOVE_TYPES    64
#define MAX_TENSIONS      64
#define MAX_MATCH_CLAUSES 8
#define MAX_EMIT_CLAUSES  8
#define MAX_STRINGS       1024
#define MAX_STRING_LEN    128
#define MAX_ENTITY_PER_CONTAINER 64
#define MAX_PROPERTIES    16
#define MAX_FROM_TO       16
#define MAX_BINDINGS      32
#define MAX_BINDING_SETS  128
#define MAX_INTENDED_MOVES 128
#define MAX_STEPS         100
#define MAX_OPS           2048
#define MAX_SCOPE_TEMPLATES 16
#define MAX_CHANNELS      16
#define MAX_POOLS         16
#define MAX_TRANSFERS     16

/* ============================================================
 * STRING INTERN TABLE
 * ============================================================ */

static char g_strings[MAX_STRINGS][MAX_STRING_LEN];
static int g_string_count = 0;

int intern(const char* s) {
    for (int i = 0; i < g_string_count; i++) {
        if (strcmp(g_strings[i], s) == 0) return i;
    }
    if (g_string_count >= MAX_STRINGS) {
        fprintf(stderr, "String table full\n");
        return -1;
    }
    strncpy(g_strings[g_string_count], s, MAX_STRING_LEN - 1);
    g_strings[g_string_count][MAX_STRING_LEN - 1] = '\0';
    return g_string_count++;
}

const char* str_of(int id) {
    if (id >= 0 && id < g_string_count) return g_strings[id];
    return "?";
}

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

PropVal pv_none(void) { PropVal v; v.type = PV_NONE; return v; }
PropVal pv_int(int64_t i) { PropVal v; v.type = PV_INT; v.i = i; return v; }
PropVal pv_float(double f) { PropVal v; v.type = PV_FLOAT; v.f = f; return v; }
PropVal pv_string(int s) { PropVal v; v.type = PV_STRING; v.s = s; return v; }

double pv_as_number(PropVal v) {
    if (v.type == PV_INT) return (double)v.i;
    if (v.type == PV_FLOAT) return v.f;
    return 0.0;
}

int pv_is_truthy(PropVal v) {
    if (v.type == PV_NONE) return 0;
    if (v.type == PV_INT) return v.i != 0;
    if (v.type == PV_FLOAT) return v.f != 0.0;
    if (v.type == PV_STRING) return 1;
    return 0;
}

int pv_equal(PropVal a, PropVal b) {
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

static Expr g_expr_pool[4096];
static int g_expr_count = 0;

Expr* alloc_expr(void) {
    if (g_expr_count >= 4096) { fprintf(stderr, "Expr pool full\n"); exit(1); }
    Expr* e = &g_expr_pool[g_expr_count++];
    memset(e, 0, sizeof(Expr));
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
    MatchClause matches[MAX_MATCH_CLAUSES];
    int match_count;
    EmitClause emits[MAX_EMIT_CLAUSES];
    int emit_count;
    int pair_mode;  /* 0 = zip, 1 = cross */
} Tension;

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

static Graph g_graph;

/* ============================================================
 * GRAPH OPERATIONS
 * ============================================================ */

int graph_find_container_by_name(int name_id) {
    for (int i = 0; i < g_graph.container_count; i++) {
        if (g_graph.containers[i].name_id == name_id) return i;
    }
    return -1;
}

int graph_find_entity_by_name(int name_id) {
    for (int i = 0; i < g_graph.entity_count; i++) {
        if (g_graph.entities[i].name_id == name_id) return i;
    }
    return -1;
}

int graph_find_move_type_by_name(int name_id) {
    for (int i = 0; i < g_graph.move_type_count; i++) {
        if (g_graph.move_types[i].name_id == name_id) return i;
    }
    return -1;
}

int graph_find_channel_by_name(int name_id) {
    for (int i = 0; i < g_graph.channel_count; i++) {
        if (g_graph.channels[i].name_id == name_id) return i;
    }
    return -1;
}

int graph_find_transfer_by_name(int name_id) {
    for (int i = 0; i < g_graph.transfer_type_count; i++) {
        if (g_graph.transfer_types[i].name_id == name_id) return i;
    }
    return -1;
}

void container_add(int ci, int ei) {
    Container* c = &g_graph.containers[ci];
    if (c->entity_count < MAX_ENTITY_PER_CONTAINER) {
        c->entities[c->entity_count++] = ei;
    }
}

void container_remove(int ci, int ei) {
    Container* c = &g_graph.containers[ci];
    for (int i = 0; i < c->entity_count; i++) {
        if (c->entities[i] == ei) {
            c->entities[i] = c->entities[--c->entity_count];
            return;
        }
    }
}

PropVal entity_get_prop(int ei, int prop_id) {
    Entity* e = &g_graph.entities[ei];
    for (int i = 0; i < e->prop_count; i++) {
        if (e->prop_keys[i] == prop_id) return e->prop_vals[i];
    }
    return pv_none();
}

void entity_set_prop(int ei, int prop_id, PropVal val) {
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

/* Get scoped container for an entity by scope name */
int get_scoped_container(int entity_idx, int scope_name_id) {
    if (entity_idx < 0 || entity_idx >= g_graph.entity_count) return -1;
    for (int i = 0; i < g_graph.entity_scope_count[entity_idx]; i++) {
        if (g_graph.entity_scope_names[entity_idx][i] == scope_name_id)
            return g_graph.entity_scope_cids[entity_idx][i];
    }
    return -1;
}

/* Get scope templates for an entity type */
int get_type_scope_idx(int type_name_id) {
    for (int i = 0; i < g_graph.type_scope_count; i++) {
        if (g_graph.type_scope_type_ids[i] == type_name_id) return i;
    }
    return -1;
}

/* Create entity with auto-scoped container creation */
int create_entity(int type_name_id, int name_id, int container_idx) {
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
            snprintf(cname, sizeof(cname), "%s::%s", ent_name, str_of(st->name_id));
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
int is_property_pooled(int prop_id) {
    for (int i = 0; i < g_graph.pool_count; i++) {
        if (g_graph.pools[i].property_id == prop_id) return 1;
    }
    return 0;
}

/* Regular move: returns 1 if executed */
int try_move(int mt_idx, int entity_idx, int to_container_idx) {
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
int do_channel_send(int ch_idx, int entity_idx) {
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
int do_channel_receive(int ch_idx, int entity_idx, int to_container_idx) {
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

/* Quantity transfer */
int do_transfer(int tt_idx, int from_entity, int to_entity, int64_t amount) {
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
int do_duplicate(int source_idx, int container_idx) {
    Entity* src = &g_graph.entities[source_idx];

    g_graph.dup_counter++;
    char dup_name[64];
    snprintf(dup_name, sizeof(dup_name), "_dup_%d", g_graph.dup_counter);

    int ei = g_graph.entity_count++;
    Entity* e = &g_graph.entities[ei];
    e->id = ei;
    e->type_id = src->type_id;
    e->name_id = intern(dup_name);
    e->prop_count = src->prop_count;
    memcpy(e->prop_keys, src->prop_keys, sizeof(int) * src->prop_count);
    memcpy(e->prop_vals, src->prop_vals, sizeof(PropVal) * src->prop_count);

    g_graph.entity_location[ei] = container_idx;
    g_graph.entity_scope_count[ei] = 0;
    if (container_idx >= 0) {
        container_add(container_idx, ei);
    }
    g_graph.op_count++;
    return ei;
}

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

int bindings_get(Bindings* b, int name_id) {
    for (int i = 0; i < b->count; i++) {
        if (b->names[i] == name_id) return b->values[i];
    }
    return -1;
}

int bindings_is_unbound(Bindings* b, int name_id) {
    for (int i = 0; i < b->unbound_count; i++) {
        if (b->unbound[i] == name_id) return 1;
    }
    return 0;
}

int resolve_ref(int ref_id, Bindings* b) {
    int val = bindings_get(b, ref_id);
    if (val >= 0) return val;
    val = graph_find_entity_by_name(ref_id);
    if (val >= 0) return val;
    val = graph_find_container_by_name(ref_id);
    if (val >= 0) return val;
    return -1;
}

int resolve_container_ref(int ref_id, Bindings* b) {
    int val = bindings_get(b, ref_id);
    if (val >= 0) return val;
    return graph_find_container_by_name(ref_id);
}

/* Resolve a scoped container reference from bindings */
int resolve_scoped_ref(int scope_bind_id, int scope_cname_id, Bindings* b) {
    int scope_entity = bindings_get(b, scope_bind_id);
    if (scope_entity < 0) {
        scope_entity = graph_find_entity_by_name(scope_bind_id);
    }
    if (scope_entity < 0) return -1;
    return get_scoped_container(scope_entity, scope_cname_id);
}

PropVal eval_expr(Expr* expr, Bindings* b) {
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

int evaluate_tension(Tension* t, IntendedAction* out, int max_out) {
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
                    memcpy(&test_b, &scalars, sizeof(Bindings));
                    test_b.names[test_b.count] = mc->bind_id;
                    test_b.values[test_b.count] = results[i];
                    test_b.count++;
                    PropVal result = eval_expr(mc->where_expr, &test_b);
                    if (pv_is_truthy(result)) {
                        filtered[fcount++] = results[i];
                    }
                }
                rcount = fcount;
                memcpy(results, filtered, sizeof(int) * fcount);
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
                    memcpy(vec_values[vec_count], results, sizeof(int) * rcount);
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
                    memcpy(vec_values[vec_count], empty, sizeof(int) * ecount);
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
            memcpy(&bs, &scalars, sizeof(Bindings));
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
                memcpy(&bs, &scalars, sizeof(Bindings));
                bs.names[bs.count] = vec_bind_ids[0];
                bs.values[bs.count] = vec_values[0][i];
                bs.count++;
                bsl.sets[bsl.count++] = bs;
            }
        } else if (vec_count == 2) {
            for (int i = 0; i < vec_counts[0]; i++)
                for (int j = 0; j < vec_counts[1] && bsl.count < MAX_BINDING_SETS; j++) {
                    Bindings bs;
                    memcpy(&bs, &scalars, sizeof(Bindings));
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
                memset(ia, 0, sizeof(IntendedAction));
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
                memset(ia, 0, sizeof(IntendedAction));
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
                memset(ia, 0, sizeof(IntendedAction));
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
                memset(ia, 0, sizeof(IntendedAction));
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
                memset(ia, 0, sizeof(IntendedAction));
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
                memset(ia, 0, sizeof(IntendedAction));
                ia->kind = IA_DUPLICATE;
                ia->dup_source_entity = entity_idx;
                ia->dup_container_idx = in_idx;
            }
        }
    }

    return action_count;
}

/* ============================================================
 * STEP / RUN
 * ============================================================ */

int step(void) {
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

int run(int max_steps) {
    int total = 0;
    for (int i = 0; i < max_steps; i++) {
        int executed = step();
        if (executed == 0) break;
        total += executed;
    }
    return total;
}

/* ============================================================
 * MINIMAL JSON PARSER
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
    return calloc(1, sizeof(JsonValue));
}

static const char* json_parse_value(const char* p, JsonValue** out);

static const char* json_parse_string_raw(const char* p, char** out) {
    if (*p != '"') return NULL;
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
    *out = strdup(buf);
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
    if (is_float) { v->type = JT_FLOAT; v->float_val = atof(buf); }
    else { v->type = JT_INT; v->int_val = atoll(buf); }
    *out = v;
    return p;
}

static const char* json_parse_value(const char* p, JsonValue** out) {
    p = json_skip_ws(p);
    if (!*p) return NULL;

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

    if (strncmp(p, "true", 4) == 0) {
        JsonValue* v = json_alloc();
        v->type = JT_BOOL; v->bool_val = 1;
        *out = v; return p + 4;
    }
    if (strncmp(p, "false", 5) == 0) {
        JsonValue* v = json_alloc();
        v->type = JT_BOOL; v->bool_val = 0;
        *out = v; return p + 5;
    }
    if (strncmp(p, "null", 4) == 0) {
        JsonValue* v = json_alloc();
        v->type = JT_NULL;
        *out = v; return p + 4;
    }

    if (*p == '[') {
        p++;
        JsonValue* v = json_alloc();
        v->type = JT_ARRAY;
        v->array.cap = 16;
        v->array.items = calloc(v->array.cap, sizeof(JsonValue*));
        v->array.count = 0;
        p = json_skip_ws(p);
        if (*p != ']') {
            while (1) {
                JsonValue* item;
                p = json_parse_value(p, &item);
                if (!p) return NULL;
                if (v->array.count >= v->array.cap) {
                    v->array.cap *= 2;
                    v->array.items = realloc(v->array.items, sizeof(JsonValue*) * v->array.cap);
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
        v->object.keys = calloc(v->object.cap, sizeof(char*));
        v->object.values = calloc(v->object.cap, sizeof(JsonValue*));
        v->object.count = 0;
        p = json_skip_ws(p);
        if (*p != '}') {
            while (1) {
                p = json_skip_ws(p);
                char* key;
                p = json_parse_string_raw(p, &key);
                if (!p) return NULL;
                p = json_skip_ws(p);
                if (*p == ':') p++;
                JsonValue* val;
                p = json_parse_value(p, &val);
                if (!p) return NULL;
                if (v->object.count >= v->object.cap) {
                    v->object.cap *= 2;
                    v->object.keys = realloc(v->object.keys, sizeof(char*) * v->object.cap);
                    v->object.values = realloc(v->object.values, sizeof(JsonValue*) * v->object.cap);
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

    return NULL;
}

JsonValue* json_get(JsonValue* obj, const char* key) {
    if (!obj || obj->type != JT_OBJECT) return NULL;
    for (int i = 0; i < obj->object.count; i++) {
        if (strcmp(obj->object.keys[i], key) == 0)
            return obj->object.values[i];
    }
    return NULL;
}

const char* json_str(JsonValue* v) {
    if (!v || v->type != JT_STRING) return NULL;
    return v->string_val;
}

int64_t json_int(JsonValue* v) {
    if (!v) return 0;
    if (v->type == JT_INT) return v->int_val;
    if (v->type == JT_FLOAT) return (int64_t)v->float_val;
    return 0;
}

int json_array_len(JsonValue* v) {
    if (!v || v->type != JT_ARRAY) return 0;
    return v->array.count;
}

JsonValue* json_array_get(JsonValue* v, int i) {
    if (!v || v->type != JT_ARRAY || i < 0 || i >= v->array.count) return NULL;
    return v->array.items[i];
}

int json_bool(JsonValue* v) {
    if (!v) return 1;
    if (v->type == JT_BOOL) return v->bool_val;
    if (v->type == JT_INT) return v->int_val != 0;
    return 1;
}

/* ============================================================
 * BUILD EXPRESSION FROM JSON
 * ============================================================ */

Expr* build_expr(JsonValue* jv) {
    if (!jv) return NULL;

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
            if (strcmp(op_str, "not") == 0) {
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

    return NULL;
}

/* ============================================================
 * LOAD PROGRAM FROM JSON
 * ============================================================ */

void load_program(JsonValue* root) {
    memset(&g_graph, 0, sizeof(Graph));
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
                if (kind_str && strcmp(kind_str, "slot") == 0) st->kind = CK_SLOT;
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
        if (kind_str && strcmp(kind_str, "slot") == 0) c->kind = CK_SLOT;
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
        memset(mt, 0, sizeof(MoveType));
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
        snprintf(buf_name, sizeof(buf_name), "channel:%s", ch_name);
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
        memset(t, 0, sizeof(Tension));

        const char* tname = json_str(json_get(jt, "name"));
        t->name_id = intern(tname);
        t->priority = (int)json_int(json_get(jt, "priority"));

        const char* pair = json_str(json_get(jt, "pair"));
        t->pair_mode = (pair && strcmp(pair, "cross") == 0) ? 1 : 0;

        /* Match clauses */
        JsonValue* jmatches = json_get(jt, "match");
        t->match_count = 0;
        for (int j = 0; j < json_array_len(jmatches); j++) {
            JsonValue* jmc = json_array_get(jmatches, j);
            MatchClause* mc = &t->matches[t->match_count++];
            memset(mc, 0, sizeof(MatchClause));
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
                mc->is_empty = (is_val && strcmp(is_val, "empty") == 0) ? 1 : 0;
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
                    if (strcmp(sel, "each") == 0) mc->select = SEL_EACH;
                    else if (strcmp(sel, "max_by") == 0) mc->select = SEL_MAX_BY;
                    else if (strcmp(sel, "min_by") == 0) mc->select = SEL_MIN_BY;
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
                if (sel && strcmp(sel, "each") == 0) mc->select = SEL_EACH;
                continue;
            }
        }

        /* Emit clauses */
        JsonValue* jemits = json_get(jt, "emit");
        t->emit_count = 0;
        for (int j = 0; j < json_array_len(jemits); j++) {
            JsonValue* jem = json_array_get(jemits, j);
            EmitClause* ec = &t->emits[t->emit_count++];
            memset(ec, 0, sizeof(EmitClause));
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

/* ============================================================
 * STATE OUTPUT (JSON)
 * ============================================================ */

void output_state(void) {
    printf("{\n");
    int first_entity = 1;
    for (int i = 0; i < g_graph.entity_count; i++) {
        Entity* e = &g_graph.entities[i];
        int loc = g_graph.entity_location[i];
        const char* loc_name = loc >= 0 ? str_of(g_graph.containers[loc].name_id) : "null";

        if (!first_entity) printf(",\n");
        first_entity = 0;

        printf("  \"%s\": {\"location\": \"%s\"", str_of(e->name_id), loc_name);

        for (int j = 0; j < e->prop_count; j++) {
            printf(", \"%s\": ", str_of(e->prop_keys[j]));
            PropVal v = e->prop_vals[j];
            if (v.type == PV_INT) printf("%lld", (long long)v.i);
            else if (v.type == PV_FLOAT) printf("%g", v.f);
            else if (v.type == PV_STRING) printf("\"%s\"", str_of(v.s));
            else printf("null");
        }

        printf("}");
    }
    printf("\n}\n");
}

/* ============================================================
 * MAIN
 * ============================================================ */

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: herb_runtime_v2 program.herb.json\n");
        return 1;
    }

    FILE* f = fopen(argv[1], "rb");
    if (!f) {
        fprintf(stderr, "Cannot open %s\n", argv[1]);
        return 1;
    }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    char* json_buf = malloc(len + 1);
    fread(json_buf, 1, len, f);
    json_buf[len] = '\0';
    fclose(f);

    JsonValue* root;
    const char* end = json_parse_value(json_buf, &root);
    if (!end || !root) {
        fprintf(stderr, "JSON parse error\n");
        return 1;
    }

    /* Reject composition specs — must be pre-composed */
    if (json_get(root, "compose")) {
        fprintf(stderr, "Error: composition specs must be pre-composed. "
                        "Use Python to compose first, then load the flat result.\n");
        return 1;
    }

    load_program(root);

    char line[256];
    while (fgets(line, sizeof(line), stdin)) {
        int ln = (int)strlen(line);
        while (ln > 0 && (line[ln-1] == '\n' || line[ln-1] == '\r')) line[--ln] = '\0';

        if (strcmp(line, "run") == 0) {
            run(MAX_STEPS);
        }
        else if (strcmp(line, "state") == 0) {
            output_state();
        }
        else if (strncmp(line, "create ", 7) == 0) {
            char name[64], type[64], container[64];
            if (sscanf(line + 7, "%63s %63s %63s", name, type, container) == 3) {
                int ci = graph_find_container_by_name(intern(container));
                if (ci >= 0) {
                    create_entity(intern(type), intern(name), ci);
                }
            }
        }
        else if (strlen(line) == 0) {
            continue;
        }
    }

    free(json_buf);
    return 0;
}
