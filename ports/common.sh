# Shared by ports/*/*/build.sh. Written for bash 3.2 too (macOS).
set -euo pipefail

ZIGDOS=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SDK=$ZIGDOS/sdk
SRC_ROOT=${ZDOS_PORTS_SRC:-$(dirname "$ZIGDOS")}

die() {
    echo "$(basename "$0"): $*" >&2
    exit 1
}

# The arguments, or all three:
arches() {
    if [ $# -eq 0 ]; then
        echo x86 x86_64 arm64
    else
        for a in "$@"; do
            case $a in
                x86 | x86_64 | arm64) echo "$a" ;;
                *) die "unknown architecture $a (x86, x86_64, arm64)" ;;
            esac
        done
    fi
}

ZDOS_CC=$SDK/bin/zdos-cc
ZDOS_STUBS=$SDK/bin/zdos-stubs

# EDITIONS (a program runs on the UEFI and metal edition of its CPU
# alike), CC and STUBS (STUBS NAME LIST libNAME.a) for an architecture.
select_arch() {
    case $1 in
        x86) EDITIONS="bios-x86" ;;
        x86_64) EDITIONS="uefi-x86_64 metal-x86_64" ;;
        arm64) EDITIONS="uefi-arm64 metal-arm64" ;;
    esac
    CC="$ZDOS_CC --arch=$1"
    STUBS="$ZDOS_STUBS --arch=$1"
}

# Where they differ, keeping times, so make rebuilds only what changed.
sync_files() {
    mkdir -p "$2"
    for f in "$1"/*; do
        [ -f "$f" ] || continue
        cmp -s "$f" "$2/$(basename "$f")" 2>/dev/null || cp -p "$f" "$2/"
    done
}

# ELF -> the flat .APP ZDOS loads
make_app() {
    "$ZDOS_CC" --app "$1" "$2"
}

# install_file <file> <folder under build/> [<name>]
install_file() {
    mkdir -p "$ZIGDOS/build/$2"
    cp "$1" "$ZIGDOS/build/$2/${3:-$(basename "$1")}"
    echo "Copied to build/$2/${3:-$(basename "$1")}"
}

# install_app <file> APPS_3RD|GAMES [<name>]: into each edition's folder.
install_app() {
    local e
    for e in $EDITIONS; do
        install_file "$1" "$e/$2" ${3:+"$3"}
    done
}

# For make -j.
cpus() {
    getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4
}

# Another port built for $arch if missing (after select_arch):
#   need_port PORT STUBS.a [LIB.ZDL]   e.g. media/x264 libx264.a X264.ZDL
need_port() {
    local e build=
    [ -f "$ZIGDOS/build/sdk-ports/lib/$arch/$2" ] || build=1
    for e in ${3:+$EDITIONS}; do
        [ -f "$ZIGDOS/build/$e/LIBS_3RD/$3" ] || build=1
    done
    [ -z "$build" ] || "$ZIGDOS/ports/$1/build.sh" "$arch" ||
        die "ports/$1/build.sh $arch failed"
}

[ -f "$SDK/src/zdos.h" ] || die "zdos SDK not found in $SDK"
