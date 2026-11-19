#!/usr/bin/env bash
# Lua 5.5: lua.app from onelua.c and version.c (the version for
# ZDOS, from lua.h).
#   build.sh [x86|x86_64|arm64]...   (none: all three)
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/coding/lua
LUA_SRC=${LUA_SRC:-$SRC_ROOT/lua/src}
[ -f "$LUA_SRC/onelua.c" ] || die "no onelua.c in $LUA_SRC (LUA_SRC=...)"

for arch in $(arches "$@"); do
    select_arch "$arch"
    echo "=== lua.app for $arch ==="
    obj=$ZIGDOS/build/lua/$arch
    mkdir -p "$obj"
    $CC -Os -I"$LUA_SRC" -include "$PORT/luaconf-zdos.h" "$LUA_SRC/onelua.c" "$PORT/version.c" -o "$obj/lua.app"
    install_app "$obj/lua.app" APPS_3RD
done
