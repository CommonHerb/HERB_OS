; ============================================================
; HERB OS Kernel Entry Point (64-bit long mode)
;
; Called by the bootloader after entering long mode.
; BSS has already been zeroed by the bootloader.
;
; - Sets up 64KB stack
; - Calls kernel_main() (C function)
; - Contains interrupt handler stubs (timer, keyboard)
;
; Compiled with: nasm -f win64 kernel_entry.asm -o kernel_entry.o
; ============================================================

[bits 64]
default rel

; External C function
extern kernel_main

; Global symbols (visible to C code)
global _start
global timer_isr_stub
global keyboard_isr_stub
global mouse_isr_stub

; Exported variables for C code to read
global volatile_timer_fired
global volatile_key_scancode
global volatile_key_pressed
global mouse_ring
global mouse_ring_head
global mouse_ring_tail

; ============================================================
; ENTRY POINT
; ============================================================
section .text

_start:
    ; ---- Enable SSE ----
    ; GCC for x86-64 uses SSE instructions (movups, etc.) freely.
    ; They fault unless we enable the SSE unit here.
    mov rax, cr0
    and ax, 0xFFFB      ; clear CR0.EM (bit 2) — disable x87 emulation
    or  ax, 0x0002      ; set CR0.MP (bit 1) — monitor coprocessor
    mov cr0, rax

    mov rax, cr4
    or  ax, (1 << 9)    ; set CR4.OSFXSR — enable FXSAVE/FXRSTOR
    or  ax, (1 << 10)   ; set CR4.OSXMMEXCPT — enable unmasked SIMD exceptions
    mov cr4, rax

    ; BSS already zeroed by bootloader.
    ; Set up stack (64KB, in BSS)
    lea rsp, [stack_top]

    ; Call C entry point
    call kernel_main

    ; Should never return
    cli
.halt:
    hlt
    jmp .halt

; ============================================================
; INTERRUPT SERVICE ROUTINE STUBS
;
; These are called by the CPU when interrupts fire.
; They save registers, set flags, send EOI, and return.
; The main loop in kernel_main.c checks the flags.
;
; The runtime is NOT reentrant, so we do NOT call any
; HERB functions from interrupt context. We just set flags.
; ============================================================

; ---- Timer interrupt (IRQ0 -> IDT entry 32) ----
timer_isr_stub:
    push rax
    push rdi

    ; Set timer_fired flag
    lea rdi, [volatile_timer_fired]
    mov byte [rdi], 1

    ; Send End-Of-Interrupt to PIC (master)
    mov al, 0x20
    out 0x20, al

    pop rdi
    pop rax
    iretq

; ---- Keyboard interrupt (IRQ1 -> IDT entry 33) ----
keyboard_isr_stub:
    push rax
    push rdi

    ; Read scan code from keyboard controller
    in al, 0x60
    lea rdi, [volatile_key_scancode]
    mov byte [rdi], al

    ; Set key_pressed flag
    lea rdi, [volatile_key_pressed]
    mov byte [rdi], 1

    ; Send End-Of-Interrupt to PIC (master)
    mov al, 0x20
    out 0x20, al

    pop rdi
    pop rax
    iretq

; ---- Mouse interrupt (IRQ12 -> IDT entry 44) ----
; IRQ12 is on the slave PIC, so EOI goes to both slave and master.
; Uses a 64-byte ring buffer to avoid lost bytes during long main-loop work.
mouse_isr_stub:
    push rax
    push rdi
    push rcx

    ; Read data byte from PS/2 controller
    in al, 0x60
    mov cl, al                              ; save byte in cl

    ; Store in ring buffer: mouse_ring[head] = byte
    lea rdi, [mouse_ring_head]
    movzx eax, byte [rdi]                  ; eax = current head index
    lea rdi, [mouse_ring]
    mov byte [rdi + rax], cl               ; ring[head] = byte

    ; Advance head: head = (head + 1) & 0x3F
    inc al
    and al, 0x3F
    lea rdi, [mouse_ring_head]
    mov byte [rdi], al

    ; Send EOI to slave PIC (port 0xA0) then master PIC (port 0x20)
    mov al, 0x20
    out 0xA0, al
    out 0x20, al

    pop rcx
    pop rdi
    pop rax
    iretq

; ============================================================
; DATA (in BSS — zeroed by bootloader)
; ============================================================
section .bss

; Volatile flags set by ISRs, read by main loop
volatile_timer_fired:   resb 1
volatile_key_scancode:  resb 1
volatile_key_pressed:   resb 1
mouse_ring:         resb 64     ; 64-byte circular buffer for mouse bytes
mouse_ring_head:    resb 1      ; write index (ISR increments)
mouse_ring_tail:    resb 1      ; read index (main loop increments)

; Alignment padding
alignb 16

; 256KB stack (evaluate_tension needs ~50KB for BindingSetList alone)
stack_bottom: resb 262144
stack_top:
