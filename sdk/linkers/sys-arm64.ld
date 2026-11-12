/* arm64 drivers (.SYS), as app-arm64.ld */
ENTRY(zdos_driver_init)

SECTIONS
{
    . = 0;

    .header : {
        LONG(0x4159535A)    /* magic "ZSYA" */
        LONG(DEFINED(zdos_api_version) ? zdos_api_version : 1)  /* API version needed */
        LONG(DEFINED(zdos_file_version) ? zdos_file_version : 0)  /* major.minor.patch.build */
        LONG(0)             /* keeps the QUADs aligned */
        QUAD(zdos_driver_init)
        QUAD(__app_end)
        QUAD(__rela_start)
        QUAD(__rela_end)
        QUAD(__code_end)
        QUAD(__ro_end)
        QUAD(zdos_driver_ids)   /* PCI IDs it drives, 0-ended */
    }
    .text : { *(.text .text.*) }

    . = ALIGN(16384);
    __code_end = .;
    .rodata : { *(.rodata .rodata.*) }
    /* Import stubs (LLD keeps these sections together): */
    .data.rel.ro : {
        *(.data.rel.ro .data.rel.ro.*)
        . = ALIGN(8);
        __zdos_imports_start = .;
        KEEP(*(.zdos_imports))
        __zdos_imports_end = .;
    }
    .init_array : {
        __init_array_start = .;
        KEEP(*(SORT_BY_INIT_PRIORITY(.init_array.*)))
        KEEP(*(.init_array))
        __init_array_end = .;
    }
    .fini_array : {
        __fini_array_start = .;
        KEEP(*(SORT_BY_INIT_PRIORITY(.fini_array.*)))
        KEEP(*(.fini_array))
        __fini_array_end = .;
    }
    .got : { *(.got .got.plt) }
    .rela.dyn : { __rela_start = .; *(.rela.*) __rela_end = .; }

    . = ALIGN(16384);
    __ro_end = .;
    .data : { *(.data .data.*) }
    .bss : { *(.bss .bss.*) *(COMMON) }
    __app_end = .;

    /DISCARD/ : {
        *(.eh_frame*) *(.comment) *(.note*) *(.interp)
        *(.dynamic) *(.dynsym) *(.dynstr) *(.hash) *(.gnu.hash)
    }
}
