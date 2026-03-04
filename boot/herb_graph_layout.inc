; boot/herb_graph_layout.inc — HERB Graph Struct Layout for Assembly
;
; Machine-verified offsets from offsetof() (Session 70, GCC 15.2.0, x86-64).
; Every future assembly file that touches graph data includes this file.
;
; DO NOT EDIT BY HAND. Regenerate with boot/verify_offsets.c if structs change.

; ============================================================
; CONSTANTS
; ============================================================

%define MAX_ENTITIES              1024
%define MAX_CONTAINERS            256
%define MAX_MOVE_TYPES            64
%define MAX_TENSIONS              256
%define MAX_STRINGS               2048
%define MAX_STRING_LEN            128
%define MAX_PROPERTIES            16
%define MAX_ENTITY_PER_CONTAINER  64
%define MAX_FROM_TO               16
%define MAX_SCOPE_TEMPLATES       16
%define MAX_CHANNELS              16
%define MAX_POOLS                 16
%define MAX_TRANSFERS             16

; ============================================================
; PropVal (16 bytes, 8-byte aligned)
; ============================================================

%define PV_TYPE      0      ; PropType enum (4 bytes)
%define PV_VALUE     8      ; union: int64/double/string_id (8 bytes)
%define SIZEOF_PV    16

; PropType enum values
%define PV_NONE_T    0
%define PV_INT_T     1
%define PV_FLOAT_T   2
%define PV_STRING_T  3

; ============================================================
; Entity (344 bytes, 8-byte aligned)
; ============================================================

%define ENT_ID          0       ; int (4 bytes)
%define ENT_TYPE_ID     4       ; int (4 bytes)
%define ENT_NAME_ID     8       ; int (4 bytes)
%define ENT_PROP_KEYS   12      ; int[16] (64 bytes)
%define ENT_PROP_VALS   80      ; PropVal[16] (256 bytes)
%define ENT_PROP_COUNT  336     ; int (4 bytes)
%define SIZEOF_ENTITY   344

; ============================================================
; Container (280 bytes, 4-byte aligned)
; ============================================================

%define CNT_ID              0       ; int (4 bytes)
%define CNT_NAME_ID         4       ; int (4 bytes)
%define CNT_KIND            8       ; ContainerKind enum (4 bytes)
%define CNT_ENTITY_TYPE     12      ; int (4 bytes)
%define CNT_ENTITIES        16      ; int[64] (256 bytes)
%define CNT_ENTITY_COUNT    272     ; int (4 bytes)
%define CNT_OWNER           276     ; int (4 bytes)
%define SIZEOF_CONTAINER    280

; ============================================================
; MoveType (284 bytes, 4-byte aligned)
; ============================================================

%define MT_NAME_ID              0       ; int
%define MT_FROM_CONTAINERS      4       ; int[16] (64 bytes)
%define MT_FROM_COUNT           68      ; int
%define MT_TO_CONTAINERS        72      ; int[16] (64 bytes)
%define MT_TO_COUNT             136     ; int
%define MT_ENTITY_TYPE          140     ; int
%define MT_IS_SCOPED            144     ; int
%define MT_SCOPED_FROM_NAMES    148     ; int[16] (64 bytes)
%define MT_SCOPED_FROM_COUNT    212     ; int
%define MT_SCOPED_TO_NAMES      216     ; int[16] (64 bytes)
%define MT_SCOPED_TO_COUNT      280     ; int
%define SIZEOF_MOVETYPE         284

; ============================================================
; Channel (20 bytes, 4-byte aligned)
; ============================================================

%define CH_NAME_ID      0       ; int
%define CH_SENDER       4       ; int
%define CH_RECEIVER     8       ; int
%define CH_ENTITY_TYPE  12      ; int
%define CH_BUFFER       16      ; int (buffer_container_idx)
%define SIZEOF_CHANNEL  20

; ============================================================
; Tension (1960 bytes, 8-byte aligned)
; ============================================================

%define TEN_NAME_ID             0       ; int
%define TEN_PRIORITY            4       ; int
%define TEN_ENABLED             8       ; int
%define TEN_OWNER               12      ; int
%define TEN_OWNER_RUN_CNT       16      ; int (owner_run_container)
%define TEN_MATCHES             24      ; MatchClause[8] (1088 bytes)
%define TEN_MATCH_COUNT         1112    ; int
%define TEN_EMITS               1120    ; EmitClause[8] (832 bytes)
%define TEN_EMIT_COUNT          1952    ; int
%define TEN_PAIR_MODE           1956    ; int
%define SIZEOF_TENSION          1960

; ============================================================
; MatchClause (136 bytes, 8-byte aligned)
; ============================================================

%define MC_KIND             0       ; MatchKind enum
%define MC_BIND_ID          4       ; int
%define MC_CONTAINER_IDX    8       ; int
%define MC_CONTAINERS       12      ; int[16] (64 bytes)
%define MC_CONTAINER_COUNT  76      ; int
%define MC_SELECT           80      ; SelectMode enum
%define MC_KEY_PROP_ID      84      ; int
%define MC_REQUIRED         88      ; int
%define MC_IS_EMPTY         92      ; int
%define MC_GUARD_CNT_IDX    96      ; int
%define MC_WHERE_EXPR       104     ; Expr* (8 bytes)
%define MC_GUARD_EXPR       112     ; Expr* (8 bytes)
%define MC_SCOPE_BIND_ID    120     ; int
%define MC_SCOPE_CNAME_ID   124     ; int
%define MC_CHANNEL_IDX      128     ; int
%define SIZEOF_MATCHCLAUSE  136

; ============================================================
; EmitClause (104 bytes, 8-byte aligned)
; ============================================================

%define EC_KIND                 0       ; EmitKind enum
%define EC_VALUE_EXPR           32      ; Expr*
%define EC_TRANSFER_AMOUNT_EXPR 80      ; Expr*
; EmitClause field offsets (full struct)
%define EC_MOVE_TYPE_IDX         4
%define EC_ENTITY_REF            8
%define EC_TO_REF                12
%define EC_TO_SCOPE_BIND_ID      16
%define EC_TO_SCOPE_CNAME_ID     20
%define EC_SET_ENTITY_REF        24
%define EC_SET_PROP_ID           28
; EC_VALUE_EXPR at 32 (already defined above)
%define EC_SEND_CHANNEL_IDX      40
%define EC_SEND_ENTITY_REF       44
%define EC_RECV_CHANNEL_IDX      48
%define EC_RECV_ENTITY_REF       52
%define EC_RECV_TO_REF           56
%define EC_RECV_TO_SCOPE_BIND_ID 60
%define EC_RECV_TO_SCOPE_CNAME_ID 64
%define EC_TRANSFER_TYPE_IDX     68
%define EC_TRANSFER_FROM_REF     72
%define EC_TRANSFER_TO_REF       76
; EC_TRANSFER_AMOUNT_EXPR at 80 (already defined above)
%define EC_DUP_ENTITY_REF        88
%define EC_DUP_IN_REF            92
%define EC_DUP_IN_SCOPE_BIND_ID  96
%define EC_DUP_IN_SCOPE_CNAME_ID 100
%define SIZEOF_EMITCLAUSE       104

; ============================================================
; ScopeTemplate (12 bytes, 4-byte aligned)
; ============================================================

%define ST_NAME_ID      0       ; int
%define ST_KIND         4       ; ContainerKind enum
%define ST_ENTITY_TYPE  8       ; int
%define SIZEOF_SCOPETEMPLATE 12

; ============================================================
; Pool (8 bytes, 4-byte aligned)
; ============================================================

%define POOL_NAME_ID        0       ; int
%define POOL_PROPERTY_ID    4       ; int
%define SIZEOF_POOL         8

; ============================================================
; TransferType (12 bytes, 4-byte aligned)
; ============================================================

%define TT_NAME_ID          0       ; int
%define TT_POOL_IDX         4       ; int
%define TT_ENTITY_TYPE      8       ; int
%define SIZEOF_TRANSFERTYPE 12

; ============================================================
; Graph (720568 bytes, 8-byte aligned)
; ============================================================

%define GRAPH_ENTITIES              0           ; Entity[1024]
%define GRAPH_ENTITY_COUNT          352256      ; int
%define GRAPH_CONTAINERS            352260      ; Container[256]
%define GRAPH_CONTAINER_COUNT       423940      ; int
%define GRAPH_MOVE_TYPES            423944      ; MoveType[64]
%define GRAPH_MOVE_TYPE_COUNT       442120      ; int
%define GRAPH_TENSIONS              442128      ; DEPRECATED — use g_tensions BSS array (Session 74)
%define GRAPH_TENSION_COUNT         567568      ; DEPRECATED — use g_tension_count BSS global (Session 74)
%define GRAPH_ENTITY_LOCATION       567572      ; int[1024]
%define GRAPH_TYPE_NAMES            571668      ; int[64]
%define GRAPH_TYPE_COUNT            571924      ; int
%define GRAPH_TYPE_SCOPE_TYPE_IDS   571928      ; int[64]
%define GRAPH_TYPE_SCOPE_TEMPLATES  572184      ; ScopeTemplate[64][16]
%define GRAPH_TYPE_SCOPE_COUNTS     584472      ; int[64]
%define GRAPH_TYPE_SCOPE_COUNT      584728      ; int
%define GRAPH_ENTITY_SCOPE_NAMES    584732      ; int[1024][16]
%define GRAPH_ENTITY_SCOPE_CIDS     650268      ; int[1024][16]
%define GRAPH_ENTITY_SCOPE_COUNT    715804      ; int[1024]
%define GRAPH_CHANNELS              719900      ; Channel[16]
%define GRAPH_CHANNEL_COUNT         720220      ; int
%define GRAPH_POOLS                 720224      ; Pool[16]
%define GRAPH_POOL_COUNT            720352      ; int
%define GRAPH_TRANSFER_TYPES        720356      ; TransferType[16]
%define GRAPH_TRANSFER_TYPE_COUNT   720548      ; int
%define GRAPH_MAX_NESTING_DEPTH     720552      ; int
%define GRAPH_DUP_COUNTER           720556      ; int
%define GRAPH_OP_COUNT              720560      ; int
%define SIZEOF_GRAPH                720568

; ============================================================
; Expr (32 bytes, 8-byte aligned)
; ============================================================

%define EX_KIND          0       ; ExprKind enum (4 bytes) + 4 pad
%define EX_VALUE         8       ; union start (24 bytes)
%define EX_INT_VAL       8       ; int_val (int64_t at union+0)
%define EX_PROP_ID       8       ; prop.prop_id (int at union+0)
%define EX_OF_ID         12      ; prop.of_id (int at union+4)
%define EX_BINARY_OP_ID  8       ; binary.op_id (int at union+0)
%define EX_BINARY_LEFT   16      ; binary.left (Expr* at union+8)
%define EX_BINARY_RIGHT  24      ; binary.right (Expr* at union+16)
%define SIZEOF_EXPR      32

; Expr union offsets — count variant
%define EX_COUNT_CIDX       8       ; count.container_idx (int at union+0)
%define EX_COUNT_SCOPED     12      ; count.is_scoped (int at union+4)
%define EX_COUNT_SBIND      16      ; count.scope_bind_id (int at union+8)
%define EX_COUNT_SCNAME     20      ; count.scope_cname_id (int at union+12)
%define EX_COUNT_ISCHAN     24      ; count.is_channel (int at union+16)
%define EX_COUNT_CHANIDX    28      ; count.channel_idx (int at union+20)

; Expr union offsets — unary variant
%define EX_UNARY_ARG        8       ; unary.arg (Expr* at union+0)

; Expr union offsets — in_of variant
%define EX_INOF_CIDX        8       ; in_of.container_idx (int at union+0)
%define EX_INOF_EREF        12      ; in_of.entity_ref_id (int at union+4)

; Expr union offsets — string/bool (alias for int_val position)
%define EX_STRING_ID        8       ; string_id (int at union+0)
%define EX_BOOL_VAL         8       ; bool_val (int at union+0)
%define EX_FLOAT_VAL        8       ; float_val (double at union+0)

; ExprKind enum values
%define EX_INT_T    0
%define EX_FLOAT_T  1
%define EX_STRING_T 2
%define EX_BOOL_T   3
%define EX_PROP_T   4
%define EX_COUNT_T  5
%define EX_BINARY_T 6
%define EX_UNARY_T  7
%define EX_INOF_T   8

; ============================================================
; BinReader (24 bytes, 8-byte aligned)
; ============================================================

%define BR_DATA     0       ; const uint8_t* (8 bytes)
%define BR_LEN      8       ; herb_size_t (8 bytes)
%define BR_POS      16      ; herb_size_t (8 bytes)
%define SIZEOF_BINREADER 24

; ============================================================
; Additional constants
; ============================================================

%define MAX_EXPR_POOL     4096
%define MAX_MATCH_CLAUSES 8
%define MAX_EMIT_CLAUSES  8
%define HAM_BYTECODE_SIZE 8192

; MatchKind enum values
%define MC_ENTITY_IN_V   0
%define MC_EMPTY_IN_V    1
%define MC_CONTAINER_IS_V 2
%define MC_GUARD_V       3

; SelectMode enum values (for MatchClause.select)
%define SEL_FIRST_V  0
%define SEL_EACH_V   1
%define SEL_MAX_BY_V 2
%define SEL_MIN_BY_V 3

; EmitKind enum values (full set)
%define EC_MOVE_V       0
%define EC_SET_V        1
%define EC_SEND_V       2
%define EC_RECEIVE_V    3
%define EC_TRANSFER_V   4
%define EC_DUPLICATE_V  5

; ContainerKind enum values
%define CK_SIMPLE_V  0
%define CK_SLOT_V    1

; ============================================================
; HamBindMap (36 bytes, 4-byte aligned) — Phase 4i
; ============================================================

%define HBM_IDS         0       ; int[4] (16 bytes)
%define HBM_REGS        16      ; int[4] (16 bytes)
%define HBM_COUNT       32      ; int (4 bytes)
%define SIZEOF_HBM      36
%define HAM_MAX_BINDS   4
