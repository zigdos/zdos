#!/usr/bin/env bash
# SQLite: SQLITE.ZDL, SQLITE3.APP, SQLTEST.APP, sqlite3.h, libsqlite3.a
#   build.sh [x86|x86_64|arm64]...   (none: all three)
# Sources: the amalgamation (SQLITE_AMALGAMATION=...), else SQLite's
# tree (SQLITE_SRC=...), where configure and make build it (tclsh).
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/databases/sqlite
SQLITE_AMALGAMATION=${SQLITE_AMALGAMATION:-$SRC_ROOT/sqlite-amalgamation}
SQLITE_SRC=${SQLITE_SRC:-$SRC_ROOT/sqlite-src}
BUILD=$ZIGDOS/build/sqlite
if [ -f "$SQLITE_AMALGAMATION/sqlite3.c" ]; then
    AMALG=$SQLITE_AMALGAMATION
else
    AMALG=$BUILD/amalgamation
fi
mkdir -p "$BUILD"

# The amalgamation: one C file of all of SQLite, and the shell's:
if [ ! -f "$AMALG/sqlite3.c" ] || [ ! -f "$AMALG/shell.c" ]; then
    [ -f "$SQLITE_SRC/configure" ] || die "no SQLite sources in $SQLITE_SRC (SQLITE_SRC=...)"
    echo "=== SQLite's amalgamation ==="
    mkdir -p "$AMALG"
    (cd "$AMALG" && "$SQLITE_SRC/configure" >configure.log && make sqlite3.c shell.c >make.log) ||
        die "making the amalgamation failed: $AMALG/configure.log, make.log"
fi

# For zdos-stubs: the sqlite3_api_routines members named by
# sqlite3ext.h's "#define sqlite3_x sqlite3_api->y" lines (two
# names for one: both on a line), then extras.def.
FUNCS=$BUILD/sqlite3.funcs
awk '/^struct sqlite3_api_routines/ { on = 1; next } on && /^};/ { exit } on' "$AMALG/sqlite3ext.h" |
    sed 's#/\*.*\*/##' | tr '\n' ' ' | tr ';' '\n' |
    sed -n 's/^[^(]*([A-Za-z_ ]*\* *\([A-Za-z0-9_]*\) *).*/\1/p' >"$BUILD/members.txt"
sed -n 's/^#define \(sqlite3_[A-Za-z0-9_]*\) *sqlite3_api->\([A-Za-z0-9_]*\).*/\2 \1/p' "$AMALG/sqlite3ext.h" >"$BUILD/names.txt"
awk 'NR == FNR { if (index(" " name[$1] " ", " " $2 " ") == 0) name[$1] = name[$1] " " $2; next }
     { print ($1 in name) ? substr(name[$1], 2) : "zdos_sqlite_slot_" FNR }' \
    "$BUILD/names.txt" "$BUILD/members.txt" >"$FUNCS"
# Every member read, or the slots after a missed one would be wrong:
count=$(wc -l <"$FUNCS")
sed -n 's/^X(\(.*\))$/\1/p' "$PORT/extras.def" >>"$FUNCS"
printf '#include "sqlite3ext.h"\n_Static_assert(sizeof(sqlite3_api_routines) / sizeof(void *) == %s, "members missed");\n' \
    "$count" >"$BUILD/count.c"
# (-fsyntax-only fails in Zig 0.14.1; -o /dev/null leaves count.o in .):
zig cc -c -I"$AMALG" "$BUILD/count.c" -o "$BUILD/count.o" ||
    die "$FUNCS has $count functions, sqlite3_api_routines more: build.sh reads sqlite3ext.h wrong"

# A file layer of ZDOS's (os_zdos.c), threads off (programs don't
# share a connection), no WAL (no shared memory); JSON, math, FTS5 and
# R*Tree in. Extension loading stays: its table is the export table.
LIB_FLAGS="-DSQLITE_OS_OTHER=1 -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_WAL=1 -DSQLITE_DEFAULT_MEMSTATUS=0
    -DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_ENABLE_MATH_FUNCTIONS=1 -DSQLITE_ENABLE_FTS5=1
    -DSQLITE_ENABLE_RTREE=1 -DSQLITE_ENABLE_SESSION=1 -DSQLITE_OMIT_SHARED_CACHE=1
    -DSQLITE_MAX_MMAP_SIZE=0 -DSQLITE_TEMP_STORE=2"
# The shell: no readline, no zlib, no child processes:
SHELL_FLAGS="-DSQLITE_OMIT_LOAD_EXTENSION=1 -DSQLITE_NOHAVE_SYSTEM=1 -DHAVE_READLINE=0 -DHAVE_EDITLINE=0"

for arch in $(arches "$@"); do
    select_arch "$arch"
    obj=$BUILD/$arch
    mkdir -p "$obj"
    echo "=== SQLITE.ZDL for $arch ==="
    $STUBS SQLITE "$FUNCS" "$obj/libsqlite3.a"
    $CC -Os $LIB_FLAGS -I"$AMALG" -I"$PORT" -w -c "$PORT/sqlite_zdl.c" -o "$obj/sqlite_zdl.o"
    $CC "$obj/sqlite_zdl.o" -o "$obj/SQLITE.ZDL"
    echo "=== SQLITE3.APP, SQLTEST.APP for $arch ==="
    $CC -Os $SHELL_FLAGS -I"$AMALG" -w "$AMALG/shell.c" "$obj/libsqlite3.a" -o "$obj/SQLITE3.APP"
    $CC -Os -I"$AMALG" "$PORT/sqltest.c" "$obj/libsqlite3.a" -o "$obj/SQLTEST.APP"
    install_app "$obj/SQLITE.ZDL" LIBS_3RD
    install_app "$obj/SQLITE3.APP" APPS_3RD
    install_app "$obj/SQLTEST.APP" APPS_3RD
    install_file "$obj/libsqlite3.a" "sdk-ports/lib/$arch"
done
install_file "$AMALG/sqlite3.h" sdk-ports/include
install_file "$AMALG/sqlite3ext.h" sdk-ports/include
