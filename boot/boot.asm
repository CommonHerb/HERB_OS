; ============================================================
; HERB OS Bootloader
;
; Two-stage x86-64 bootloader. Legacy BIOS boot (MBR).
;
; Stage 1 (sector 0, 512 bytes):
;   - Loaded by BIOS to 0x7C00
;   - Loads stage 2 (sectors 1-7) to 0x7E00
;   - Jumps to stage 2
;
; Stage 2 (sectors 1-7, 3.5KB):
;   - Loads kernel binary to temp buffer at 0x10000
;   - Enters 32-bit protected mode
;   - Zeroes 1MB at 0x100000 (covers all BSS)
;   - Copies kernel from 0x10000 to 0x100000
;   - Sets up identity-mapped page tables (first 64MB)
;   - Enters 64-bit long mode
;   - Jumps to kernel entry at 0x100000
;
; Memory layout:
;   0x1000-0x3FFF  Page tables (PML4, PDPT, PD)
;   0x7C00-0x7DFF  Stage 1 (MBR)
;   0x7E00-0x8BFF  Stage 2
;   0x10000+       Kernel temp buffer (below 1MB)
;   0x100000+      Kernel final location (1MB)
;
; KERNEL_SECTORS: defined at build time by Makefile
;   nasm -f bin -DKERNEL_SECTORS=N boot.asm -o boot.bin
; ============================================================

%ifndef KERNEL_SECTORS
%define KERNEL_SECTORS 128      ; default, overridden by Makefile
%endif

; ============================================================
; STAGE 1 — Master Boot Record (512 bytes)
; ============================================================
[bits 16]
[org 0x7C00]

stage1_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    ; Save boot drive (BIOS passes in DL)
    mov [boot_drive], dl

    ; Print banner
    mov si, msg_boot
    call print16

    ; Load Stage 2 (sectors 1-7) to 0x7E00
    mov ah, 0x42
    mov dl, [boot_drive]
    mov si, dap_stage2
    int 0x13
    jc .disk_error

    ; Jump to Stage 2
    jmp 0x0000:stage2_entry

.disk_error:
    mov si, msg_err
    call print16
    cli
    hlt

; 16-bit BIOS print
print16:
    lodsb
    or al, al
    jz .done
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    jmp print16
.done:
    ret

; Data
msg_boot:   db "HERB OS", 13, 10, 0
msg_err:    db "ERR", 0
boot_drive: db 0

; DAP for Stage 2 load
align 4
dap_stage2:
    db 16, 0            ; size, reserved
    dw 7                ; sectors
    dw 0x7E00           ; offset
    dw 0x0000           ; segment
    dq 1                ; LBA

; MBR signature
times 510 - ($ - $$) db 0
dw 0xAA55

; ============================================================
; STAGE 2 — Mode Switching and Kernel Loading
; ============================================================
stage2_entry:
    mov si, msg_s2
    call print16

    ; ---- Enable A20 line ----
    in al, 0x92
    or al, 0x02
    and al, 0xFE
    out 0x92, al

    ; ---- Load kernel to temp buffer at 0x10000 ----
    mov si, msg_ld
    call print16

    mov dword [ld_lba], 8              ; kernel starts at LBA 8
    mov word [ld_seg], 0x1000          ; segment 0x1000 = phys 0x10000
    mov word [ld_rem], KERNEL_SECTORS

.load_loop:
    cmp word [ld_rem], 0
    je .load_done

    ; Chunk = min(remaining, 64)
    mov ax, [ld_rem]
    cmp ax, 64
    jbe .chunk_ok
    mov ax, 64
.chunk_ok:
    ; Fill DAP
    mov [dap_kern.count], ax
    mov bx, [ld_seg]
    mov [dap_kern.seg], bx
    mov ebx, [ld_lba]
    mov [dap_kern.lba_lo], ebx
    mov dword [dap_kern.lba_hi], 0

    ; INT 13h extended read
    push ax                            ; save chunk count
    mov ah, 0x42
    mov dl, [boot_drive]
    mov si, dap_kern
    int 0x13
    jc .load_fail
    pop ax

    ; Advance
    sub [ld_rem], ax
    movzx eax, ax
    add [ld_lba], eax
    shl ax, 5                          ; sectors * 32 = paragraphs
    add [ld_seg], ax

    ; Progress dot
    mov al, '.'
    mov ah, 0x0E
    int 0x10
    jmp .load_loop

.load_fail:
    pop ax
    mov si, msg_fail
    call print16
    cli
    hlt

.load_done:
    mov si, msg_ok
    call print16

    ; ---- Disable interrupts for mode switching ----
    cli

    ; ---- Load GDT ----
    lgdt [gdt_desc]

    ; ---- Enter Protected Mode ----
    mov eax, cr0
    or eax, 1                          ; PE bit
    mov cr0, eax

    jmp 0x08:pm_entry                  ; far jump to 32-bit code

; ---- Stage 2 data ----
msg_s2:     db "S2 ", 0
msg_ld:     db "LD", 0
msg_ok:     db " OK", 13, 10, 0
msg_fail:   db " FAIL", 0

ld_lba:     dd 0
ld_seg:     dw 0
ld_rem:     dw 0

align 4
dap_kern:
    db 16, 0                           ; size, reserved
.count:
    dw 0                               ; sectors (filled per chunk)
    dw 0x0000                          ; offset (always 0)
.seg:
    dw 0                               ; segment (filled per chunk)
.lba_lo:
    dd 0                               ; LBA low (filled per chunk)
.lba_hi:
    dd 0                               ; LBA high

; ============================================================
; GDT
; ============================================================
align 16
gdt_start:
    dq 0                               ; [0x00] Null

    ; [0x08] 32-bit code: base=0, limit=4GB, ring 0
    dw 0xFFFF, 0x0000
    db 0x00, 10011010b, 11001111b, 0x00

    ; [0x10] 32-bit data: base=0, limit=4GB, ring 0
    dw 0xFFFF, 0x0000
    db 0x00, 10010010b, 11001111b, 0x00

    ; [0x18] 64-bit code: L bit, ring 0
    dw 0x0000, 0x0000
    db 0x00, 10011010b, 00100000b, 0x00

    ; [0x20] 64-bit data: ring 0
    dw 0x0000, 0x0000
    db 0x00, 10010010b, 00000000b, 0x00
gdt_end:

gdt_desc:
    dw gdt_end - gdt_start - 1
    dd gdt_start

; ============================================================
; 32-bit Protected Mode
; ============================================================
[bits 32]

pm_entry:
    ; Load data segments
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    ; ---- Zero 4MB at 0x100000 (covers all kernel BSS + headroom) ----
    ; The kernel BSS includes ~256KB stack, HERB runtime static arrays,
    ; and potentially framebuffer scratch data. 4MB ensures everything
    ; is zeroed. Arena starts at 0x800000 (8MB), well beyond this range.
    mov edi, 0x100000
    mov ecx, (4 * 1024 * 1024) / 4    ; 1M dwords = 4MB
    xor eax, eax
    rep stosd

    ; ---- Copy kernel binary from 0x10000 to 0x100000 ----
    mov esi, 0x10000                   ; source (temp buffer)
    mov edi, 0x100000                  ; destination
    mov ecx, (KERNEL_SECTORS * 512) / 4
    rep movsd

    ; ---- Set up page tables ----
    ; PML4 at 0x1000, PDPT at 0x2000, PD at 0x3000
    ; Identity-map first 64MB using 2MB pages

    ; Zero page table pages
    mov edi, 0x1000
    mov ecx, (3 * 4096) / 4           ; 3 pages
    xor eax, eax
    rep stosd

    ; PML4[0] -> PDPT at 0x2000
    mov dword [0x1000], 0x2003        ; present + writable

    ; PDPT[0] -> PD at 0x3000
    mov dword [0x2000], 0x3003        ; present + writable

    ; PD[0..31] -> 2MB pages (64MB total)
    mov edi, 0x3000
    mov eax, 0x00000083               ; present + writable + 2MB page
    mov ecx, 32
.fill_pd:
    mov [edi], eax
    mov dword [edi + 4], 0            ; high 32 bits = 0
    add eax, 0x200000                 ; next 2MB
    add edi, 8
    dec ecx
    jnz .fill_pd

    ; ---- Enable PAE ----
    mov eax, cr4
    or eax, (1 << 5)
    mov cr4, eax

    ; ---- Load PML4 into CR3 ----
    mov eax, 0x1000
    mov cr3, eax

    ; ---- Enable Long Mode (IA32_EFER.LME) ----
    mov ecx, 0xC0000080
    rdmsr
    or eax, (1 << 8)
    wrmsr

    ; ---- Enable Paging (activates Long Mode) ----
    mov eax, cr0
    or eax, (1 << 31)
    mov cr0, eax

    ; ---- Jump to 64-bit code ----
    jmp 0x18:lm_entry

; ============================================================
; 64-bit Long Mode
; ============================================================
[bits 64]

lm_entry:
    ; Load 64-bit data segment
    mov ax, 0x20
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    ; ---- Jump to kernel at 0x100000 ----
    mov rax, 0x100000
    jmp rax

; ---- Pad Stage 2 to exactly 7 sectors (3584 bytes) ----
times (7 * 512) - ($ - stage2_entry) db 0
