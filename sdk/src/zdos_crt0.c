/* Program startup for programs with main (needs zdos_libc.c for exit):
 * sets zdos, loads the imported libraries, splits the command line
 * into argv (rules: sdk/README.md), runs the global constructors,
 * calls main and ends through exit() with its result, so atexit
 * functions and destructors run. */
#include <stddef.h>
#include <stdlib.h>
#include "zdos.h"
#include "zdos_internal.h"

extern int main(int argc, char **argv);

/* From the linker scripts in sdk/linkers */
typedef void (*zdos_init_fn)(void);
extern zdos_init_fn __init_array_start[];
extern zdos_init_fn __init_array_end[];
extern zdos_init_fn __fini_array_start[];
extern zdos_init_fn __fini_array_end[];

#define MAX_ARGS 256
static char program_name[1032]; /* a path: "C:" + 1024 bytes */
static char arg_text[4096 + 2]; /* ZDOS passes at most 4096 bytes of arguments */
static char *argv_table[MAX_ARGS + 2];

static void run_fini(void) {
    for (zdos_init_fn *f = __fini_array_end; f > __fini_array_start;) {
        (*--f)();
    }
}

static int split_args(const char *args, size_t len) {
    int argc = 1;
    size_t out = 0;
    size_t i = 0;
    while (argc <= MAX_ARGS) {
        while (i < len && (args[i] == ' ' || args[i] == '\t')) {
            ++i;
        }
        if (i >= len) {
            break;
        }
        argv_table[argc++] = &arg_text[out];
        bool quoted = false;
        while (i < len && (quoted || (args[i] != ' ' && args[i] != '\t'))) {
            if (args[i] == '\\' && i + 1 < len && args[i + 1] == '"') {
                arg_text[out++] = '"';
                i += 2;
            } else if (args[i] == '"') {
                quoted = !quoted;
                ++i;
            } else {
                arg_text[out++] = args[i++];
            }
            if (out + 1 >= sizeof(arg_text)) {
                break;
            }
        }
        arg_text[out++] = '\0';
        if (out >= sizeof(arg_text)) {
            break;
        }
    }
    argv_table[argc] = NULL;
    return argc;
}

ZDOS_CALL unsigned char zdos_entry(const zdos_start *start) {
    zdos_init(start);
    if (!zdos_load_imports_offering(zdos_imports_runtime())) zdos->programs->exit(1);

    size_t n = zdos->programs->program_path(program_name, sizeof(program_name) - 1);
    program_name[n] = '\0';
    argv_table[0] = program_name;
    int argc = split_args(start->args, start->args_len);
    zdos_tls_start(); /* constructors may use thread_local data */

    for (zdos_init_fn *f = __init_array_start; f < __init_array_end; ++f) {
        (*f)();
    }
    zdos_crt0_fini = run_fini;

    exit(main(argc, argv_table));
}
