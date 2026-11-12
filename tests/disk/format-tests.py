#!/usr/bin/env python3
# FORMAT test suite: each case types a FORMAT command in
# QEMU, then checks the layout, fsck.fat -n, that nothing outside the
# volume changed, and that a refused FORMAT changed nothing.
#   format-tests.py run
# Default metal x86_64; another edition (tests/common.py):
#   ZDOS_EDITION=bios ZDOS_ARCH=x86 python3 tests/disk/format-tests.py run
# The floppy and C: cases are BIOS's (a floppy drive, a FAT C:).
# Two cases need large sparse files under build/ (5 GB, over 2 TB).
# The test disk's first FAT partition is the edition's first test
# letter (BIOS E:, metal D:); the floppy A: (BIOS).
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import common as h  # noqa: E402

OUT = h.suite_dir("format-tests")
IMG = os.path.join(OUT, "images")
SHOTS = os.path.join(OUT, "shots")
SECTOR = h.SECTOR
MB = h.MB
DISK_SECTORS = h.DISK_SECTORS
DISK = h.TEST_DISK
TEST_LETTER = h.TEST_LETTER
FLOPPY_LETTER = "A"

HD = {"media": 0xF8, "spt": 63, "heads": 255}
# Sectors -> geometry and media byte:
FLOPPY = {
    320: {"spt": 8, "heads": 1, "media": 0xFE}, 360: {"spt": 9, "heads": 1, "media": 0xFC},
    640: {"spt": 8, "heads": 2, "media": 0xFF}, 720: {"spt": 9, "heads": 2, "media": 0xFD},
    1440: {"spt": 9, "heads": 2, "media": 0xF9}, 2400: {"spt": 15, "heads": 2, "media": 0xF9},
    2880: {"spt": 18, "heads": 2, "media": 0xF0}, 5760: {"spt": 36, "heads": 2, "media": 0xF0},
}


# TEST DISKS: the makers in common.py, and these

def sparse_partition(kind, disk_sectors):
    # Sparse, no marker, one partition from 1 MB to its end.
    def make(path):
        h.make_disk(path, disk_sectors)
        h.write_table(path, 0, [(kind, MB, disk_sectors - MB)])
        return {"start": MB, "sectors": disk_sectors - MB, "tables": {0}, "no_marker": True}
    return make


def foreign_signatures(path):
    # An ext2 magic at its start and ZFS uberblocks in its first
    # and last labels: FORMAT wipes them.
    make = h.one_partition(0x83, 2048, 32768)
    layout = make(path)
    sb = bytearray(h.read_sector(path, 2048 + 2))
    sb[56:58] = struct.pack("<H", 0xEF53)
    h.write_sector(path, 2048 + 2, bytes(sb))
    for lba in (2048 + 256, 2048 + 32768 - 512 + 256):  # labels 0 and 2 (their rings, 128 KB in)
        ub = bytearray(h.read_sector(path, lba))
        ub[0:8] = struct.pack("<Q", 0x00bab10c)
        h.write_sector(path, lba, bytes(ub))
    return layout


def over_2tb(path):
    # A little over 2 TB, no partition table (sparse; nothing written).
    h.make_disk(path, (1 << 32) + 1024 * MB)
    return {"start": 0, "sectors": (1 << 32) + 1024 * MB, "tables": set(), "no_marker": True}


def blank_floppy(path):
    h.make_disk(path, 2880)
    return {"start": 0, "sectors": 2880, "tables": set(), "no_marker": True}


def build_floppy(path):
    h.copy_to(h.FLOPPY_IMG, path)
    sectors = os.path.getsize(path) // SECTOR
    return {"start": 0, "sectors": sectors, "tables": set(), "no_marker": True}


# CHECKING A FORMATTED VOLUME

def fat_bytes(kind, clusters):
    entries = clusters + 2
    return {"fat12": (entries * 3 + 1) // 2, "fat16": entries * 2, "fat32": entries * 4}[kind]


def verify_volume(image, start, sectors, e, written=False):
    # Empty is right. written: ZDOS wrote a file there after FORMAT, so the
    # FAT, root and FSInfo's free count are not compared.
    problems = []

    def want(name, got, exp):
        if got != exp:
            problems.append(f"{name} {got!r}, expected {exp!r}")

    kind = e["kind"]
    fat32 = kind == "fat32"
    boot = h.read_sector(image, start)
    want("jump", boot[0], 0xEB)
    want("signature", boot[510:512], b"\x55\xaa")
    want("bytes per sector", h.u16(boot, 11), SECTOR)
    want("sectors per cluster", boot[13], e["spc"])
    want("reserved sectors", h.u16(boot, 14), 32 if fat32 else 1)
    want("FATs", boot[16], 2)
    want("root entries", h.u16(boot, 17), {"fat12": 224, "fat16": 512, "fat32": 0}[kind])
    if sectors <= 0xFFFF:
        want("total sectors (16-bit)", h.u16(boot, 19), sectors)
        want("total sectors (32-bit)", h.u32(boot, 32), 0)
    else:
        want("total sectors (16-bit)", h.u16(boot, 19), 0)
        want("total sectors (32-bit)", h.u32(boot, 32), sectors)
    want("media", boot[21], e["media"])
    want("sectors per track", h.u16(boot, 24), e["spt"])
    want("heads", h.u16(boot, 26), e["heads"])
    want("hidden sectors", h.u32(boot, 28), e["hidden"])
    label = e.get("label", "NO NAME").ljust(11).encode()
    if fat32:
        want("16-bit FAT size", h.u16(boot, 22), 0)
        want("root cluster", h.u32(boot, 44), 2)
        want("FSInfo sector", h.u16(boot, 48), 1)
        want("backup boot sector", h.u16(boot, 50), 6)
        want("extended signature", boot[66], 0x29)
        want("label in the boot sector", boot[71:82], label)
        want("type string", boot[82:90], b"FAT32   ")
    else:
        want("extended signature", boot[38], 0x29)
        want("label in the boot sector", boot[43:54], label)
        want("type string", boot[54:62], b"FAT12   " if kind == "fat12" else b"FAT16   ")
    if problems:
        return problems  # the rest reads the volume by this boot sector
    v = h.Vol(image, base=start * SECTOR)
    want("FAT type by cluster count", v.kind, kind)
    needed = (fat_bytes(kind, v.clusters) + SECTOR - 1) // SECTOR
    if not needed <= v.fat_sectors <= needed + 1:
        problems.append(f"FAT size {v.fat_sectors} sectors for {v.clusters} clusters (needs {needed})")
    # The reserved entries, then free clusters; both copies the same:
    fat1 = v.read(v.reserved * SECTOR, v.fat_sectors * SECTOR)
    fat2 = v.read((v.reserved + v.fat_sectors) * SECTOR, v.fat_sectors * SECTOR)
    want("FAT copies equal", fat1 == fat2, True)
    media = e["media"]
    head = {
        "fat12": bytes([media, 0xFF, 0xFF]),
        "fat16": bytes([media, 0xFF, 0xFF, 0xFF]),
        "fat32": struct.pack("<III", 0x0FFFFF00 | media, 0x0FFFFFFF, 0x0FFFFFFF),
    }[kind]
    want("FAT reserved entries", fat1[:len(head)], head)
    if not written:
        want("FAT free after them", fat1[len(head):] == bytes(len(fat1) - len(head)), True)
    # The label entry first (unless there is no label), then empty:
    if fat32:
        root = v.read(v.data_start * SECTOR, v.spc * SECTOR)
    else:
        root = v.read((v.reserved + 2 * v.fat_sectors) * SECTOR, v.root_sectors * SECTOR)
    if e.get("label", "NO NAME") == "NO NAME":
        if not written:
            want("root directory empty", root == bytes(len(root)), True)
    else:
        want("label entry", (root[:11], root[11]), (label, 0x08))
        if not written:
            want("root directory empty after the label", root[32:] == bytes(len(root) - 32), True)
    if fat32:
        info = h.read_sector(image, start + 1)
        want("FSInfo lead signature", h.u32(info, 0), 0x41615252)
        want("FSInfo signature", h.u32(info, 484), 0x61417272)
        if not written:
            want("FSInfo free clusters", h.u32(info, 488), v.clusters - 1)
            want("FSInfo next free", h.u32(info, 492), 3)
        want("FSInfo trail signature", h.u32(info, 508), 0xAA550000)
        want("backup boot sector", h.read_sector(image, start + 6), boot)
    return problems


# CASES

def format_steps(args, wait=8, yes=True):
    return h.command(f"FORMAT {args}", 3) + h.answer("y" if yes else "n", wait) + \
        [("shot", "01-format", "FORMAT's summary, the question, and the result")]


def checkdisk(disk, part, wait=15):
    return h.command(f"CHKDSK {disk} {part}", wait) + [("shot", "02-chkdsk", "CHKDSK on the new volume: no errors")]


def write_file(letter):
    # A file written from ZDOS on the new volume, read back with mtools:
    return [("wait", 2)] + h.command("DRIVES", 3) + \
        [("shot", "03-drives", f"The new volume has a drive letter ({letter}: expected)")] + \
        h.command(f"ECHO HELLO > {letter}:\\HELLO.TXT", 3) + h.command(f"DIR {letter}:", 3) + \
        [("shot", "04-written", "HELLO.TXT is on the new volume")]


def ok_case(name, disk, args, expect, volume, wait=8, after=(), writes=False, floppy=False, check=None):
    # check(image, layout): more problems to look for, as a list.
    return {"name": name, "disk": disk, "steps": format_steps(args, wait) + list(after), "volume": volume,
            "expect": expect, "writes": writes, "floppy": floppy, "check": check}


# MORE CHECKS AFTER A FORMAT

def mbr_type(want):
    def check(image, layout):
        got = h.read_entries(h.read_sector(image, 0))[0]["type"]
        return [] if got == want else [f"MBR type {got:02X}, expected {want:02X}"]
    return check


def gpt_type(slot, want):
    def check(image, layout):
        problems, entries = h.read_gpt(image, layout["gpt"])
        if slot >= len(entries) or entries[slot] is None:
            return problems + [f"GPT entry {slot + 1} is gone"]
        if entries[slot][0] != want:
            problems.append(f"GPT entry {slot + 1} has another type")
        return problems
    return check


def no_marker_inside(image, layout):
    left = h.marked_inside(image, layout["start"], layout["sectors"])
    return [] if not left else [f"{len(left)} sectors of the volume not zeroed (first {left[:5]})"]


def no_foreign(image, layout):
    problems = mbr_type(0x06)(image, layout)
    if h.u16(h.read_sector(image, 2048 + 2), 56) == 0xEF53:
        problems.append("the ext2 superblock magic is still there")
    for lba in (2048 + 256, 2048 + 32768 - 512 + 256):
        if h.read_sector(image, lba)[:8] == struct.pack("<Q", 0x00bab10c):
            problems.append(f"a ZFS uberblock is still at sector {lba}")
    return problems


GPT_SLOT1 = [(h.GPT_LINUX, 2048, 2048 + 32768 - 1, "test")]
GPT_SLOT2 = [None, (h.GPT_LINUX, 2048, 2048 + 32768 - 1, "test")]


def refused(name, disk, args, expect, yes=True, floppy=False, keep=None):
    # FORMAT says why and writes nothing (when it asks, it is answered):
    steps = h.command(f"FORMAT {args}", 3) + (h.answer("y" if yes else "n", 3)) + \
        [("shot", "01-refused", expect)]
    return {"name": name, "disk": disk, "steps": steps, "refused": True, "expect": expect + "; nothing is written",
            "floppy": floppy, "keep": keep}


CASES = [
    ok_case("fat16", h.one_partition(0x06, 2048, 32768), f"{DISK} 1 -L TESTVOL",
            "FAT16, 512-byte clusters, label TESTVOL, hidden sectors 2048, hard disk geometry",
            dict(kind="fat16", spc=1, label="TESTVOL", hidden=2048, **HD),
            after=checkdisk(DISK, 1) + write_file(TEST_LETTER), writes=True),
    ok_case("fat16-cluster", h.one_partition(0x06, 2048, 32768), f"{DISK} 1 -C 2048",
            "FAT16 with 2 KB clusters (-C 2048), no label",
            dict(kind="fat16", spc=4, hidden=2048, **HD), after=checkdisk(DISK, 1)),
    ok_case("fat16-auto", h.one_partition(0x06, 2048, 63 * MB), f"{DISK} 1",
            "a 63 MB partition without -T: FAT16 with 1 KB clusters",
            dict(kind="fat16", spc=2, hidden=2048, **HD), after=checkdisk(DISK, 1)),
    ok_case("fat12-auto", h.one_partition(0x01, 2048, 4096), f"{DISK} 1 -L SMALL",
            "a 2 MB partition without -T: FAT12, 512-byte clusters, 224 root entries",
            dict(kind="fat12", spc=1, label="SMALL", hidden=2048, **HD), after=checkdisk(DISK, 1)),
    ok_case("fat32", h.one_partition(0x0C, 2048, 48 * MB), f"{DISK} 1 -T 32 -L BIG32",
            "a 48 MB partition with -T 32: FAT32, 512-byte clusters, FSInfo and backup boot sector",
            dict(kind="fat32", spc=1, label="BIG32", hidden=2048, **HD), wait=15,
            after=checkdisk(DISK, 1, 30) + write_file(TEST_LETTER), writes=True),
    ok_case("fat32-auto", sparse_partition(0x0C, 5 * 1024 * MB), f"{DISK} 1",
            "a 5 GB partition without -T: FAT16 doesn't fit, so FAT32 with 4 KB clusters",
            dict(kind="fat32", spc=8, hidden=2048, **HD), wait=120),
    ok_case("logical", h.with_logical, f"{DISK} 3 -L LOGICAL",
            "partition 3 (logical): FAT16, hidden sectors 36864 (its start on the disk); partition 1 untouched",
            dict(kind="fat16", spc=1, label="LOGICAL", hidden=36864, **HD), after=checkdisk(DISK, 3)),
    ok_case("esp", h.one_partition(0xEF, 2048, 32768), f"{DISK} 1",
            "an EFI system partition: the warning, then (Y) formatted as FAT16; its type stays EF",
            dict(kind="fat16", spc=1, hidden=2048, **HD), check=mbr_type(0xEF)),
    ok_case("gpt", h.gpt_disk(GPT_SLOT1, 0), f"{DISK} 1 -L GPTVOL",
            "GPT partition 1 (type Linux): FAT16, hidden sectors 2048; its type becomes Microsoft basic data, "
            "both GPT copies with valid CRCs",
            dict(kind="fat16", spc=1, label="GPTVOL", hidden=2048, **HD),
            after=checkdisk(DISK, 1), check=gpt_type(0, h.GPT_BASIC_DATA)),
    ok_case("gpt-slot2", h.gpt_disk(GPT_SLOT2, 1), f"{DISK} 2",
            "GPT entry 1 empty, the partition in entry 2: it is partition 2 (numbered by slot)",
            dict(kind="fat16", spc=1, hidden=2048, **HD), check=gpt_type(1, h.GPT_BASIC_DATA)),
    ok_case("mbr-type", foreign_signatures, f"{DISK} 1",
            "a Linux partition (83) with an ext2 superblock and ZFS labels: FAT16, type set to 06, "
            "the old signatures wiped",
            dict(kind="fat16", spc=1, hidden=2048, **HD), check=no_foreign),
    ok_case("type-kept", h.one_partition(0x0E, 2048, 32768), f"{DISK} 1",
            "a FAT16 LBA partition (0E): a type that fits FAT16 is kept",
            dict(kind="fat16", spc=1, hidden=2048, **HD), check=mbr_type(0x0E)),
    ok_case("hidden-type", h.one_partition(0x1B, 2048, 32768), f"{DISK} 1",
            "a hidden FAT32 partition (1B) formatted as FAT16: hidden FAT16 (16)",
            dict(kind="fat16", spc=1, hidden=2048, **HD), check=mbr_type(0x16)),
    ok_case("full", h.one_partition(0x06, 2048, 32768), f"{DISK} 1 -F",
            "-F (full): every sector of the volume written, none keeps the marker",
            dict(kind="fat16", spc=1, hidden=2048, **HD), wait=20, check=no_marker_inside),
    ok_case("superfloppy", h.fat_superfloppy(32768), f"{DISK} 1 -L SUPER2",
            "a disk that is one FAT volume (no partition table; its boot sector ends in 55 AA): "
            "the whole disk reformatted, hidden 0",
            dict(kind="fat16", spc=1, label="SUPER2", hidden=0, **HD), after=checkdisk(DISK, 1)),
    ok_case("whole-disk", h.whole_disk(2880), f"{DISK} 1",
            "a disk with no partition table (not removable): the whole disk as FAT12, hard disk geometry, hidden 0",
            dict(kind="fat12", spc=1, hidden=0, **HD), after=checkdisk(DISK, 1, 8)),
    ok_case("letter", h.formatted_partition, f"{TEST_LETTER}: -L LETTER",
            f"FORMAT {TEST_LETTER}: (by drive letter) over a mkfs.fat volume: FAT16, hidden sectors 2048, label LETTER",
            dict(kind="fat16", spc=1, label="LETTER", hidden=2048, **HD), after=checkdisk(DISK, 1)),
    ok_case("floppy-blank", blank_floppy, f"{FLOPPY_LETTER}:",
            "a blank 1.44 MB floppy: FAT12, 18 sectors per track, 2 heads, media F0, 224 root entries",
            dict(kind="fat12", spc=1, hidden=0, **FLOPPY[2880]),
            after=checkdisk(h.FLOPPY_DISK, 1, 8), floppy=True),
    ok_case("floppy", build_floppy, f"{FLOPPY_LETTER}: -L FLOPPY",
            "the build's floppy reformatted: its size's floppy geometry and media byte, label FLOPPY",
            None, after=checkdisk(h.FLOPPY_DISK, 1, 8), floppy=True),
    refused("answer-no", h.one_partition(0x06, 2048, 32768), f"{DISK} 1", "N to the question", yes=False),
    refused("fat12-too-big", h.one_partition(0x06, 2048, 32768), f"{DISK} 1 -T 12",
            "-T 12 on 16 MB with 512-byte clusters: too many clusters for FAT12"),
    refused("fat32-too-small", h.one_partition(0x06, 2048, 32768), f"{DISK} 1 -T 32",
            "-T 32 on 16 MB: too few clusters for FAT32"),
    refused("bad-cluster", h.one_partition(0x06, 2048, 32768), f"{DISK} 1 -C 1000",
            "-C 1000 is not a power of two"),
    refused("long-label", h.one_partition(0x06, 2048, 32768), f"{DISK} 1 -L ABCDEFGHIJKL",
            "a 12-character label"),
    refused("extended", h.with_logical, f"{DISK} 2", "partition 2 is the extended partition"),
    refused("gpt-no-header", h.gpt_no_header, f"{DISK} 1",
            "a protective MBR whose GPT header is missing: the partition table can't be read"),
    refused("gpt-empty-slot", h.gpt_disk(GPT_SLOT2, 1), f"{DISK} 1", "GPT entry 1 is empty: no partition 1"),
    refused("superfloppy-part2", h.fat_superfloppy(), f"{DISK} 2",
            "a FAT volume with no partition table (its boot sector ends in 55 AA) has only partition 1"),
    refused("past-end", h.one_partition(0x06, 2048, 200000), f"{DISK} 1",
            "the partition's entry goes past the end of the 64 MB disk"),
    refused("no-partition", h.one_partition(0x06, 2048, 32768), f"{DISK} 2", "disk 3 has one partition"),
    refused("no-table-part2", h.whole_disk(2880), f"{DISK} 2", "a disk with no partition table has only partition 1"),
    refused("over-2tb", over_2tb, f"{DISK} 1", "a volume of more than 2^32 sectors"),
    refused("boot-drive", h.one_partition(0x06, 2048, 32768), "C:", "C: is the drive ZDOS started from",
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
    floppy = image if case["floppy"] else h.FLOPPY_IMG
    test = None if case["floppy"] else image
    before = h.fingerprint(image)
    sock = os.path.join(OUT, f"mon-{case['name']}.sock")
    args = h.qemu_args(sock, test=test, system=system, system_snapshot=system == h.SYSTEM_IMG,
                       floppy=floppy, floppy_snapshot=not case["floppy"])
    shots = h.run_qemu(args, case["steps"], os.path.join(SHOTS, case["name"]), sock)
    notes = []
    if case.get("refused"):
        passed = h.fingerprint(image) == before
        notes.append("disk unchanged" if passed else "the disk was CHANGED")
        if case.get("keep") == "system":
            same = h.read_sector(system, c_start) == system_before
            passed = passed and same
            notes.append("C: unchanged" if same else "C: was CHANGED")
            os.remove(system)
    else:
        start, sectors = layout["start"], layout["sectors"]
        expect = case["volume"] or dict(kind="fat12", spc=1 if sectors * SECTOR <= 2 << 20 else 2,
                                        label="FLOPPY", hidden=0, **FLOPPY.get(sectors, HD))
        problems = verify_volume(image, start, sectors, expect, written=case["writes"])
        passed = not problems
        notes.append("volume as expected" if not problems else "; ".join(problems))
        if not layout.get("no_marker"):
            changed = h.outside_changed(image, layout)
            passed = passed and not changed
            notes.append("nothing outside it changed" if not changed else
                         f"{len(changed)} sectors outside it changed (first {changed[:5]})")
        if case.get("check"):
            more = case["check"](image, layout)
            passed = passed and not more
            notes.append("; ".join(more) if more else "partition table and signatures as expected")
        if not problems:
            ok, text = h.fsck(image, start, sectors)
            passed = passed and ok is not False
            notes.append(f"fsck.fat: {text}")
        if case["writes"]:
            data = h.mtools_read(image, start, "HELLO.TXT")
            if data is None:
                notes.append("mtools not installed: HELLO.TXT not checked")
            else:
                written = data.startswith(b"HELLO")
                passed = passed and written
                notes.append("HELLO.TXT reads back" if written else "HELLO.TXT missing or wrong")
    if os.path.getsize(image) > (1 << 30):
        os.remove(image)  # the large sparse disks are not kept
    return passed, "; ".join(notes), shots


def main():
    if len(sys.argv) != 2 or sys.argv[1] != "run":
        print("Usage: format-tests.py run")
        sys.exit(1)
    h.require_system()
    os.makedirs(IMG, exist_ok=True)
    results = []
    for case in CASES:
        passed, detail, shots = run_case(case)
        results.append((case["name"], passed, case["expect"], detail, shots))
        print(f"{'PASS' if passed else 'FAIL'}  {case['name']}: {detail}", flush=True)
    h.write_results(os.path.join(OUT, "RESULTS.md"), "FORMAT test results", results)
    sys.exit(1 if h.summary(results) else 0)


if __name__ == "__main__":
    main()
