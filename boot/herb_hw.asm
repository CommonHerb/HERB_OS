; boot/herb_hw.asm — HERB hardware interface (Phase 2 assembly)
;
; x86-64 port I/O primitives. Called from C via Microsoft x64 ABI.
; These replace the inline asm wrappers in kernel_main.c.
;
; Assembled with: nasm -f win64 herb_hw.asm -o herb_hw.o

[bits 64]
default rel

global outb
global inb

section .text

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
