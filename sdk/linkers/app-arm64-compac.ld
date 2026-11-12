/* ARM64 .APP, compact; code keeps its 4 KiB file offsets for adrp */
ENTRY(zdos_entry)

SECTIONS
{
    . = 0;

    .header : {
        LONG(0x4150415A)    /* magic "ZAPA" */
        LONG(DEFINED(zdos_api_version) ? zdos_api_version : 1)  /* API version needed */
        LONG(DEFINED(zdos_file_version) ? zdos_file_version : 0)  /* major.minor.patch.build */
        LONG(0)             /* keeps the QUADs aligned */
        QUAD(zdos_entry)
        QUAD(__app_end)
        QUAD(__rela_start)
        QUAD(__rela_end)
    }
    .text : { *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    /* libunwind finds these by their symbols: */
    .eh_frame_hdr : { __eh_frame_hdr_start = .; *(.eh_frame_hdr) __eh_frame_hdr_end = .; }
    .eh_frame : { __eh_frame_start = .; KEEP(*(.eh_frame)) __eh_frame_end = .; }
    .gcc_except_table : { *(.gcc_except_table .gcc_except_table.*) }
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
    .data : { *(.data .data.*) }
    /* Copied per thread by zdos_tls.c; 64 is the largest TLS alignment: */
    .tdata : ALIGN(64) { __tdata_start = .; *(.tdata .tdata.*) __tdata_end = .; }
    .tbss : ALIGN(64) { *(.tbss .tbss.*) *(.tcommon) __tbss_end = .; }
    .rela.dyn : { __rela_start = .; *(.rela.*) __rela_end = .; }
    .bss : { *(.bss .bss.*) *(COMMON) }
    __app_end = .;

    /DISCARD/ : {
        *(.comment) *(.note*) *(.interp)
        *(.dynamic) *(.dynsym) *(.dynstr) *(.hash) *(.gnu.hash)
    }
}
