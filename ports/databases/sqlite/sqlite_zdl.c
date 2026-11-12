/* SQLITE.ZDL: SQLite as a library (a copy per program: SQLite has globals).
 * Its export table: the slot count, SQLite's own sqlite3_api_routines (the
 * table loadable extensions get; it only grows at its end), then the few
 * functions it lacks (extras.def). The import stubs (sqlite3.funcs, made by
 * build.sh) call sqlite3_open & co by name. One compile unit: the
 * amalgamation, then the file layer and the table. */
#include "sqlite3.c"
#include "os_zdos.c"

#define X(f) +1
enum { zdos_sqlite_extras = 0
#include "extras.def"
};
#undef X

struct zdos_sqlite_table {
    uintptr_t slots;
    sqlite3_api_routines api;
    void *extras[zdos_sqlite_extras];
};

/* Filled in by zdos_sqlite_start: sqlite3Apis is no constant C can copy
 * at compile time. ZDOS hands the table out only after the start has run. */
struct zdos_sqlite_table zdos_library;

__attribute__((constructor)) static void zdos_sqlite_start(void) {
    zdos_library.slots = sizeof(sqlite3_api_routines) / sizeof(void *) + zdos_sqlite_extras;
    memcpy(&zdos_library.api, &sqlite3Apis, sizeof sqlite3Apis);
    int i = 0;
#define X(f) zdos_library.extras[i++] = (void *)f;
#include "extras.def"
#undef X
}
