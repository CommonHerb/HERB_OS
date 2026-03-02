/*
 * HERB Freestanding Support Layer
 *
 * Replaces ALL libc dependencies for the HERB runtime.
 * Zero external dependencies. Compiles with -ffreestanding -nostdlib.
 *
 * Provides:
 *   - Arena allocator (bump pointer, no free)
 *   - String/memory primitives
 *   - Number parsing (for JSON load)
 *   - Minimal string formatting (for name construction)
 *
 * Design:
 *   The arena allocator takes a single contiguous block of memory
 *   provided by the external environment (bootloader, firmware, test
 *   harness). All allocations come from this block. There is no free.
 *   HERB programs are loaded once and run forever — an OS doesn't
 *   deallocate its kernel.
 *
 *   After program loading completes, the arena watermark is recorded.
 *   The tension resolution loop (the hot path) performs ZERO allocations.
 *   Entity creation at runtime (signals) uses the arena but never frees.
 *   Arena exhaustion during load is a fatal error reported via the
 *   error callback. Arena exhaustion during runtime is impossible if
 *   the arena was sized correctly for the program's entity budget.
 */

#ifndef HERB_FREESTANDING_H
#define HERB_FREESTANDING_H

/* ============================================================
 * TYPES
 *
 * In freestanding mode, we define our own integer types.
 * In hosted mode (when libc headers are also included),
 * we use stdint.h to avoid conflicts.
 * ============================================================ */

#ifdef __STDC_HOSTED__
#if __STDC_HOSTED__ == 1
#include <stdint.h>
#define HERB_HOSTED 1
#endif
#endif

#ifndef HERB_HOSTED
/* Freestanding: define all types ourselves */
typedef unsigned char      uint8_t;
typedef signed char        int8_t;
typedef unsigned short     uint16_t;
typedef signed short       int16_t;
typedef unsigned int       uint32_t;
typedef signed int         int32_t;
typedef unsigned long long uint64_t;
typedef signed long long   int64_t;
typedef unsigned long long uintptr_t;
typedef long long          intptr_t;
#endif

/* size_t: our own type to avoid any conflicts */
typedef unsigned long long herb_size_t;

/* NULL */
#define HERB_NULL ((void*)0)

/* ============================================================
 * ARENA ALLOCATOR
 *
 * A single contiguous block. Bump-pointer allocation.
 * Alignment to 8 bytes (natural alignment for 64-bit values).
 * No free. No fragmentation. Deterministic.
 *
 * Usage:
 *   char memory[1024*1024];  // 1MB arena
 *   HerbArena arena;
 *   herb_arena_init(&arena, memory, sizeof(memory));
 *   void* p = herb_arena_alloc(&arena, 256);
 * ============================================================ */

typedef struct {
    uint8_t* base;      /* start of memory block */
    herb_size_t size;   /* total size of block */
    herb_size_t offset; /* current allocation offset (watermark) */
} HerbArena;

/* Initialize arena with externally-provided memory block */
void herb_arena_init(HerbArena* arena, void* memory, herb_size_t size);

/* Allocate 'size' bytes, 8-byte aligned. Returns HERB_NULL on exhaustion. */
void* herb_arena_alloc(HerbArena* arena, herb_size_t size);

/* Allocate and zero-fill (replaces calloc) */
void* herb_arena_calloc(HerbArena* arena, herb_size_t count, herb_size_t elem_size);

/* Record current watermark (call after load_program completes) */
herb_size_t herb_arena_watermark(HerbArena* arena);

/* Report arena usage */
herb_size_t herb_arena_used(HerbArena* arena);
herb_size_t herb_arena_remaining(HerbArena* arena);

/* ============================================================
 * MEMORY PRIMITIVES
 * ============================================================ */

void  herb_memset(void* dst, int val, herb_size_t n);
void  herb_memcpy(void* dst, const void* src, herb_size_t n);
int   herb_memcmp(const void* a, const void* b, herb_size_t n);

/* ============================================================
 * STRING PRIMITIVES
 * ============================================================ */

herb_size_t herb_strlen(const char* s);
int         herb_strcmp(const char* a, const char* b);
int         herb_strncmp(const char* a, const char* b, herb_size_t n);
void        herb_strncpy(char* dst, const char* src, herb_size_t n);

/* Duplicate string into arena (replaces strdup) */
char* herb_strdup(HerbArena* arena, const char* s);

/* ============================================================
 * NUMBER PARSING (load-time only)
 * ============================================================ */

/* Parse decimal integer from string. Returns the value.
 * Handles negative numbers and leading zeros. */
int64_t herb_atoll(const char* s);

/* Parse floating-point from string. Returns the value.
 * Handles negative, decimal point, and e/E exponent notation. */
double herb_atof(const char* s);

/* ============================================================
 * STRING FORMATTING (minimal)
 *
 * Only supports the format specifiers actually used by the runtime:
 *   %s  — string
 *   %d  — int (signed decimal)
 *   %lld — int64_t (signed decimal)
 *   %g  — double (shortest representation)
 *   %%  — literal %
 *
 * Returns number of characters written (excluding null terminator).
 * Always null-terminates if size > 0.
 * ============================================================ */

int herb_snprintf(char* buf, herb_size_t size, const char* fmt, ...);

/* ============================================================
 * ERROR HANDLING
 *
 * The freestanding runtime cannot call exit() or write to stderr.
 * Instead, it reports errors through a callback function that the
 * external environment provides.
 *
 * Error severity:
 *   HERB_ERR_FATAL  — cannot continue (arena exhaustion, parse failure)
 *   HERB_ERR_WARN   — recoverable (pool full, etc.)
 * ============================================================ */

#define HERB_ERR_FATAL 0
#define HERB_ERR_WARN  1

typedef void (*HerbErrorFn)(int severity, const char* message);

/* Set the error callback. If NULL, errors are silently ignored. */
void herb_set_error_handler(HerbErrorFn fn);

/* Report an error through the callback */
void herb_error(int severity, const char* message);

/* ============================================================
 * VARIADIC ARGUMENT SUPPORT
 *
 * The C standard specifies that <stdarg.h> is available in
 * freestanding mode. It's a compiler builtin, not a library.
 * We use it for herb_snprintf.
 * ============================================================ */

/* GCC/Clang builtins for variadic arguments */
typedef __builtin_va_list herb_va_list;
#define herb_va_start(ap, last) __builtin_va_start(ap, last)
#define herb_va_end(ap)         __builtin_va_end(ap)
#define herb_va_arg(ap, type)   __builtin_va_arg(ap, type)

#endif /* HERB_FREESTANDING_H */
