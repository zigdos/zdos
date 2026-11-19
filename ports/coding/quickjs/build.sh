#!/usr/bin/env bash
# QuickJS (QuickJS-NG): qjs.app, the JavaScript interpreter and its
# REPL, from QuickJS's own files with quickjs-zdos.h included first;
# the files quickjs-zdos.patch changes are compiled from patched
# copies in build/quickjs/src. With ZDOS's modules: zdos:net (sockets,
# TLS by the Mbed TLS port), zdos:sqlite (the SQLite port's
# SQLITE.ZDL) and zdos:web (web.js, inside the program).
#   build.sh [x86|x86_64|arm64]...   (none: all three)
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/coding/quickjs
QUICKJS_SRC=${QUICKJS_SRC:-$SRC_ROOT/quickjs}
[ -f "$QUICKJS_SRC/quickjs.c" ] && [ -f "$QUICKJS_SRC/gen/repl.c" ] || die "no QuickJS in $QUICKJS_SRC (QUICKJS_SRC=...)"

# As QuickJS's CMakeLists.txt builds qjs: the engine, its libc (std
# and os modules) and the CLI with its compiled-in REPL:
SOURCES="dtoa.c libregexp.c libunicode.c quickjs.c quickjs-libc.c qjs.c gen/repl.c gen/standalone.c"
FLAGS="-O2 -std=gnu11 -D_GNU_SOURCE -DQUICKJS_NG_BUILD -DQJS_BUILD_LIBC"

# PATCHED FILES
# Fresh copies when QuickJS's file or the patch is newer:
PATCHED_DIR=$ZIGDOS/build/quickjs/src
PATCHED=$(sed -n 's|^+++ b/||p' "$PORT/quickjs-zdos.patch" | tr '\n' ' ')
mkdir -p "$PATCHED_DIR"
stale=0
for f in $PATCHED; do
    if [ ! -f "$PATCHED_DIR/$f" ] || [ "$QUICKJS_SRC/$f" -nt "$PATCHED_DIR/$f" ] || [ "$PORT/quickjs-zdos.patch" -nt "$PATCHED_DIR/$f" ]; then stale=1; fi
done
if [ $stale = 1 ]; then
    for f in $PATCHED; do cp "$QUICKJS_SRC/$f" "$PATCHED_DIR/$f" && chmod u+w "$PATCHED_DIR/$f"; done
    patch -s -d "$PATCHED_DIR" -p1 <"$PORT/quickjs-zdos.patch" || die "quickjs-zdos.patch doesn't apply to $QUICKJS_SRC"
fi

# ZDOS's modules: the C files, web.js embedded by zdos_web.c
MODULES="zdos_net.c zdos_sqlite.c zdos_web.c"

for arch in $(arches "$@"); do
    select_arch "$arch"
    need_port libs/mbedtls libmbedtls.a
    need_port databases/sqlite libsqlite3.a SQLITE.ZDL
    echo "=== qjs.app for $arch ==="
    obj=$ZIGDOS/build/quickjs/$arch
    mkdir -p "$obj"
    objs=()
    for f in $SOURCES; do
        o=$obj/$(basename "${f%.c}").o
        src=$QUICKJS_SRC/$f
        [ -f "$PATCHED_DIR/$f" ] && case " $PATCHED " in *" $f "*) src=$PATCHED_DIR/$f ;; esac
        $CC $FLAGS -I"$QUICKJS_SRC" -I"$PORT" -include "$PORT/quickjs-zdos.h" -c "$src" -o "$o"
        objs+=("$o")
    done
    for f in $MODULES; do
        o=$obj/${f%.c}.o
        $CC $FLAGS -Wno-c23-extensions -I"$QUICKJS_SRC" -I"$PORT" -c "$PORT/$f" -o "$o"
        objs+=("$o")
    done
    $CC -Os -I"$QUICKJS_SRC" -c "$PORT/version.c" -o "$obj/version.o"
    $CC "${objs[@]}" "$obj/version.o" -lmbedtls -lmbedx509 -lmbedcrypto -lsqlite3 -o "$obj/qjs.app"
    install_app "$obj/qjs.app" APPS_3RD
done
