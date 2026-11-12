#!/usr/bin/env python3
# chkdsk-checks.py run: two CHKDSK checks in QEMU (the images of
# chkdsk-tests.py make). Default metal x86_64; another edition:
#   ZDOS_EDITION=bios ZDOS_ARCH=x86 python3 tests/disk/chkdsk-checks.py run
#   date   FOUND.000\FILE0000.CHK from CHKDSK -F has a real date
#   bound  a first cluster past the volume's end doesn't touch the next
#          partition (filled with a marker)
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import common as h  # noqa: E402

OUT = h.suite_dir("chkdsk-checks")
IMG = os.path.join(OUT, "images")
SHOTS = os.path.join(OUT, "shots")
SECTOR = h.SECTOR
SRC = os.path.join(h.CHKDSK_IMAGES, "fat16-lost.img")
CLEAN = os.path.join(h.CHKDSK_IMAGES, "fat16-clean.img")


def date_of(raw):
    wtime, wdate = struct.unpack_from("<HH", raw, 22)
    return 1980 + (wdate >> 9), (wdate >> 5) & 15, wdate & 31, wtime


def real_date(raw):
    year, month, day, _ = date_of(raw)
    return 1 <= month <= 12 and 1 <= day <= 31 and year >= 2020


def check_date():
    # CHKDSK -F on a lost chain: the saved folder and file carry a real date:
    image = h.copy_to(SRC, os.path.join(IMG, "date.img"))
    steps = h.command(f"CHKDSK {h.TEST_DISK} 1", 6) + h.command(f"CHKDSK {h.TEST_DISK} 1 -F", 8) + \
        h.answer("y", 8) + [("shot", "01-repair", "Repairs: the lost chain saved as FOUND.000\\FILE0000.CHK")] + \
        h.answer("n", 3) + [("shot", "02-after", "No errors on the recheck")]
    run(image, steps, "date")
    v = h.Vol(image)
    found = v.find(h.name83("FOUND.000"))
    if found is None:
        return False, "FOUND.000 not found in the root directory"
    folder = v.read(found, 32)
    saved = v.find(h.name83("FILE0000.CHK"), v.first_cluster(found))
    if saved is None:
        return False, "FILE0000.CHK not found in FOUND.000"
    file = v.read(saved, 32)
    ok = folder[11] & 0x10 and real_date(folder) and real_date(file)
    fy, fm, fd, ft = date_of(folder)
    cy, cm, cd, _ = date_of(file)
    return bool(ok), (f"FOUND.000 {fy:04d}-{fm:02d}-{fd:02d} {ft >> 11:02d}:{(ft >> 5) & 63:02d}, "
                      f"FILE0000.CHK {cy:04d}-{cm:02d}-{cd:02d}")


def check_boundary():
    # A partition with a marker after it, and a damaged A.TXT past its end:
    image = os.path.join(IMG, "bound.img")
    clean = h.Vol(CLEAN)
    vol_sectors = clean.total
    part1, part2_start, part2_sectors = 2048, 2048 + vol_sectors, 4096
    marker = bytes([0xA5]) * SECTOR
    h.make_disk(image, part2_start + part2_sectors)
    with open(CLEAN, "rb") as src:
        h.write_sector(image, part1, src.read(vol_sectors * SECTOR))
    h.write_table(image, 0, [(0x06, part1, vol_sectors), (0x06, part2_start, part2_sectors)])
    h.write_sector(image, part2_start, marker * part2_sectors)
    # A.TXT's first cluster is past the last cluster of the volume:
    v = h.Vol(image, base=part1 * SECTOR)
    a = v.find(h.name83("A.TXT"))
    if a is None:
        raise SystemExit("A.TXT is not in the test image")
    v.set_first(a, v.clusters + 10)
    first = h.TEST_LETTER
    steps = [("wait", 2)] + h.command("DRIVES", 3) + \
        [("shot", "01-drives", f"The first partition of disk {h.TEST_DISK} has a letter ({first}: expected)")] + \
        h.command(f"TYPE {first}:\\A.TXT", 4) + \
        [("shot", "02-type", "Reading the damaged file: an error, no data from the next partition")] + \
        h.command(f"ECHO HELLO > {first}:\\A.TXT", 4) + [("shot", "03-write", "Writing the damaged file: refused")] + \
        h.command("DRIVES", 3) + [("shot", "04-next", "The next partition (the marker) is still listed as before")]
    run(image, steps, "bound")
    after = h.read_sector(image, part2_start, part2_sectors)
    changed = sum(1 for i in range(part2_sectors) if after[i * SECTOR:(i + 1) * SECTOR] != marker)
    return changed == 0, f"{changed} of {part2_sectors} sectors of the next partition changed"


def run(image, steps, name):
    sock = os.path.join(OUT, f"mon-{name}.sock")
    return h.run_qemu(h.qemu_args(sock, test=image), steps, os.path.join(SHOTS, name), sock)


def main():
    if len(sys.argv) != 2 or sys.argv[1] != "run":
        print("Usage: chkdsk-checks.py run")
        sys.exit(1)
    h.require(SRC, CLEAN, hint="make the CHKDSK test images first: chkdsk-tests.py make")
    h.require_system()
    os.makedirs(IMG, exist_ok=True)
    results = []
    for name, fn, expect in (
        ("date", check_date, "FOUND.000 and FILE0000.CHK carry a real date"),
        ("bound", check_boundary, "the next partition keeps its marker in every sector"),
    ):
        ok, detail = fn()
        results.append((name, ok, expect, detail, []))
        print(f"{'PASS' if ok else 'FAIL'}  {name}: {detail}", flush=True)
    h.write_results(os.path.join(OUT, "RESULTS.md"), "CHKDSK checks", results)
    sys.exit(1 if h.summary(results) else 0)


if __name__ == "__main__":
    main()
