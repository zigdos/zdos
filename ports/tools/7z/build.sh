#!/usr/bin/env bash
# 7-Zip: 7ZZ.APP, the console 7-Zip with all formats (RAR: unpacking).
# 7-Zip's own makefile.gcc builds a copy of its sources
# (SEVENZIP_SRC=...) in build/7z/tree, with 7z-zdos.patch.
#   build.sh [x86|x86_64|arm64]...   (none: all three)
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/tools/7z
SEVENZIP_SRC=${SEVENZIP_SRC:-$SRC_ROOT/7z}
BUILD=${SEVENZIP_BUILD:-$ZIGDOS/build/7z}
TREE=$BUILD/tree
[ -f "$SEVENZIP_SRC/CPP/7zip/Bundles/Alone2/makefile.gcc" ] || die "no 7-Zip in $SEVENZIP_SRC (SEVENZIP_SRC=...)"

# SOURCES
# 7-Zip's (times kept, writable), patched files fresh when changed:
PATCHED=$(sed -n 's|^+++ b/||p' "$PORT/7z-zdos.patch")
mkdir -p "$TREE"
excludes=()
for f in $PATCHED; do excludes+=(--exclude="/$f"); done
(cd "$SEVENZIP_SRC" && rsync -a --chmod=u+w "${excludes[@]}" ./ "$TREE/")
stale=0
for f in $PATCHED; do
    if [ ! -f "$TREE/$f" ] || [ "$SEVENZIP_SRC/$f" -nt "$TREE/$f" ] || [ "$PORT/7z-zdos.patch" -nt "$TREE/$f" ]; then stale=1; fi
done
if [ $stale = 1 ]; then
    for f in $PATCHED; do cp "$SEVENZIP_SRC/$f" "$TREE/$f" && chmod u+w "$TREE/$f"; done
    patch -s -d "$TREE" -p1 <"$PORT/7z-zdos.patch" || die "7z-zdos.patch doesn't apply to $SEVENZIP_SRC"
fi

# BUILD
# C only (no assembler); warnings not errors (a newer compiler's);
# no -lpthread -ldl (the SDK's C library has them); not stripped
# (zdos-cc --app keeps only what loads):
for arch in $(arches "$@"); do
    select_arch "$arch"
    obj=$BUILD/$arch
    mkdir -p "$obj"
    echo "=== 7ZZ.APP for $arch ==="
    (cd "$TREE/CPP/7zip/Bundles/Alone2" &&
        make -f makefile.gcc -j"$(cpus)" CC="$ZDOS_CC --arch=$arch" CXX="$SDK/bin/zdos-c++ --arch=$arch" \
            O="$obj" CFLAGS_WARN_WALL= LIB2= LFLAGS_STRIP= >"$obj/make.log" 2>&1) ||
        die "7-Zip's build failed: $obj/make.log"
    make_app "$obj/7zz" "$obj/7ZZ.APP"
    install_app "$obj/7ZZ.APP" APPS_3RD
done
