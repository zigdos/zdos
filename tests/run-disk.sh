#!/bin/sh
# Runs the disk test suites one after another, in QEMU.
# Default metal x86_64; another edition (tests/common.py):
#   tests/run-disk.sh
#   ZDOS_EDITION=bios ZDOS_ARCH=x86 tests/run-disk.sh
# FDISK's suite is BIOS-only, CHKFS's and CHKAUTO's not on UEFI, the MFS
# power cuts not on UEFI (there the plain MFS suite runs): elsewhere
# they are skipped.
cd "$(dirname "$0")/disk" || exit 1
edition=${ZDOS_EDITION:-metal}

failed=
# suite SCRIPT [ARGS]: runs it, noting it when it fails:
suite() {
    python3 "$@" || failed="$failed $1"
    sleep 1
}

python3 chkdsk-tests.py make || exit 1
suite chkdsk-tests.py run
suite chkdsk-checks.py run
if [ "$edition" = bios ]; then suite fdisk-tests.py run; else echo "fdisk: BIOS only, skipped"; fi
suite format-tests.py run
suite mke2fs-tests.py run
suite fat-tests.py run
suite ext2-tests.py run
if [ "$edition" != uefi ]; then
    suite chkfs-tests.py
    suite chkauto-tests.py
else
    echo "chkfs, chkauto: not on UEFI, skipped"
fi
suite sys-tests.py
# The power cuts run the MFS suite first:
if [ "$edition" = uefi ]; then suite mfs-tests.py run; else suite mfs-reliability.py; fi

if [ -n "$failed" ]; then
    echo "run-disk: failed:$failed"
    exit 1
fi
echo "run-disk: all suites passed"
