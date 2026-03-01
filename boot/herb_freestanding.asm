; boot/herb_freestanding.asm — HERB Freestanding Support Layer in Assembly
;
; Phase 4c: Complete port of src/herb_freestanding.c to x86-64.
; Eliminates the C file from the bare-metal build entirely.
;
; Functions ported (23 total):
;   Tier 1 — Memory:    herb_memset, herb_memcpy, herb_memcmp, memcpy, memset, memmove
;   Tier 2 — Strings:   herb_strlen, herb_strcmp, herb_strncmp, herb_strncpy
;   Tier 3 — Error:     herb_set_error_handler, herb_error
;   Tier 4 — Arena:     herb_arena_init, herb_arena_alloc, herb_arena_calloc,
;                        herb_arena_watermark, herb_arena_used, herb_arena_remaining
;   Tier 5 — Infra:     ___chkstk_ms
;   Tier 6 — Formatting: herb_snprintf (+ internal fmt_putc, fmt_puts, fmt_int64, fmt_double)
;   Tier 7 — Parsing:   herb_atoll, herb_atof, herb_strdup
;
; Register convention: MS x64 ABI
;   Args:    RCX, RDX, R8, R9 (integer/pointer), XMM0-XMM3 (float)
;   Return:  RAX (integer/pointer), XMM0 (float)
;   Caller-saved: RAX, RCX, RDX, R8-R11, XMM0-XMM5
;   Callee-saved: RBX, RSI, RDI, R12-R15, RBP
;   Shadow space: 32 bytes before each CALL
;   Stack: 16-byte aligned at CALL instruction
;
; Assembled with: nasm -f win64 herb_freestanding.asm -o herb_freestanding.o

[bits 64]
default rel

%include "herb_freestanding_layout.inc"

; ============================================================
; Exports
; ============================================================

; Tier 1 — Memory primitives
global herb_memset
global herb_memcpy
global herb_memcmp
global memcpy
global memset
global memmove

; Tier 2 — String primitives
global herb_strlen
global herb_strcmp
global herb_strncmp
global herb_strncpy

; Tier 3 — Error handling
global herb_set_error_handler
global herb_error

; Tier 4 — Arena allocator
global herb_arena_init
global herb_arena_alloc
global herb_arena_calloc
global herb_arena_watermark
global herb_arena_used
global herb_arena_remaining

; Tier 5 — Stack probe
global ___chkstk_ms

; Tier 6 — String formatting
global herb_snprintf

; Tier 7 — Number parsing + strdup
global herb_atoll
global herb_atof
global herb_strdup

; ============================================================
; Read-only data
; ============================================================

section .rdata
    str_arena_exhausted: db "arena exhausted", 0
    str_int64_min:       db "-9223372036854775808", 0
    str_snprintf_null:   db "(null)", 0

    ; Constants for floating-point operations
    align 8
    const_10_0:    dq 10.0
    const_0_1:     dq 0.1
    const_frac_eps: dq 0.0000005    ; threshold for fractional part

; ============================================================
; BSS data
; ============================================================

section .bss
    g_error_fn: resq 1     ; HerbErrorFn — function pointer (or NULL)

; ============================================================
; TEXT — all functions
; ============================================================

section .text

; ============================================================
; TIER 1 — MEMORY PRIMITIVES
; ============================================================

; ------------------------------------------------------------
; herb_memset(void* dst [RCX], int val [EDX], herb_size_t n [R8])
; Returns: void
; ------------------------------------------------------------
herb_memset:
    push    rdi             ; RDI is callee-saved in MS x64
    mov     rdi, rcx        ; dst
    movzx   eax, dl         ; val (byte) -> AL
    mov     rcx, r8         ; count
    rep stosb
    pop     rdi
    ret

; ------------------------------------------------------------
; herb_memcpy(void* dst [RCX], const void* src [RDX], herb_size_t n [R8])
; Returns: void
; ------------------------------------------------------------
herb_memcpy:
    push    rsi
    push    rdi
    mov     rdi, rcx        ; dst
    mov     rsi, rdx        ; src
    mov     rcx, r8         ; count
    rep movsb
    pop     rdi
    pop     rsi
    ret

; ------------------------------------------------------------
; herb_memcmp(const void* a [RCX], const void* b [RDX], herb_size_t n [R8])
; Returns: int (RAX)
; ------------------------------------------------------------
herb_memcmp:
    push    rsi
    push    rdi
    mov     rsi, rcx        ; a
    mov     rdi, rdx        ; b
    mov     rcx, r8         ; n
    test    rcx, rcx
    jz      .memcmp_equal
.memcmp_loop:
    lodsb                   ; al = [rsi++]
    mov     ah, [rdi]
    inc     rdi
    cmp     al, ah
    jne     .memcmp_diff
    dec     rcx
    jnz     .memcmp_loop
.memcmp_equal:
    xor     eax, eax
    pop     rdi
    pop     rsi
    ret
.memcmp_diff:
    movzx   eax, al
    movzx   ecx, ah
    sub     eax, ecx
    pop     rdi
    pop     rsi
    ret

; ------------------------------------------------------------
; memcpy(void* dst [RCX], const void* src [RDX], herb_size_t n [R8])
; Returns: void* dst (RAX) — GCC-required wrapper
; ------------------------------------------------------------
memcpy:
    push    rsi
    push    rdi
    mov     rax, rcx        ; save dst for return
    mov     rdi, rcx
    mov     rsi, rdx
    mov     rcx, r8
    rep movsb
    pop     rdi
    pop     rsi
    ret                     ; RAX = dst

; ------------------------------------------------------------
; memset(void* dst [RCX], int val [EDX], herb_size_t n [R8])
; Returns: void* dst (RAX) — GCC-required wrapper
; ------------------------------------------------------------
memset:
    push    rdi             ; RDI is callee-saved in MS x64
    mov     rdi, rcx        ; dst
    mov     rax, rcx        ; save dst for return
    movzx   ecx, dl         ; val (byte)
    mov     r9, rax         ; move saved dst to r9 (caller-saved, safe)
    mov     al, cl          ; value for rep stosb
    mov     rcx, r8         ; count
    rep stosb
    mov     rax, r9         ; return saved dst
    pop     rdi
    ret

; ------------------------------------------------------------
; memmove(void* dst [RCX], const void* src [RDX], herb_size_t n [R8])
; Returns: void* dst (RAX)
; Handles overlapping regions.
; ------------------------------------------------------------
memmove:
    push    rsi
    push    rdi
    mov     rax, rcx        ; save dst for return
    mov     rdi, rcx        ; dst
    mov     rsi, rdx        ; src
    mov     rcx, r8         ; n
    test    rcx, rcx
    jz      .memmove_done
    ; If dst < src or dst >= src+n, forward copy is safe
    cmp     rdi, rsi
    jb      .memmove_fwd
    ; dst >= src: check if dst >= src + n (no overlap)
    lea     rdx, [rsi + rcx]
    cmp     rdi, rdx
    jae     .memmove_fwd
    ; Overlap with dst after src — backward copy
    std                     ; set direction flag for backward
    lea     rsi, [rsi + rcx - 1]
    lea     rdi, [rdi + rcx - 1]
    rep movsb
    cld                     ; clear direction flag
    jmp     .memmove_done
.memmove_fwd:
    rep movsb
.memmove_done:
    pop     rdi
    pop     rsi
    ret

; ============================================================
; TIER 2 — STRING PRIMITIVES
; ============================================================

; ------------------------------------------------------------
; herb_strlen(const char* s [RCX])
; Returns: herb_size_t (RAX)
; ------------------------------------------------------------
herb_strlen:
    mov     rax, rcx        ; save start pointer
.strlen_loop:
    cmp     byte [rcx], 0
    je      .strlen_done
    inc     rcx
    jmp     .strlen_loop
.strlen_done:
    sub     rcx, rax        ; length = end - start
    mov     rax, rcx
    ret

; ------------------------------------------------------------
; herb_strcmp(const char* a [RCX], const char* b [RDX])
; Returns: int (RAX)
; ------------------------------------------------------------
herb_strcmp:
.strcmp_loop:
    movzx   eax, byte [rcx]
    movzx   r8d, byte [rdx]
    test    al, al
    jz      .strcmp_end
    cmp     al, r8b
    jne     .strcmp_end
    inc     rcx
    inc     rdx
    jmp     .strcmp_loop
.strcmp_end:
    sub     eax, r8d
    ret

; ------------------------------------------------------------
; herb_strncmp(const char* a [RCX], const char* b [RDX], herb_size_t n [R8])
; Returns: int (RAX)
; ------------------------------------------------------------
herb_strncmp:
    test    r8, r8
    jz      .strncmp_equal
.strncmp_loop:
    movzx   eax, byte [rcx]
    movzx   r9d, byte [rdx]
    test    al, al
    jz      .strncmp_end
    cmp     al, r9b
    jne     .strncmp_end
    inc     rcx
    inc     rdx
    dec     r8
    jnz     .strncmp_loop
.strncmp_equal:
    xor     eax, eax
    ret
.strncmp_end:
    sub     eax, r9d
    ret

; ------------------------------------------------------------
; herb_strncpy(char* dst [RCX], const char* src [RDX], herb_size_t n [R8])
; Returns: void
; Copies up to n bytes from src, zero-pads remainder.
; ------------------------------------------------------------
herb_strncpy:
    push    rdi
    mov     rdi, rcx        ; dst
    mov     rcx, r8         ; n
    test    rcx, rcx
    jz      .strncpy_done
    ; Copy bytes from src until null or n exhausted
.strncpy_copy:
    movzx   eax, byte [rdx]
    test    al, al
    jz      .strncpy_pad
    mov     [rdi], al
    inc     rdx
    inc     rdi
    dec     rcx
    jnz     .strncpy_copy
    jmp     .strncpy_done
    ; Zero-pad remaining bytes
.strncpy_pad:
    test    rcx, rcx
    jz      .strncpy_done
    mov     byte [rdi], 0
    inc     rdi
    dec     rcx
    jnz     .strncpy_pad
.strncpy_done:
    pop     rdi
    ret

; ============================================================
; TIER 3 — ERROR HANDLING
; ============================================================

; ------------------------------------------------------------
; herb_set_error_handler(HerbErrorFn fn [RCX])
; Returns: void
; ------------------------------------------------------------
herb_set_error_handler:
    lea     rax, [g_error_fn]
    mov     [rax], rcx
    ret

; ------------------------------------------------------------
; herb_error(int severity [ECX], const char* message [RDX])
; Returns: void
; Calls g_error_fn(severity, message) if non-null.
; ------------------------------------------------------------
herb_error:
    lea     rax, [g_error_fn]
    mov     rax, [rax]
    test    rax, rax
    jz      .error_noop
    ; g_error_fn is non-null — call it
    ; Args already in RCX, RDX
    sub     rsp, 40         ; 32 shadow + 8 alignment
    call    rax
    add     rsp, 40
.error_noop:
    ret

; ============================================================
; TIER 4 — ARENA ALLOCATOR
; ============================================================

; ------------------------------------------------------------
; herb_arena_init(HerbArena* arena [RCX], void* memory [RDX], herb_size_t size [R8])
; Returns: void
; ------------------------------------------------------------
herb_arena_init:
    mov     [rcx + ARENA_BASE], rdx
    mov     [rcx + ARENA_SIZE], r8
    mov     qword [rcx + ARENA_OFFSET], 0
    ret

; ------------------------------------------------------------
; herb_arena_alloc(HerbArena* arena [RCX], herb_size_t size [RDX])
; Returns: void* (RAX) or NULL on exhaustion
;
; Aligns offset to 8 bytes, checks bounds, bumps pointer.
; ------------------------------------------------------------
herb_arena_alloc:
    push    rbx
    push    r12
    sub     rsp, 40         ; 32 shadow + 8 (total push=16 + sub=40 = 56, need 16-aligned at call => 56+8 ret = 64, ok wait)
    ; Actually: push rbx(8) + push r12(8) = 16 on stack. Sub 40 => 56 on stack.
    ; At entry RSP was 16n+8 (return addr). After pushes: 16n+8-16 = 16n-8. After sub 40: 16n-48.
    ; 16n-48 mod 16 = -48 mod 16 = 0. At call: RSP = 16n-48, need RSP mod 16 = 0. YES, aligned.
    mov     rbx, rcx        ; arena
    mov     r12, rdx        ; size

    ; aligned = (arena->offset + 7) & ~7
    mov     rax, [rbx + ARENA_OFFSET]
    add     rax, 7
    and     rax, ~7         ; aligned

    ; Check: aligned + size > arena->size?
    lea     rcx, [rax + r12]
    cmp     rcx, [rbx + ARENA_SIZE]
    ja      .alloc_fail

    ; ptr = arena->base + aligned
    mov     rcx, [rbx + ARENA_BASE]
    add     rcx, rax        ; rcx = ptr

    ; arena->offset = aligned + size
    add     rax, r12
    mov     [rbx + ARENA_OFFSET], rax

    mov     rax, rcx        ; return ptr
    add     rsp, 40
    pop     r12
    pop     rbx
    ret

.alloc_fail:
    ; herb_error(HERB_ERR_FATAL, "arena exhausted")
    xor     ecx, ecx        ; HERB_ERR_FATAL = 0
    lea     rdx, [str_arena_exhausted]
    call    herb_error
    xor     eax, eax        ; return NULL
    add     rsp, 40
    pop     r12
    pop     rbx
    ret

; ------------------------------------------------------------
; herb_arena_calloc(HerbArena* arena [RCX], herb_size_t count [RDX], herb_size_t elem_size [R8])
; Returns: void* (RAX) or NULL
; ------------------------------------------------------------
herb_arena_calloc:
    push    rbx
    push    r12
    sub     rsp, 40

    mov     rbx, rcx        ; arena
    ; total = count * elem_size
    mov     rax, rdx
    imul    rax, r8
    mov     r12, rax        ; total

    ; herb_arena_alloc(arena, total)
    mov     rcx, rbx
    mov     rdx, r12
    call    herb_arena_alloc
    test    rax, rax
    jz      .calloc_done

    ; herb_memset(ptr, 0, total)
    push    rax             ; save ptr
    mov     rcx, rax        ; dst
    xor     edx, edx        ; val = 0
    mov     r8, r12         ; n = total
    call    herb_memset
    pop     rax             ; restore ptr

.calloc_done:
    add     rsp, 40
    pop     r12
    pop     rbx
    ret

; ------------------------------------------------------------
; herb_arena_watermark(HerbArena* arena [RCX])
; Returns: herb_size_t (RAX)
; ------------------------------------------------------------
herb_arena_watermark:
    mov     rax, [rcx + ARENA_OFFSET]
    ret

; ------------------------------------------------------------
; herb_arena_used(HerbArena* arena [RCX])
; Returns: herb_size_t (RAX)
; ------------------------------------------------------------
herb_arena_used:
    mov     rax, [rcx + ARENA_OFFSET]
    ret

; ------------------------------------------------------------
; herb_arena_remaining(HerbArena* arena [RCX])
; Returns: herb_size_t (RAX)
; ------------------------------------------------------------
herb_arena_remaining:
    mov     rax, [rcx + ARENA_SIZE]
    sub     rax, [rcx + ARENA_OFFSET]
    ret

; ============================================================
; TIER 5 — STACK PROBE (GCC-required)
; ============================================================

; ------------------------------------------------------------
; ___chkstk_ms
; Called by GCC for functions with >4KB stack usage.
; RAX = number of bytes to probe. Must probe each page.
; On bare metal, stack is pre-allocated, but we still probe
; to stay compatible with GCC-generated code.
; Preserves all registers except flags.
; ------------------------------------------------------------
___chkstk_ms:
    push    rcx
    push    rax
    cmp     rax, 0x1000
    lea     rcx, [rsp + 24]     ; point past return addr + 2 pushes
    jb      .chkstk_last
.chkstk_loop:
    sub     rcx, 0x1000
    test    [rcx], rcx          ; touch the page
    sub     rax, 0x1000
    cmp     rax, 0x1000
    ja      .chkstk_loop
.chkstk_last:
    sub     rcx, rax
    test    [rcx], rcx          ; touch final page
    pop     rax
    pop     rcx
    ret

; ============================================================
; TIER 6 — STRING FORMATTING (herb_snprintf)
;
; Internal helpers use a custom calling convention to avoid
; excessive push/pop. They're local labels, never exported.
;
; Common register convention for format helpers:
;   R12 = buf pointer
;   R13 = buf size
;   R14 = current position (pos + total)
;   Return: RAX = number of chars written (added to total)
; ============================================================

; ------------------------------------------------------------
; fmt_putc — write one char to buffer with bounds checking
; Input:  R12=buf, R13=size, R14=position, CL=char
; Output: RAX=1 (always writes 1 logical char)
; Clobbers: none significant
; ------------------------------------------------------------
fmt_putc:
    cmp     r14, r13
    jae     fmt_putc_skip      ; pos >= size-1 already checked below
    lea     rax, [r13 - 1]
    cmp     r14, rax
    jae     fmt_putc_skip
    mov     [r12 + r14], cl
fmt_putc_skip:
    mov     eax, 1
    ret

; ------------------------------------------------------------
; fmt_puts — write string to buffer
; Input:  R12=buf, R13=size, R14=base position, RSI=string pointer
; Output: RAX=number of chars written (logical, may exceed buf)
; Clobbers: RSI advanced past string
; ------------------------------------------------------------
fmt_puts:
    push    rbx
    xor     ebx, ebx            ; written = 0
fmt_puts_loop:
    cmp     byte [rsi], 0
    je      fmt_puts_done
    ; Check bounds: pos + written < size - 1
    lea     rax, [r14 + rbx]
    lea     rcx, [r13 - 1]
    cmp     rax, rcx
    jae     fmt_puts_nobuf
    add     rax, r12            ; rax = buf + pos + written
    movzx   ecx, byte [rsi]
    mov     [rax], cl
fmt_puts_nobuf:
    inc     ebx
    inc     rsi
    jmp     fmt_puts_loop
fmt_puts_done:
    mov     eax, ebx
    pop     rbx
    ret

; ------------------------------------------------------------
; fmt_int64 — write signed 64-bit integer to buffer
; Input:  R12=buf, R13=size, R14=position, RAX=value
; Output: RAX=number of chars written
; Clobbers: RCX, RDX, R8, R9, R10, R11
; Uses 24 bytes of stack for digit buffer
; ------------------------------------------------------------
fmt_int64:
    push    rbx
    push    rsi
    sub     rsp, 32             ; digit buffer (24 bytes used, aligned to 32)
    mov     r10, rax            ; value
    xor     r8d, r8d            ; negative = 0
    xor     r9d, r9d            ; digit count = 0

    ; Check negative
    test    r10, r10
    jns     .fi64_positive
    ; Check INT64_MIN
    mov     rax, 0x8000000000000000
    cmp     r10, rax
    jne     .fi64_negate
    ; INT64_MIN: use literal string
    lea     rsi, [str_int64_min]
    call    fmt_puts
    add     rsp, 32
    pop     rsi
    pop     rbx
    ret
.fi64_negate:
    neg     r10
    mov     r8d, 1              ; negative = 1
.fi64_positive:
    ; Convert digits (reverse order into stack buffer)
    test    r10, r10
    jnz     .fi64_digits
    ; Value is 0
    mov     byte [rsp + r9], '0'
    inc     r9d
    jmp     .fi64_write
.fi64_digits:
    mov     rax, r10
    xor     edx, edx
    mov     rcx, 10
    div     rcx                 ; rax = quotient, rdx = remainder
    add     dl, '0'
    mov     [rsp + r9], dl
    inc     r9d
    mov     r10, rax
    test    rax, rax
    jnz     .fi64_digits
.fi64_write:
    ; Write sign + digits to buffer
    xor     ebx, ebx            ; written = 0
    ; Write '-' if negative
    test    r8d, r8d
    jz      .fi64_write_digits
    mov     cl, '-'
    push    r14
    add     r14, rbx
    call    fmt_putc
    pop     r14
    add     ebx, eax
.fi64_write_digits:
    ; Write digits in reverse (r9d-1 downto 0)
    mov     r11d, r9d
    dec     r11d
.fi64_digit_loop:
    test    r11d, r11d
    js      .fi64_done
    movzx   ecx, byte [rsp + r11]
    push    r14
    lea     r14, [r14 + rbx]
    call    fmt_putc
    pop     r14
    add     ebx, eax
    dec     r11d
    jmp     .fi64_digit_loop
.fi64_done:
    mov     eax, ebx
    add     rsp, 32
    pop     rsi
    pop     rbx
    ret

; ------------------------------------------------------------
; fmt_double — write double in %g style
; Input:  R12=buf, R13=size, R14=position, XMM0=value
; Output: RAX=number of chars written
; Clobbers: RCX, RDX, R8, R9, R10, R11, XMM0-XMM5
; Uses stack for temp storage
; ------------------------------------------------------------
fmt_double:
    push    rbx
    push    rsi
    sub     rsp, 48             ; space for frac digits + alignment
    xor     ebx, ebx            ; written = 0

    ; Check negative
    xorpd   xmm1, xmm1         ; xmm1 = 0.0
    ucomisd xmm0, xmm1
    jae     .fd_not_neg
    ; Negative — write '-' and negate
    mov     cl, '-'
    push    r14
    add     r14, rbx
    call    fmt_putc
    pop     r14
    add     ebx, eax
    ; Negate: xmm0 = -xmm0
    xorpd   xmm1, xmm1
    subsd   xmm1, xmm0
    movsd   xmm0, xmm1
.fd_not_neg:
    ; Check zero
    xorpd   xmm1, xmm1
    ucomisd xmm0, xmm1
    jne     .fd_nonzero
    jp      .fd_nonzero         ; NaN is not zero
    ; Write '0'
    mov     cl, '0'
    push    r14
    lea     r14, [r14 + rbx]
    call    fmt_putc
    pop     r14
    add     ebx, eax
    mov     eax, ebx
    add     rsp, 48
    pop     rsi
    pop     rbx
    ret

.fd_nonzero:
    ; Extract integer part: int_part = (int64_t)val
    cvttsd2si rax, xmm0        ; rax = int_part
    mov     r10, rax            ; save int_part

    ; frac_part = val - (double)int_part
    cvtsi2sd xmm1, rax
    subsd   xmm0, xmm1         ; xmm0 = frac_part
    movsd   [rsp + 32], xmm0   ; save frac_part to stack

    ; Write integer part using fmt_int64
    mov     rax, r10
    push    r14
    lea     r14, [r14 + rbx]
    call    fmt_int64
    pop     r14
    add     ebx, eax

    ; Check if frac_part > 0.0000005
    movsd   xmm0, [rsp + 32]   ; reload frac_part
    movsd   xmm1, [const_frac_eps]
    ucomisd xmm0, xmm1
    jbe     .fd_no_frac

    ; Generate up to 6 fractional digits
    xor     r9d, r9d            ; frac_len = 0
    mov     r8d, 6              ; max 6 digits
    movsd   xmm2, [const_10_0] ; xmm2 = 10.0
.fd_frac_loop:
    mulsd   xmm0, xmm2         ; f *= 10.0
    cvttsd2si eax, xmm0        ; digit = (int)f
    cmp     eax, 9
    jle     .fd_digit_ok
    mov     eax, 9
.fd_digit_ok:
    add     al, '0'
    mov     [rsp + r9], al      ; frac_buf[frac_len] = digit
    inc     r9d
    ; f -= digit
    sub     al, '0'
    movzx   eax, al
    cvtsi2sd xmm1, eax
    subsd   xmm0, xmm1
    dec     r8d
    jnz     .fd_frac_loop

    ; Strip trailing zeros
.fd_strip:
    test    r9d, r9d
    jz      .fd_no_frac
    movzx   eax, byte [rsp + r9 - 1]
    cmp     al, '0'
    jne     .fd_write_frac
    dec     r9d
    jmp     .fd_strip

.fd_write_frac:
    ; Write '.'
    mov     cl, '.'
    push    r14
    lea     r14, [r14 + rbx]
    call    fmt_putc
    pop     r14
    add     ebx, eax

    ; Write fractional digits
    xor     r8d, r8d            ; i = 0
.fd_frac_write:
    cmp     r8d, r9d
    jge     .fd_no_frac
    movzx   ecx, byte [rsp + r8]
    push    r14
    lea     r14, [r14 + rbx]
    call    fmt_putc
    pop     r14
    add     ebx, eax
    inc     r8d
    jmp     .fd_frac_write

.fd_no_frac:
    mov     eax, ebx
    add     rsp, 48
    pop     rsi
    pop     rbx
    ret

; ------------------------------------------------------------
; herb_snprintf(char* buf [RCX], herb_size_t size [RDX],
;               const char* fmt [R8], ...)
; Returns: int total (RAX) — chars written (excl null terminator)
;
; MS x64 variadic: first 4 args in RCX,RDX,R8,R9 AND in shadow
; space. va_args start at shadow[3] (RSP+8+24 at entry = RSP+32).
; But R9 is arg4 (first variadic), then stack at RSP+40, RSP+48...
;
; On entry, the caller has already placed args in shadow space.
; We spill R9 to shadow[3] too since compiler may not for variadics.
; ------------------------------------------------------------
herb_snprintf:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8              ; align to 16 (7 pushes = 56, + sub 8 = 64)

    ; Save core parameters
    mov     r12, rcx            ; buf
    mov     r13, rdx            ; size
    mov     r15, r8             ; fmt pointer

    ; Set up va_list pointer
    ; At entry: [RBP+8]=ret, [RBP+16]=shadow0(RCX), [RBP+24]=shadow1(RDX),
    ;           [RBP+32]=shadow2(R8), [RBP+40]=shadow3(R9),
    ;           [RBP+48]=arg5, [RBP+56]=arg6, ...
    ; First variadic arg is arg4 = R9. Spill it to shadow space.
    mov     [rbp + 40], r9
    lea     rdi, [rbp + 40]     ; va_ptr = &shadow[3] (first variadic arg)

    xor     r14d, r14d          ; total = 0

.snprintf_loop:
    movzx   eax, byte [r15]
    test    al, al
    jz      .snprintf_done

    cmp     al, '%'
    je      .snprintf_format

    ; Literal character
    mov     cl, al
    push    r14                 ; save base position
    call    fmt_putc
    pop     r14
    add     r14d, eax
    inc     r15
    jmp     .snprintf_loop

.snprintf_format:
    inc     r15                 ; skip '%'
    movzx   eax, byte [r15]

    ; %%
    cmp     al, '%'
    je      .snf_percent

    ; %s
    cmp     al, 's'
    je      .snf_string

    ; %d
    cmp     al, 'd'
    je      .snf_int

    ; %lld
    cmp     al, 'l'
    je      .snf_check_lld

    ; %g
    cmp     al, 'g'
    je      .snf_double

    ; Unknown — write % and the char literally
    mov     cl, '%'
    push    r14
    call    fmt_putc
    pop     r14
    add     r14d, eax
    movzx   ecx, byte [r15]
    push    r14
    call    fmt_putc
    pop     r14
    add     r14d, eax
    inc     r15
    jmp     .snprintf_loop

.snf_percent:
    mov     cl, '%'
    push    r14
    call    fmt_putc
    pop     r14
    add     r14d, eax
    inc     r15
    jmp     .snprintf_loop

.snf_string:
    ; va_arg: const char*
    mov     rsi, [rdi]
    add     rdi, 8
    ; Check for NULL
    test    rsi, rsi
    jnz     .snf_str_ok
    lea     rsi, [str_snprintf_null]
    jmp     .snf_str_ok
.snf_str_ok:
    push    r14
    call    fmt_puts
    pop     r14
    add     r14d, eax
    inc     r15
    jmp     .snprintf_loop

.snf_int:
    ; va_arg: int (promoted to 64-bit on stack, but only low 32 bits valid)
    movsxd  rax, dword [rdi]
    add     rdi, 8
    push    r14
    call    fmt_int64
    pop     r14
    add     r14d, eax
    inc     r15
    jmp     .snprintf_loop

.snf_check_lld:
    ; Check for "lld"
    cmp     byte [r15 + 1], 'l'
    jne     .snf_unknown_l
    cmp     byte [r15 + 2], 'd'
    jne     .snf_unknown_l
    ; va_arg: int64_t
    mov     rax, [rdi]
    add     rdi, 8
    push    r14
    call    fmt_int64
    pop     r14
    add     r14d, eax
    add     r15, 3
    jmp     .snprintf_loop
.snf_unknown_l:
    ; Write %l literally
    mov     cl, '%'
    push    r14
    call    fmt_putc
    pop     r14
    add     r14d, eax
    movzx   ecx, byte [r15]
    push    r14
    call    fmt_putc
    pop     r14
    add     r14d, eax
    inc     r15
    jmp     .snprintf_loop

.snf_double:
    ; va_arg: double (8 bytes on stack)
    movsd   xmm0, [rdi]
    add     rdi, 8
    push    r14
    call    fmt_double
    pop     r14
    add     r14d, eax
    inc     r15
    jmp     .snprintf_loop

.snprintf_done:
    ; Null-terminate
    test    r13, r13
    jz      .snprintf_ret
    ; term_pos = min(total, size-1)
    mov     rax, r14
    lea     rcx, [r13 - 1]
    cmp     rax, rcx
    jbe     .snf_term
    mov     rax, rcx
.snf_term:
    mov     byte [r12 + rax], 0

.snprintf_ret:
    mov     eax, r14d           ; return total
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

; ============================================================
; TIER 7 — NUMBER PARSING + STRDUP
; ============================================================

; ------------------------------------------------------------
; herb_atoll(const char* s [RCX])
; Returns: int64_t (RAX)
; ------------------------------------------------------------
herb_atoll:
    push    rbx
    xor     eax, eax            ; result = 0
    xor     r8d, r8d            ; negative = 0

    ; Skip whitespace
.atoll_ws:
    movzx   edx, byte [rcx]
    cmp     dl, ' '
    je      .atoll_ws_next
    cmp     dl, 9               ; '\t'
    je      .atoll_ws_next
    cmp     dl, 10              ; '\n'
    je      .atoll_ws_next
    cmp     dl, 13              ; '\r'
    je      .atoll_ws_next
    jmp     .atoll_sign
.atoll_ws_next:
    inc     rcx
    jmp     .atoll_ws

.atoll_sign:
    cmp     dl, '-'
    jne     .atoll_plus
    mov     r8d, 1
    inc     rcx
    jmp     .atoll_digits
.atoll_plus:
    cmp     dl, '+'
    jne     .atoll_digits
    inc     rcx

.atoll_digits:
    movzx   edx, byte [rcx]
    sub     dl, '0'
    cmp     dl, 9
    ja      .atoll_done
    ; result = result * 10 + digit
    mov     rbx, 10
    imul    rax, rbx
    movzx   edx, dl
    add     rax, rdx
    inc     rcx
    jmp     .atoll_digits

.atoll_done:
    test    r8d, r8d
    jz      .atoll_ret
    neg     rax
.atoll_ret:
    pop     rbx
    ret

; ------------------------------------------------------------
; herb_atof(const char* s [RCX])
; Returns: double (XMM0)
; Uses SSE2 for all floating-point work.
; ------------------------------------------------------------
herb_atof:
    push    rbx
    push    rsi
    sub     rsp, 8              ; align

    mov     rsi, rcx            ; s pointer
    xor     r8d, r8d            ; negative = 0
    xorpd   xmm0, xmm0         ; result = 0.0

    ; Skip whitespace
.atof_ws:
    movzx   eax, byte [rsi]
    cmp     al, ' '
    je      .atof_ws_next
    cmp     al, 9
    je      .atof_ws_next
    cmp     al, 10
    je      .atof_ws_next
    cmp     al, 13
    je      .atof_ws_next
    jmp     .atof_sign
.atof_ws_next:
    inc     rsi
    jmp     .atof_ws

.atof_sign:
    cmp     al, '-'
    jne     .atof_plus
    mov     r8d, 1
    inc     rsi
    jmp     .atof_int
.atof_plus:
    cmp     al, '+'
    jne     .atof_int
    inc     rsi

    ; Integer part: result = result * 10.0 + digit
.atof_int:
    movzx   eax, byte [rsi]
    sub     al, '0'
    cmp     al, 9
    ja      .atof_check_dot
    movzx   eax, al
    cvtsi2sd xmm1, eax         ; xmm1 = digit
    mulsd   xmm0, [const_10_0] ; result *= 10.0
    addsd   xmm0, xmm1         ; result += digit
    inc     rsi
    jmp     .atof_int

.atof_check_dot:
    cmp     byte [rsi], '.'
    jne     .atof_check_exp
    inc     rsi

    ; Fractional part: result += digit * place; place *= 0.1
    movsd   xmm2, [const_0_1]  ; place = 0.1
.atof_frac:
    movzx   eax, byte [rsi]
    sub     al, '0'
    cmp     al, 9
    ja      .atof_check_exp
    movzx   eax, al
    cvtsi2sd xmm1, eax         ; xmm1 = digit
    mulsd   xmm1, xmm2         ; digit * place
    addsd   xmm0, xmm1         ; result += digit * place
    mulsd   xmm2, [const_0_1]  ; place *= 0.1
    inc     rsi
    jmp     .atof_frac

.atof_check_exp:
    movzx   eax, byte [rsi]
    cmp     al, 'e'
    je      .atof_exp
    cmp     al, 'E'
    je      .atof_exp
    jmp     .atof_apply_sign

.atof_exp:
    inc     rsi
    xor     r9d, r9d            ; exp_neg = 0
    xor     r10d, r10d          ; exp_val = 0

    movzx   eax, byte [rsi]
    cmp     al, '-'
    jne     .atof_exp_plus
    mov     r9d, 1
    inc     rsi
    jmp     .atof_exp_digits
.atof_exp_plus:
    cmp     al, '+'
    jne     .atof_exp_digits
    inc     rsi

.atof_exp_digits:
    movzx   eax, byte [rsi]
    sub     al, '0'
    cmp     al, 9
    ja      .atof_exp_apply
    movzx   eax, al
    imul    r10d, 10
    add     r10d, eax
    inc     rsi
    jmp     .atof_exp_digits

.atof_exp_apply:
    ; multiplier = 10.0 ^ exp_val
    movsd   xmm3, [const_10_0] ; 10.0
    ; Start with multiplier = 1.0
    mov     rax, 1
    cvtsi2sd xmm4, rax         ; xmm4 = 1.0
    test    r10d, r10d
    jz      .atof_exp_done
.atof_exp_loop:
    mulsd   xmm4, xmm3         ; multiplier *= 10.0
    dec     r10d
    jnz     .atof_exp_loop
.atof_exp_done:
    test    r9d, r9d
    jnz     .atof_exp_div
    mulsd   xmm0, xmm4
    jmp     .atof_apply_sign
.atof_exp_div:
    divsd   xmm0, xmm4

.atof_apply_sign:
    test    r8d, r8d
    jz      .atof_ret
    ; Negate: xmm0 = -xmm0
    xorpd   xmm1, xmm1
    subsd   xmm1, xmm0
    movsd   xmm0, xmm1

.atof_ret:
    add     rsp, 8
    pop     rsi
    pop     rbx
    ret

; ------------------------------------------------------------
; herb_strdup(HerbArena* arena [RCX], const char* s [RDX])
; Returns: char* (RAX) or NULL
; ------------------------------------------------------------
herb_strdup:
    push    rbx
    push    r12
    sub     rsp, 40

    mov     rbx, rcx            ; arena
    mov     r12, rdx            ; s

    ; len = herb_strlen(s) + 1
    mov     rcx, r12
    call    herb_strlen
    inc     rax                 ; +1 for null terminator
    mov     r8, rax             ; save len in r8

    ; dup = herb_arena_alloc(arena, len)
    mov     rcx, rbx
    mov     rdx, rax
    push    r8                  ; save len
    call    herb_arena_alloc
    pop     r8
    test    rax, rax
    jz      .strdup_done

    ; herb_memcpy(dup, s, len)
    push    rax                 ; save dup
    mov     rcx, rax            ; dst
    mov     rdx, r12            ; src
    ; r8 already = len
    call    herb_memcpy
    pop     rax                 ; restore dup

.strdup_done:
    add     rsp, 40
    pop     r12
    pop     rbx
    ret
