; boot/herb_hw.asm — HERB hardware interface (Phase 2 assembly)
;
; x86-64 hardware primitives. Called from C via Microsoft x64 ABI.
; Replaces inline asm wrappers in kernel_main.c and framebuffer.h.
;
; Session 58: outb, inb (port I/O bytes)
; Session 59: outw, inw, outl, inl, io_wait (port I/O words/dwords)
;             hw_lidt, hw_sti, hw_hlt, hw_flush_tlb (privileged CPU ops)
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
