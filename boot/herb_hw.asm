; boot/herb_hw.asm — HERB hardware interface (Phase 2 assembly)
;
; x86-64 hardware primitives. Called from C via Microsoft x64 ABI.
; Replaces inline asm wrappers in kernel_main.c and framebuffer.h.
;
; Session 58: outb, inb (port I/O bytes)
; Session 59: outw, inw, outl, inl, io_wait (port I/O words/dwords)
;             hw_lidt, hw_sti, hw_hlt, hw_flush_tlb (privileged CPU ops)
; Session 60: serial_init, serial_putchar, serial_print (serial port)
;
; Assembled with: nasm -f win64 herb_hw.asm -o herb_hw.o

[bits 64]
default rel

; Port I/O
global outb
global inb
global outw
global inw
global outl
global inl
global io_wait

; Privileged CPU operations
global hw_lidt
global hw_sti
global hw_hlt
global hw_flush_tlb

; Serial port (COM1)
global serial_init
global serial_putchar
global serial_print

section .text

; ============================================================
; PORT I/O — Tier 1
; ============================================================

; void outb(uint16_t port, uint8_t val)
; MS x64: rcx = port, rdx = val
outb:
    mov al, dl          ; val -> AL (read before dx clobbered)
    mov dx, cx          ; port -> DX
    out dx, al
    ret

; uint8_t inb(uint16_t port)
; MS x64: rcx = port, return in rax
inb:
    xor eax, eax        ; zero full rax for clean return
    mov dx, cx          ; port -> DX
    in al, dx            ; read port -> AL
    ret

; void outw(uint16_t port, uint16_t val)
; MS x64: rcx = port, rdx = val
outw:
    mov ax, dx          ; val -> AX (read before dx clobbered)
    mov dx, cx          ; port -> DX
    out dx, ax
    ret

; uint16_t inw(uint16_t port)
; MS x64: rcx = port, return in rax
inw:
    xor eax, eax        ; zero full rax for clean return
    mov dx, cx          ; port -> DX
    in ax, dx            ; read port -> AX
    ret

; void outl(uint16_t port, uint32_t val)
; MS x64: rcx = port, rdx = val
outl:
    mov eax, edx        ; val -> EAX (read before dx clobbered)
    mov dx, cx          ; port -> DX
    out dx, eax
    ret

; uint32_t inl(uint16_t port)
; MS x64: rcx = port, return in rax
inl:
    xor eax, eax        ; zero full rax for clean return
    mov dx, cx          ; port -> DX
    in eax, dx           ; read port -> EAX
    ret

; void io_wait(void)
; Write to port 0x80 (POST diagnostic, safe to write) for ~1µs delay
io_wait:
    mov al, 0
    mov dx, 0x80
    out dx, al
    ret

; ============================================================
; PRIVILEGED CPU OPERATIONS — Tier 2
; ============================================================

; void hw_lidt(void* idt_descriptor)
; MS x64: rcx = pointer to IDT descriptor struct
hw_lidt:
    lidt [rcx]
    ret

; void hw_sti(void)
; Enable interrupts
hw_sti:
    sti
    ret

; void hw_hlt(void)
; Halt CPU until next interrupt
hw_hlt:
    hlt
    ret

; void hw_flush_tlb(void)
; Flush TLB by reloading CR3
hw_flush_tlb:
    mov rax, cr3
    mov cr3, rax
    ret

; ============================================================
; SERIAL PORT (COM1) — Tier 3
; ============================================================

; void serial_init(void)
; Configure COM1 UART: 115200 baud, 8N1, FIFO enabled
serial_init:
    ; Disable interrupts
    mov dx, 0x3F9           ; COM1 + 1
    mov al, 0x00
    out dx, al

    ; Enable DLAB (set baud rate divisor)
    mov dx, 0x3FB           ; COM1 + 3
    mov al, 0x80
    out dx, al

    ; Divisor low byte = 1 (115200 baud)
    mov dx, 0x3F8           ; COM1 + 0
    mov al, 0x01
    out dx, al

    ; Divisor high byte = 0
    mov dx, 0x3F9           ; COM1 + 1
    mov al, 0x00
    out dx, al

    ; 8 bits, no parity, 1 stop bit (8N1), DLAB off
    mov dx, 0x3FB           ; COM1 + 3
    mov al, 0x03
    out dx, al

    ; Enable FIFO, clear, 14-byte threshold
    mov dx, 0x3FA           ; COM1 + 2
    mov al, 0xC7
    out dx, al

    ; DTR + RTS + OUT2
    mov dx, 0x3FC           ; COM1 + 4
    mov al, 0x0B
    out dx, al

    ret

; void serial_putchar(char c)
; MS x64: c in cl. Poll until TX ready, then send.
serial_putchar:
    mov r8b, cl             ; save char (r8 is volatile, no calls here)
.poll:
    mov dx, 0x3FD           ; COM1 + 5 (Line Status Register)
    in al, dx
    test al, 0x20           ; bit 5 = TX holding register empty
    jz .poll
    mov dx, 0x3F8           ; COM1 + 0 (data register)
    mov al, r8b
    out dx, al
    ret

; void serial_print(const char* s)
; MS x64: s in rcx. Loop over string, emit \r before \n.
serial_print:
    push rsi                ; rsi is non-volatile in MS x64
    sub rsp, 32             ; shadow space for serial_putchar calls
    mov rsi, rcx            ; save string pointer
.loop:
    movzx eax, byte [rsi]
    test al, al
    jz .done
    cmp al, 0x0A            ; '\n'?
    jne .emit
    ; Emit \r before \n
    mov cl, 0x0D
    call serial_putchar
.emit:
    mov cl, [rsi]
    call serial_putchar
    inc rsi
    jmp .loop
.done:
    add rsp, 32             ; restore shadow space
    pop rsi
    ret
