/* x86_64 libraries (.ZDL), as app-x86_64.ld */
ENTRY(zdos_library)
/* Kept if defined: section GC would drop them before DEFINED() */
EXTERN(zdos_library_shared zdos_library_init)

SECTIONS
{
    . = 0;

    .header : {
        __zdos_header = .;  /* zdos_libinit.c reads the flags */
        LONG(0x364C445A)    /* magic "ZDL6" */
        LONG(DEFINED(zdos_api_version) ? zdos_api_version : 1)  /* API version needed */
        LONG(DEFINED(zdos_file_version) ? zdos_file_version : 0)  /* major.minor.patch.build */
        LONG(0)             /* keeps the QUADs aligned */
        QUAD(zdos_library)
        QUAD(__app_end)
        QUAD(__rela_start)
        QUAD(__rela_end)
        QUAD(__code_end)
        QUAD(__ro_end)
        QUAD(DEFINED(zdos_library_shared) ? 1 : 0)                /* flags: 1 shared */
        QUAD(DEFINED(zdos_library_init) ? zdos_library_init : 0)  /* run once per load */
    }
    .text : { *(.text .text.*) }

    . = ALIGN(4096);
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
    .rela.dyn : { __rela_start = .; *(.rela.*) __rela_end = .; }

    . = ALIGN(4096);
    __ro_end = .;
    .data : { *(.data .data.*) }
    .bss : { *(.bss .bss.*) *(COMMON) }
    __app_end = .;
    /* No thread_local data in a library: threads use the program's */
    __tdata_start = .;
    __tdata_end = .;
    __tbss_end = .;

    /DISCARD/ : {
        *(.eh_frame*) *(.comment) *(.note*) *(.interp)
        *(.dynamic) *(.dynsym) *(.dynstr) *(.hash) *(.gnu.hash)
    }
}
