/*
 * HERB OS Kernel Linker Script (PE format)
 *
 * Defines BSS boundary symbols needed by kernel_entry.asm.
 * Section addresses are controlled by PE --image-base flag.
 */

ENTRY(_start)

SECTIONS {
    .text : {
        *(.text)
        *(.text.*)
    }

    .rdata : {
        *(.rdata)
        *(.rdata.*)
        *(.rodata)
        *(.rodata.*)
    }

    .data : {
        *(.data)
        *(.data.*)
    }

    .bss ALIGN(16) : {
        _bss_start = .;
        *(.bss)
        *(.bss.*)
        *(COMMON)
        _bss_end = .;
    }
}
