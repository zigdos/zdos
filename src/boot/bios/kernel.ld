/* Stage 2 copies the kernel to 1 MiB and starts at its first
   byte (_start in main_bios.zig). */
ENTRY(_start)

SECTIONS
{
    . = 0x100000;
    __kernel_start = .;

    .text : { *(.text.entry) *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    .data : { *(.data .data.*) }
    .bss (NOLOAD) : {
        __bss_start = .;
        *(.bss .bss.*) *(COMMON)
        __bss_end = .;
    }
    /* Startup stack; programs get their own */
    .stack (NOLOAD) : {
        . = ALIGN(16);
        . += 64K;
        __stack_top = .;
    }
    __kernel_end = .;

    /DISCARD/ : { *(.eh_frame*) *(.comment) *(.note*) }
}
