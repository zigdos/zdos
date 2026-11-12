/* HELLO_API: a program on the bare zdos API, without the C library.
 * zdos_init connects the groups (zdos->console, zdos->files ...).
 * Arguments come as text (start->args, args_len), not 0-terminated.
 * Build by hand: SDK/README.md. */
#include "zdos.h"

ZDOS_CALL unsigned char zdos_entry(const zdos_start *start) {
    zdos_init(start);
    zdos_puts("Hello from a ZDOS C app!\n");
    if (start->args_len > 0) {
        zdos_puts("Arguments: ");
        zdos->console->print(start->args, start->args_len);
        zdos_puts("\n");
    }
    return 0;
}
