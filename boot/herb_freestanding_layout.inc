; boot/herb_freestanding_layout.inc — HerbArena Struct Layout for Assembly
;
; Phase 4c (Session 74): Freestanding support layer ported to x86-64.
;
; HerbArena layout from src/herb_freestanding.h:
;   typedef struct {
;       uint8_t*    base;    /* 8 bytes */
;       herb_size_t size;    /* 8 bytes */
;       herb_size_t offset;  /* 8 bytes */
;   } HerbArena;

; ============================================================
; HerbArena (24 bytes, 8-byte aligned)
; ============================================================

%define ARENA_BASE      0       ; uint8_t* (8 bytes)
%define ARENA_SIZE      8       ; herb_size_t (8 bytes)
%define ARENA_OFFSET    16      ; herb_size_t (8 bytes)
%define SIZEOF_ARENA    24

; ============================================================
; Error severity constants (from herb_freestanding.h)
; ============================================================

%define HERB_ERR_FATAL  0
%define HERB_ERR_WARN   1
