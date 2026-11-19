#!/usr/bin/env bash
# HarfBuzz: HARFBUZZ.ZDL (with FreeType: hb-ft), its headers and the
# import stubs, libharfbuzz.a.
#   build.sh [x86|x86_64|arm64]...   (none: all three)
# Sources: ../harfbuzz (HARFBUZZ_SRC=...), only read; built in build/harfbuzz.
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/libs/harfbuzz
HARFBUZZ_SRC=${HARFBUZZ_SRC:-$SRC_ROOT/harfbuzz}
[ -f "$HARFBUZZ_SRC/src/harfbuzz.cc" ] || die "no HarfBuzz sources in $HARFBUZZ_SRC (HARFBUZZ_SRC=...)"
BUILD=$ZIGDOS/build/harfbuzz
FT_INC=$ZIGDOS/build/sdk-ports/include/freetype2
mkdir -p "$BUILD"

# The functions after HB_EXTERN in hb.h, hb-ot.h and hb-ft.h, as
# preprocessed for this build (so #ifdef'd ones drop out), in order:
names() {
    printf '#include <hb.h>\n#include <hb-ot.h>\n#include <hb-ft.h>\n' >"$BUILD/names.c"
    "$ZDOS_CC" --arch=x86_64 -E -DHB_EXTERN=HBEXPORTMARK -include "$PORT/config.h" \
        -I"$HARFBUZZ_SRC/src" -I"$FT_INC" "$BUILD/names.c" | python3 -c '
import re, sys
names = []
for m in re.finditer(r"HBEXPORTMARK(.*?);", sys.stdin.read(), re.S):
    decl = re.sub(r"__attribute__\s*\(\(.*?\)\)", "", m.group(1), flags=re.S)
    ids = re.findall(r"[A-Za-z_][A-Za-z0-9_]*", decl.split("(")[0])
    if ids and ids[-1] not in names:
        names.append(ids[-1])
print("\n".join(names))'
}

for arch in $(arches "$@"); do
    select_arch "$arch"
    need_port libs/freetype libfreetype.a FREETYPE.ZDL
done
# A new HarfBuzz's additions go to the end of exports.def:
FUNCS=$BUILD/harfbuzz.funcs
sed -n 's/^X(\(.*\))$/\1/p' "$PORT/exports.def" >"$FUNCS"
missing=$(names | grep -vxF -f "$FUNCS" || true)
[ -z "$missing" ] || die "HarfBuzz's headers have functions exports.def lacks: $missing"

# As HarfBuzz's meson.build compiles it: one file, C++11, no exceptions,
# RTTI or thread-safe statics:
FLAGS="-O2 -DHAVE_CONFIG_H -I$PORT -I$HARFBUZZ_SRC/src -I$FT_INC"
CXXFLAGS="-std=c++11 -fno-exceptions -fno-rtti -fno-threadsafe-statics -fvisibility-inlines-hidden"

for arch in $(arches "$@"); do
    select_arch "$arch"
    obj=$BUILD/$arch
    mkdir -p "$obj"
    echo "=== HARFBUZZ.ZDL for $arch ==="
    "$SDK/bin/zdos-c++" --arch="$arch" $FLAGS $CXXFLAGS -w -c "$HARFBUZZ_SRC/src/harfbuzz.cc" -o "$obj/harfbuzz.o"
    $CC $FLAGS -Wno-deprecated-declarations -c "$PORT/harfbuzz_zdl.c" -o "$obj/harfbuzz_zdl.o"
    # FreeType through its stubs; --gc-sections: of the C library and
    # runtime only what is used:
    $CC "$obj/harfbuzz.o" "$obj/harfbuzz_zdl.o" "$ZIGDOS/build/sdk-ports/lib/$arch/libfreetype.a" -Wl,--gc-sections -o "$obj/HARFBUZZ.ZDL"
    $STUBS HARFBUZZ "$FUNCS" "$obj/libharfbuzz.a"
    install_app "$obj/HARFBUZZ.ZDL" LIBS_3RD
    install_file "$obj/libharfbuzz.a" "sdk-ports/lib/$arch"
done
# The public headers, as HarfBuzz installs them (include/harfbuzz):
inc=$ZIGDOS/build/sdk-ports/include/harfbuzz
rm -rf "$inc"
mkdir -p "$inc"
for h in $(sed -n "/^hb_base_headers = files(/,/)/p" "$HARFBUZZ_SRC/src/meson.build" | grep -o "'[^']*\.h'" | tr -d "'") hb-ft.h hb-version.h; do
    cp "$HARFBUZZ_SRC/src/$h" "$inc/"
done
echo "Copied to build/sdk-ports/include/harfbuzz"
