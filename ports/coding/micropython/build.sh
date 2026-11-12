#!/usr/bin/env bash
# MicroPython: micropython.app. zdos/ is copied into the checkout
# (../micropython, MICROPYTHON=...) as ports/zdos and built there.
#   build.sh [x86|x86_64|arm64]...   (none: all three)
source "$(dirname "$0")/../../common.sh"
MICROPYTHON=${MICROPYTHON:-$SRC_ROOT/micropython}
[ -d "$MICROPYTHON/py" ] && [ -d "$MICROPYTHON/ports" ] || die "no MicroPython checkout in $MICROPYTHON (MICROPYTHON=...)"
TREE=$MICROPYTHON/ports/zdos
sync_files "$ZIGDOS/ports/coding/micropython/zdos" "$TREE"

for arch in $(arches "$@"); do
    select_arch "$arch"
    echo "=== micropython.app for $arch ==="
    log=$ZIGDOS/build/micropython/$arch.log
    mkdir -p "$(dirname "$log")"
    # One architecture must not reuse another's objects:
    make -C "$TREE" -j"$(cpus)" ZDOS_ARCH="$arch" BUILD="build-$arch" SDK="$SDK" >"$log" 2>&1 ||
        die "MicroPython build failed for $arch; see $log"
    make_app "$TREE/build-$arch/micropython.elf" "$TREE/build-$arch/micropython.app"
    install_app "$TREE/build-$arch/micropython.app" APPS_3RD
done
