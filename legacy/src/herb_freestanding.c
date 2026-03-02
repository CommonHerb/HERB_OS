/*
 * HERB Freestanding Support Layer — Implementation
 *
 * Every function here is self-contained. No headers except our own.
 * Compiles with -ffreestanding -nostdlib.
 */

#include "herb_freestanding.h"

/* ============================================================
 * COMPILER-REQUIRED SYMBOLS
 *
 * GCC lowers struct assignments and aggregate copies to calls
 * to memcpy/memset/memmove even with -ffreestanding. These
 * symbols MUST be provided or linking fails. We implement them
 * using our herb_ versions.
 *
 * In hosted mode (test harness), libc already provides these,
 * so we skip them to avoid duplicate symbol errors.
 *
 * On Windows/MinGW, ___chkstk_ms is called for functions with
 * >4KB stack usage (stack probing). On bare metal, the stack is
 * pre-allocated so the probe is a no-op.
 * ============================================================ */

#ifndef HERB_HOSTED

void* memcpy(void* dst, const void* src, herb_size_t n) {
    herb_memcpy(dst, src, n);
    return dst;
}

void* memset(void* dst, int val, herb_size_t n) {
    herb_memset(dst, val, n);
    return dst;
}

void* memmove(void* dst, const void* src, herb_size_t n) {
    uint8_t* d = (uint8_t*)dst;
    const uint8_t* s = (const uint8_t*)src;
    if (d < s || d >= s + n) {
        /* No overlap or dst before src — forward copy */
        while (n--) *d++ = *s++;
    } else {
        /* Overlap with dst after src — backward copy */
        d += n;
        s += n;
        while (n--) *--d = *--s;
    }
    return dst;
}

#endif /* !HERB_HOSTED */

/* Stack probe — Windows/MinGW requires this for large stack frames.
 * On bare metal, the stack is pre-allocated and this is a no-op.
 * In hosted mode, the C runtime already provides this. */
#if !defined(HERB_HOSTED) && (defined(__x86_64__) || defined(_M_X64))
__attribute__((naked))
void ___chkstk_ms(void) {
    __asm__ volatile (
        "push   %%rcx\n\t"
        "push   %%rax\n\t"
        "cmp    $0x1000, %%rax\n\t"
        "lea    24(%%rsp), %%rcx\n\t"
        "jb     2f\n\t"
        "1:\n\t"
        "sub    $0x1000, %%rcx\n\t"
        "test   %%rcx, (%%rcx)\n\t"
        "sub    $0x1000, %%rax\n\t"
        "cmp    $0x1000, %%rax\n\t"
        "ja     1b\n\t"
        "2:\n\t"
        "sub    %%rax, %%rcx\n\t"
        "test   %%rcx, (%%rcx)\n\t"
        "pop    %%rax\n\t"
        "pop    %%rcx\n\t"
        "ret\n\t"
        ::: "memory"
    );
}
#elif !defined(HERB_HOSTED) && (defined(__i386__) || defined(_M_IX86))
__attribute__((naked))
void __chkstk_ms(void) {
    __asm__ volatile (
        "push   %%ecx\n\t"
        "push   %%eax\n\t"
        "cmp    $0x1000, %%eax\n\t"
        "lea    12(%%esp), %%ecx\n\t"
        "jb     2f\n\t"
        "1:\n\t"
        "sub    $0x1000, %%ecx\n\t"
        "test   %%ecx, (%%ecx)\n\t"
        "sub    $0x1000, %%eax\n\t"
        "cmp    $0x1000, %%eax\n\t"
        "ja     1b\n\t"
        "2:\n\t"
        "sub    %%eax, %%ecx\n\t"
        "test   %%ecx, (%%ecx)\n\t"
        "pop    %%eax\n\t"
        "pop    %%ecx\n\t"
        "ret\n\t"
        ::: "memory"
    );
}
#endif

/* ============================================================
 * ERROR HANDLING
 * ============================================================ */

static HerbErrorFn g_error_fn = HERB_NULL;

void herb_set_error_handler(HerbErrorFn fn) {
    g_error_fn = fn;
}

void herb_error(int severity, const char* message) {
    if (g_error_fn) {
        g_error_fn(severity, message);
    }
}

/* ============================================================
 * ARENA ALLOCATOR
 * ============================================================ */

void herb_arena_init(HerbArena* arena, void* memory, herb_size_t size) {
    arena->base = (uint8_t*)memory;
    arena->size = size;
    arena->offset = 0;
}

void* herb_arena_alloc(HerbArena* arena, herb_size_t size) {
    /* Align to 8 bytes */
    herb_size_t aligned = (arena->offset + 7) & ~(herb_size_t)7;
    if (aligned + size > arena->size) {
        herb_error(HERB_ERR_FATAL, "arena exhausted");
        return HERB_NULL;
    }
    void* ptr = arena->base + aligned;
    arena->offset = aligned + size;
    return ptr;
}

void* herb_arena_calloc(HerbArena* arena, herb_size_t count, herb_size_t elem_size) {
    herb_size_t total = count * elem_size;
    void* ptr = herb_arena_alloc(arena, total);
    if (ptr) {
        herb_memset(ptr, 0, total);
    }
    return ptr;
}

herb_size_t herb_arena_watermark(HerbArena* arena) {
    return arena->offset;
}

herb_size_t herb_arena_used(HerbArena* arena) {
    return arena->offset;
}

herb_size_t herb_arena_remaining(HerbArena* arena) {
    return arena->size - arena->offset;
}

/* ============================================================
 * MEMORY PRIMITIVES
 * ============================================================ */

void herb_memset(void* dst, int val, herb_size_t n) {
    uint8_t* d = (uint8_t*)dst;
    uint8_t v = (uint8_t)val;
    while (n--) *d++ = v;
}

void herb_memcpy(void* dst, const void* src, herb_size_t n) {
    uint8_t* d = (uint8_t*)dst;
    const uint8_t* s = (const uint8_t*)src;
    while (n--) *d++ = *s++;
}

int herb_memcmp(const void* a, const void* b, herb_size_t n) {
    const uint8_t* pa = (const uint8_t*)a;
    const uint8_t* pb = (const uint8_t*)b;
    while (n--) {
        if (*pa != *pb) return (int)*pa - (int)*pb;
        pa++;
        pb++;
    }
    return 0;
}

/* ============================================================
 * STRING PRIMITIVES
 * ============================================================ */

herb_size_t herb_strlen(const char* s) {
    const char* p = s;
    while (*p) p++;
    return (herb_size_t)(p - s);
}

int herb_strcmp(const char* a, const char* b) {
    while (*a && *b && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

int herb_strncmp(const char* a, const char* b, herb_size_t n) {
    while (n && *a && *b && *a == *b) { a++; b++; n--; }
    if (n == 0) return 0;
    return (unsigned char)*a - (unsigned char)*b;
}

void herb_strncpy(char* dst, const char* src, herb_size_t n) {
    herb_size_t i;
    for (i = 0; i < n && src[i]; i++) {
        dst[i] = src[i];
    }
    for (; i < n; i++) {
        dst[i] = '\0';
    }
}

char* herb_strdup(HerbArena* arena, const char* s) {
    herb_size_t len = herb_strlen(s) + 1;
    char* dup = (char*)herb_arena_alloc(arena, len);
    if (dup) {
        herb_memcpy(dup, s, len);
    }
    return dup;
}

/* ============================================================
 * NUMBER PARSING
 * ============================================================ */

int64_t herb_atoll(const char* s) {
    int64_t result = 0;
    int negative = 0;

    /* Skip whitespace */
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;

    if (*s == '-') { negative = 1; s++; }
    else if (*s == '+') { s++; }

    while (*s >= '0' && *s <= '9') {
        result = result * 10 + (*s - '0');
        s++;
    }

    return negative ? -result : result;
}

double herb_atof(const char* s) {
    double result = 0.0;
    int negative = 0;

    /* Skip whitespace */
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;

    if (*s == '-') { negative = 1; s++; }
    else if (*s == '+') { s++; }

    /* Integer part */
    while (*s >= '0' && *s <= '9') {
        result = result * 10.0 + (*s - '0');
        s++;
    }

    /* Fractional part */
    if (*s == '.') {
        s++;
        double place = 0.1;
        while (*s >= '0' && *s <= '9') {
            result += (*s - '0') * place;
            place *= 0.1;
            s++;
        }
    }

    /* Exponent */
    if (*s == 'e' || *s == 'E') {
        s++;
        int exp_neg = 0;
        int exp_val = 0;
        if (*s == '-') { exp_neg = 1; s++; }
        else if (*s == '+') { s++; }
        while (*s >= '0' && *s <= '9') {
            exp_val = exp_val * 10 + (*s - '0');
            s++;
        }
        double multiplier = 1.0;
        for (int i = 0; i < exp_val; i++) {
            multiplier *= 10.0;
        }
        if (exp_neg) result /= multiplier;
        else result *= multiplier;
    }

    return negative ? -result : result;
}

/* ============================================================
 * STRING FORMATTING (minimal herb_snprintf)
 *
 * Supports: %s, %d, %lld, %g, %%, and literal characters.
 * This is NOT a full printf implementation — only what the
 * HERB runtime actually uses.
 * ============================================================ */

/* Internal: write a character to buffer with bounds checking */
static int fmt_putc(char* buf, herb_size_t size, herb_size_t pos, char c) {
    if (pos < size - 1) {
        buf[pos] = c;
    }
    return 1;
}

/* Internal: write a string to buffer */
static int fmt_puts(char* buf, herb_size_t size, herb_size_t pos, const char* s) {
    int written = 0;
    while (*s) {
        if (pos + written < size - 1) {
            buf[pos + written] = *s;
        }
        written++;
        s++;
    }
    return written;
}

/* Internal: write a signed 64-bit integer */
static int fmt_int64(char* buf, herb_size_t size, herb_size_t pos, int64_t val) {
    char tmp[24]; /* enough for -9223372036854775808 */
    int len = 0;
    int negative = 0;

    if (val < 0) {
        negative = 1;
        /* Handle INT64_MIN carefully */
        if (val == (int64_t)((uint64_t)1 << 63)) {
            /* -9223372036854775808 */
            const char* min_str = "-9223372036854775808";
            return fmt_puts(buf, size, pos, min_str);
        }
        val = -val;
    }

    if (val == 0) {
        tmp[len++] = '0';
    } else {
        while (val > 0) {
            tmp[len++] = '0' + (int)(val % 10);
            val /= 10;
        }
    }

    int written = 0;
    if (negative) {
        written += fmt_putc(buf, size, pos + written, '-');
    }
    for (int i = len - 1; i >= 0; i--) {
        written += fmt_putc(buf, size, pos + written, tmp[i]);
    }
    return written;
}

/* Internal: write a double in shortest representation (%g style) */
static int fmt_double(char* buf, herb_size_t size, herb_size_t pos, double val) {
    int written = 0;

    /* Handle negative */
    if (val < 0) {
        written += fmt_putc(buf, size, pos + written, '-');
        val = -val;
    }

    /* Handle zero */
    if (val == 0.0) {
        written += fmt_putc(buf, size, pos + written, '0');
        return written;
    }

    /* Extract integer and fractional parts */
    int64_t int_part = (int64_t)val;
    double frac_part = val - (double)int_part;

    /* Write integer part */
    written += fmt_int64(buf, size, pos + written, int_part);

    /* Write fractional part (up to 6 digits, strip trailing zeros) */
    if (frac_part > 0.0000005) {
        char frac_buf[8];
        int frac_len = 0;
        double f = frac_part;
        for (int i = 0; i < 6; i++) {
            f *= 10.0;
            int digit = (int)f;
            if (digit > 9) digit = 9;
            frac_buf[frac_len++] = '0' + digit;
            f -= digit;
        }
        /* Strip trailing zeros */
        while (frac_len > 0 && frac_buf[frac_len - 1] == '0') frac_len--;
        if (frac_len > 0) {
            written += fmt_putc(buf, size, pos + written, '.');
            for (int i = 0; i < frac_len; i++) {
                written += fmt_putc(buf, size, pos + written, frac_buf[i]);
            }
        }
    }

    return written;
}

int herb_snprintf(char* buf, herb_size_t size, const char* fmt, ...) {
    herb_va_list ap;
    herb_va_start(ap, fmt);

    herb_size_t pos = 0;
    int total = 0;

    while (*fmt) {
        if (*fmt == '%') {
            fmt++;
            if (*fmt == '%') {
                total += fmt_putc(buf, size, pos + total, '%');
                fmt++;
            }
            else if (*fmt == 's') {
                const char* s = herb_va_arg(ap, const char*);
                if (!s) s = "(null)";
                total += fmt_puts(buf, size, pos + total, s);
                fmt++;
            }
            else if (*fmt == 'd') {
                int v = herb_va_arg(ap, int);
                total += fmt_int64(buf, size, pos + total, (int64_t)v);
                fmt++;
            }
            else if (*fmt == 'l' && *(fmt+1) == 'l' && *(fmt+2) == 'd') {
                int64_t v = herb_va_arg(ap, int64_t);
                total += fmt_int64(buf, size, pos + total, v);
                fmt += 3;
            }
            else if (*fmt == 'g') {
                double v = herb_va_arg(ap, double);
                total += fmt_double(buf, size, pos + total, v);
                fmt++;
            }
            else {
                /* Unknown format specifier — write literally */
                total += fmt_putc(buf, size, pos + total, '%');
                total += fmt_putc(buf, size, pos + total, *fmt);
                fmt++;
            }
        } else {
            total += fmt_putc(buf, size, pos + total, *fmt);
            fmt++;
        }
    }

    /* Null-terminate */
    if (size > 0) {
        herb_size_t term_pos = (herb_size_t)total < size - 1 ? (herb_size_t)total : size - 1;
        buf[term_pos] = '\0';
    }

    herb_va_end(ap);
    return total;
}
