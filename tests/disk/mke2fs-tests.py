#!/usr/bin/env python3
# MKE2FS test suite: each case types an MKE2FS
# command in QEMU, then checks the volume and the disk around it.
#   mke2fs-tests.py run
# Default metal x86_64; another edition (tests/common.py):
#   ZDOS_EDITION=bios ZDOS_ARCH=x86 python3 tests/disk/mke2fs-tests.py run
# The floppy and C: cases are BIOS's (a floppy drive, a FAT C:).
# The test disk's first volume is the edition's first test letter
# (BIOS E:, metal D:).
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import common as h  # noqa: E402

OUT = h.suite_dir("mke2fs-tests")
IMG = os.path.join(OUT, "images")
SHOTS = os.path.join(OUT, "shots")
SECTOR = h.SECTOR
DISK = h.TEST_DISK
TEST_LETTER = h.TEST_LETTER
FEATURES = {"filetype", "sparse_super", "large_file"}

GPT_SLOT1 = [(h.GPT_BASIC_DATA, 2048, 2048 + 32768 - 1, "test")]


def tiny_partition(path):
    # 64 KB: too small for ext2:
    h.marked()(path, [(0x83, 2048, 128)])
    return {"tables": {0}}


# CHECKING A NEW FILE SYSTEM

def run_tool(*args):
    p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return p.returncode, p.stdout


def verify_ext2(image, start, sectors, e):
    # As a list.
    problems = []
    vol = h.extract(image, start, sectors, image + ".ext2")
    try:
        rc, out = run_tool("e2fsck", "-fn", vol)
        if rc != 0:
            lines = [l for l in out.splitlines() if l.strip()]
            problems.append(f"e2fsck exit {rc}: " + "; ".join(lines[-4:]))
        rc, out = run_tool("dumpe2fs", "-h", vol)
        if rc != 0:
            return problems + ["dumpe2fs can't read it"]
        fields = dict(re.findall(r"^([^:\n]+):\s*(.*)$", out, re.M))
        bs = int(fields.get("Block size", "0"))
        blocks = int(fields.get("Block count", "0"))
        if bs != e["bs"]:
            problems.append(f"block size {bs}, expected {e['bs']}")
        label = fields.get("Filesystem volume name", "")
        if label in ("<none>",):
            label = ""
        if label != e.get("label", ""):
            problems.append(f"label {label!r}, expected {e.get('label', '')!r}")
        features = set(fields.get("Filesystem features", "").split())
        if not FEATURES <= features:
            problems.append(f"features {sorted(features)} lack {sorted(FEATURES - features)}")
        extra = features & {"has_journal", "extent", "extents", "64bit", "flex_bg", "metadata_csum"}
        if extra:
            problems.append(f"features it shouldn't have: {sorted(extra)}")
        # A last group too small for its overhead may be left out,
        # as Linux's mke2fs does:
        if bs and (blocks * bs > sectors * SECTOR or blocks * bs < sectors * SECTOR * 9 // 10):
            problems.append(f"{blocks} blocks of {bs} don't fit the {sectors}-sector partition")
        if e.get("hello"):
            # Its stdout alone: debugfs prints its version on stderr:
            p = subprocess.run(["debugfs", "-R", "cat /HELLO.TXT", vol], stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL)
            if not p.stdout.startswith(b"HELLO"):
                problems.append("HELLO.TXT missing or wrong")
    finally:
        os.remove(vol)
    return problems


def mbr_type(want):
    def check(image, layout):
        got = h.read_entries(h.read_sector(image, 0))[0]["type"]
        return [] if got == want else [f"MBR type {got:02X}, expected {want:02X}"]
    return check


def logical_type(image, layout):
    # Partition 3's entry, in the extended partition's first record:
    got = h.read_entries(h.read_sector(image, 34816))[0]["type"]
    return [] if got == 0x83 else [f"logical partition type {got:02X}, expected 83"]


def gpt_linux(image, layout):
    problems, entries = h.read_gpt(image, layout["gpt"])
    if not entries or entries[0] is None:
        return problems + ["GPT entry 1 is gone"]
    if entries[0][0] != h.GPT_LINUX:
        problems.append("GPT entry 1 is not of the Linux type")
    return problems


def no_table(image, layout):
    # The whole disk: no boot sector or table left in sector 0:
    sec = h.read_sector(image, 0)
    return [] if sec[510:512] != b"\x55\xaa" else ["sector 0 still ends in 55 AA"]


# CASES

def mke2fs_steps(args, wait=8, yes=True):
    return h.command(f"MKE2FS {args}", 3) + h.answer("y" if yes else "n", wait) + \
        [("shot", "01-mke2fs", "MKE2FS's summary, the question, and the result")]


def write_file(letter):
    # A file written from ZDOS on the new volume, read back with debugfs:
    return [("wait", 2)] + h.command("DRIVES", 3) + \
        [("shot", "02-drives", f"The new ext2 volume has a drive letter ({letter}: expected)")] + \
        h.command(f"ECHO HELLO > {letter}:\\HELLO.TXT", 3) + h.command(f"DIR {letter}:", 3) + \
        [("shot", "03-written", "HELLO.TXT is on the new volume")]


def ok_case(name, disk, args, expect, fs, wait=8, after=(), check=None):
    return {"name": name, "disk": disk, "steps": mke2fs_steps(args, wait) + list(after), "fs": fs,
            "expect": expect, "check": check}


def refused(name, disk, args, expect, yes=True, keep=None):
    steps = h.command(f"MKE2FS {args}", 3) + h.answer("y" if yes else "n", 3) + \
        [("shot", "01-refused", expect)]
    return {"name": name, "disk": disk, "steps": steps, "refused": True, "expect": expect + "; nothing is written",
            "keep": keep}


CASES = [
    ok_case("mbr", h.one_partition(0x06, 2048, 32768), f"{DISK} 1 -L ZDOSEXT",
            "MBR partition 1 (type 06): ext2 with 1 KB blocks, label ZDOSEXT, type set to 83; "
            "then ZDOS writes a file to it",
            dict(bs=1024, label="ZDOSEXT", hello=True), after=write_file(TEST_LETTER), check=mbr_type(0x83)),
    ok_case("block4096", h.one_partition(0x83, 2048, 32768), f"{DISK} 1 -b 4096",
            "-b 4096: 4 KB blocks", dict(bs=4096), check=mbr_type(0x83)),
    ok_case("block65536", h.one_partition(0x83, 2048, 64 * h.MB - 4096), f"{DISK} 1 -b 65536",
            "-b 65536: 64 KB blocks (the note about Linux on x86 shown)", dict(bs=65536), wait=12),
    ok_case("gpt", h.gpt_disk(GPT_SLOT1, 0), f"{DISK} 1 -L GPTEXT",
            "GPT partition 1 (basic data): ext2, its type becomes the Linux GUID, both GPT copies valid",
            dict(bs=1024, label="GPTEXT"), check=gpt_linux),
    ok_case("logical", h.with_logical, f"{DISK} 3",
            "logical partition 3: ext2 there, its type set to 83; partition 1 untouched",
            dict(bs=1024), check=logical_type),
    ok_case("whole-disk", h.whole_disk(32768), f"{DISK} 1 -L WHOLE",
            "a disk with no partition table: ext2 on the whole disk (no table written); ZDOS gives it a letter "
            "and writes a file to it",
            dict(bs=1024, label="WHOLE", hello=True), after=write_file(TEST_LETTER), check=no_table),
    ok_case("superfloppy", h.fat_superfloppy(32768), f"{DISK} 1",
            "a disk that is one FAT volume: ext2 on the whole disk, the FAT boot sector gone",
            dict(bs=1024), check=no_table),
    ok_case("letter", h.formatted_partition, f"{TEST_LETTER}: -L FROMFAT",
            f"MKE2FS {TEST_LETTER}: (by drive letter) over a FAT16 volume: ext2, type set to 83",
            dict(bs=1024, label="FROMFAT"), check=mbr_type(0x83)),
    refused("answer-no", h.one_partition(0x83, 2048, 32768), f"{DISK} 1", "N to the question", yes=False),
    refused("bad-block-size", h.one_partition(0x83, 2048, 32768), f"{DISK} 1 -b 3000",
            "-b 3000 is not a power of two"),
    refused("small-block-size", h.one_partition(0x83, 2048, 32768), f"{DISK} 1 -b 512",
            "-b 512 is below ext2's 1024"),
    refused("long-label", h.one_partition(0x83, 2048, 32768), f"{DISK} 1 -L ABCDEFGHIJKLMNOPQ",
            "a 17-character label"),
    refused("too-small", tiny_partition, f"{DISK} 1", "a 64 KB partition: too small for ext2"),
    refused("extended", h.with_logical, f"{DISK} 2", "partition 2 is the extended partition"),
    refused("past-end", h.one_partition(0x83, 2048, 200000), f"{DISK} 1",
            "the partition's entry goes past the end of the 64 MB disk (a damaged table, not a whole disk)"),
    refused("no-partition", h.one_partition(0x83, 2048, 32768), f"{DISK} 2", "disk 3 has one partition"),
    refused("no-table-part2", h.whole_disk(32768), f"{DISK} 2",
            "a disk with no partition table has only partition 1"),
    refused("gpt-no-header", h.gpt_no_header, f"{DISK} 1",
            "a protective MBR whose GPT header is missing: the partition table can't be read"),
    refused("floppy", h.one_partition(0x83, 2048, 32768), "A:", "floppies get FAT: MKE2FS refuses A:"),
    refused("boot-drive", h.one_partition(0x83, 2048, 32768), "C:", "C: is the drive ZDOS started from",
            keep="system"),
]
if h.EDITION != "bios":
    # No floppy drive; C: isn't a FAT volume read off an MBR:
    skipped = [c["name"] for c in CASES if c.get("floppy") or c.get("keep") == "system" or c["name"] == "floppy"]
    CASES = [c for c in CASES if c["name"] not in skipped]
    print(f"BIOS only, skipped: {', '.join(skipped)}")


def run_case(case):
    image = os.path.join(IMG, f"{case['name']}.img")
    if os.path.exists(image):
        os.remove(image)
    layout = case["disk"](image)
    system = h.SYSTEM_IMG
    if case.get("keep") == "system":
        # A copy of the system disk: C:'s boot sector shows it isn't
        # formatted (the boot itself writes C:, a home folder):
        system = h.copy_to(h.SYSTEM_IMG, os.path.join(IMG, f"{case['name']}-system.img"))
        c_start = h.read_entries(h.read_sector(system, 0))[0]["start"]
        system_before = h.read_sector(system, c_start)
    before = h.fingerprint(image)
    floppy_before = h.fingerprint(h.FLOPPY_IMG) if h.EDITION == "bios" else None
    sock = os.path.join(OUT, f"mon-{case['name']}.sock")
    args = h.qemu_args(sock, test=image, system=system, system_snapshot=system == h.SYSTEM_IMG)
    shots = h.run_qemu(args, case["steps"], os.path.join(SHOTS, case["name"]), sock)
    notes = []
    if case.get("refused"):
        passed = h.fingerprint(image) == before and (floppy_before is None or h.fingerprint(h.FLOPPY_IMG) == floppy_before)
        notes.append("disk unchanged" if passed else "the disk was CHANGED")
        if case.get("keep") == "system":
            same = h.read_sector(system, c_start) == system_before
            passed = passed and same
            notes.append("C: unchanged" if same else "C: was CHANGED")
            os.remove(system)
    else:
        start, sectors = layout["start"], layout["sectors"]
        problems = verify_ext2(image, start, sectors, case["fs"])
        passed = not problems
        notes.append("ext2 as expected, e2fsck clean" if not problems else "; ".join(problems))
        if not layout.get("no_marker"):
            changed = h.outside_changed(image, layout)
            passed = passed and not changed
            notes.append("nothing outside it changed" if not changed else
                         f"{len(changed)} sectors outside it changed (first {changed[:5]})")
        if case.get("check"):
            more = case["check"](image, layout)
            passed = passed and not more
            notes.append("; ".join(more) if more else "partition table as expected")
    return passed, "; ".join(notes), shots


def main():
    if len(sys.argv) != 2 or sys.argv[1] != "run":
        print("Usage: mke2fs-tests.py run")
        sys.exit(1)
    h.require_system()
    for tool in ("e2fsck", "dumpe2fs", "debugfs", "mkfs.fat"):
        if shutil.which(tool) is None:
            raise SystemExit(f"{tool} is missing (e2fsprogs, dosfstools)")
    os.makedirs(IMG, exist_ok=True)
    results = []
    for case in CASES:
        passed, detail, shots = run_case(case)
        results.append((case["name"], passed, case["expect"], detail, shots))
        print(f"{'PASS' if passed else 'FAIL'}  {case['name']}: {detail}", flush=True)
    h.write_results(os.path.join(OUT, "RESULTS.md"), "MKE2FS test results", results)
    sys.exit(1 if h.summary(results) else 0)


if __name__ == "__main__":
    main()
