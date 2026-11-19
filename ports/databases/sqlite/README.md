# SQLite

[SQLite](https://sqlite.org) 3.54 as a library: `C:\LIBS\SQLITE.ZDL`, a copy per program (SQLite keeps global state). With it come the `sqlite3` shell (`SQLITE3.APP`) and its test (`SQLTEST.APP`).

```sh
ports/databases/sqlite/build.sh             # all three CPUs
ports/databases/sqlite/build.sh x86_64      # one or more: x86, x86_64, arm64
zig build                                   # puts them onto drive C:
```

Sources: SQLite's amalgamation (`sqlite3.c`, `sqlite3.h`, `sqlite3ext.h`, `shell.c`, from sqlite.org's download page) in `$ZDOS_PORTS_SRC/sqlite-amalgamation` (`../sqlite-amalgamation` when that variable is unset; `SQLITE_AMALGAMATION=...`). Without it, SQLite's own tree in `$ZDOS_PORTS_SRC/sqlite-src` (`SQLITE_SRC=...`): the amalgamation is then made from it by SQLite's `configure` and `make` (which needs Tcl) in `build/sqlite/amalgamation`. Objects: `build/sqlite/<arch>/`; the sources are only read. The version for ZDOS is taken from `VERSION`.

## How it is made

- `sqlite_zdl.c`: the amalgamation, the file layer and the export table in one compile unit, linked by `zdos-cc ... -o SQLITE.ZDL`. The table is SQLite's own `sqlite3_api_routines` (what loadable extensions get; it only grows at its end), then the functions it lacks (`extras.def`: `sqlite3_initialize`, `sqlite3_config` ...).
- `os_zdos.c`: SQLite's file layer (VFS `zdos`) on ZDOS's file calls. `sync` is `files->commit`.
- Import stubs: `build.sh` reads the table's order from `sqlite3ext.h` (`sqlite3.funcs`, checked against `sizeof(sqlite3_api_routines)`), and `tools/build/zdl-stubs.zig` makes `libsqlite3.a`. A program links it and calls `sqlite3_open` & co by name; its start-up loads `SQLITE.ZDL`.
- Options: no threads (`SQLITE_THREADSAFE=0`), no WAL (it needs shared memory), temporary tables in memory unless `PRAGMA temp_store = FILE`; JSON, math functions, FTS5 and R*Tree in.

## Using it from a program

```sh
zdos-cc -Ibuild/sdk-ports/include prog.c build/sdk-ports/lib/x86_64/libsqlite3.a -o PROG.APP
```

Not reachable through the stubs: SQLite's variables (`sqlite3_version`, `sqlite3_temp_directory`; use `sqlite3_libversion()`), loadable extensions (ZDOS has none).

## Limits

- **Locks:** ZDOS's file locks (`files->lock`) on the bytes SQLite's Windows layer locks, so connections in one program and in several lock each other as SQLite expects. On a ZDOS without them (0.2) there are none.
- Times come from ZDOS's clock; randomness (temporary names, `random()`) comes from ZDOS's random numbers (`getrandom`).

## Tests

`tests/ports/sqlite-tests.py [EDITION...]`, including a power cut mid-commit.
