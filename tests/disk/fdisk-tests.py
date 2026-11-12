#!/usr/bin/env python3
# FDISK test suite (BIOS only: bios x86 is its default): each case types FDISK's keys in QEMU,
# then checks the partition table on the image.
#   fdisk-tests.py run   (after chkdsk-tests.py make)
#   ZDOS_EDITION=bios ZDOS_ARCH=x86 python3 tests/disk/fdisk-tests.py run
# The 2 TB case needs a file system under build/ with large sparse
# files (ext4, xfs, btrfs).
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
# BIOS only (the floppy, a FAT C:): its default edition
if "ZDOS_EDITION" not in os.environ and "ZDOS_ARCH" not in os.environ:
    os.environ.update(ZDOS_EDITION="bios", ZDOS_ARCH="x86")
import common as h  # noqa: E402

h.only("bios-x86")

OUT = h.suite_dir("fdisk-tests")
IMG = os.path.join(OUT, "images")
SHOTS = os.path.join(OUT, "shots")
SECTOR = h.SECTOR
MB = 2048  # sectors
DISK_SECTORS = 64 * MB  # the blank test disk: 64 MB
DISK = h.TEST_DISK

# A FAT16 superfloppy: its boot sector stands for an old file system
# left on the disk.
OLD_FAT = os.path.join(h.CHKDSK_IMAGES, "fat16-clean.img")


# TEST DISKS

def blank(path):
    h.make_disk(path, DISK_SECTORS)


def old_fat_at(lba):
    # An old FAT boot sector at lba, where a new partition will start.
    def make(path):
        blank(path)
        h.write_sector(path, lba, h.read_sector(OLD_FAT, 0))
    return make


def old_record_at(lba):
    # A stale boot record at lba: 55 AA, a FAT16 entry and a link.
    def make(path):
        blank(path)
        h.write_table(path, lba, [(0x06, 2048, 4096), (0x05, 8192, 4096)])
    return make


def superfloppy(path):
    # One FAT volume, no partition table.
    h.copy_to(OLD_FAT, path)


def foreign_superfloppy(oem):
    # Sector 0 an NTFS or exFAT boot sector: it ends in 55 AA, but its boot
    # code is no table.
    def make(path):
        blank(path)
        sec = bytearray(h.read_sector(path, 0))
        sec[0:3] = b"\xeb\x52\x90"
        sec[3:11] = oem
        sec[446:510] = bytes((i * 7 + 0x41) & 0xFF for i in range(64))  # boot code
        sec[510:512] = b"\x55\xaa"
        h.write_sector(path, 0, bytes(sec))
    return make


def gpt(path):
    blank(path)
    h.write_table(path, 0, [(0xEE, 1, DISK_SECTORS - 1)])


BIG_FIRST = (1 << 32) - 2048  # the first partition ends at sector 2^32


def big(path):
    # A little over 2 TB (sparse): one partition up to sector 2^32, so the
    # next would start past an MBR entry's 32-bit start.
    h.make_disk(path, (1 << 32) + 1024 * MB)
    h.write_table(path, 0, [(0x06, 2048, BIG_FIRST)])


# FDISK'S KEYS

def fdisk(disk=DISK):
    return h.command(f"FDISK {disk}", 4)


def menu(choice):
    return h.answer(choice, 1)


def primary(kind="", size=""):
    # "1" is primary in both questions FDISK asks. kind: the type's number
    # in the list ("" is FAT16), or ("5", "0B") for a hex type; size in MB
    # ("" is all the free space).
    kind_steps = h.answer(kind[0], 1) + h.answer(kind[1], 1) if isinstance(kind, tuple) else h.answer(kind, 1)
    return menu("1") + h.answer("1", 1) + kind_steps + h.answer(size, 3)


def extended(ext_size="", kind="", size=""):
    # Extended (asked only while there is none): its size, then its first
    # logical partition's type and size.
    return menu("1") + h.answer("2", 1) + h.answer(ext_size, 1) + h.answer(kind, 1) + h.answer(size, 3)


def logical(kind="", size=""):
    # With an extended partition "2" is logical.
    return menu("1") + h.answer("2", 1) + h.answer(kind, 1) + h.answer(size, 3)


def delete(num):
    return menu("3") + h.answer(str(num), 1) + h.answer("y", 2)


def active(num):
    return menu("2") + h.answer(str(num), 2)


def quit_fdisk():
    return menu("0") + [("wait", 1)]


def shot(name, note):
    return [("shot", name, note)]


# CHECKS: each gets the case's context (prim, logical, image, before:
# the sectors saved before the run) and returns (passed, detail)

def expect_table(prim=(), logical=()):
    # prim: (slot, type, start, sectors[, status]); other slots empty.
    # logical: (ebr, type, start_rel, sectors), the whole chain in order.
    def check(ctx):
        ok = True
        wanted = {p[0]: p for p in prim}
        for slot, e in enumerate(ctx["prim"]):
            if slot not in wanted:
                ok = ok and e["type"] == 0
                continue
            _, kind, start, sectors, *status = wanted[slot]
            ok = ok and (e["type"], e["start"], e["sectors"]) == (kind, start, sectors)
            if status:
                ok = ok and e["status"] == status[0]
        got = [(x["ebr"], x["type"], x["start_rel"], x["sectors"]) for x in ctx["logical"]]
        ok = ok and got == list(logical)
        return ok, h.describe_table(ctx["prim"], ctx["logical"])
    return check


def all_of(*checks):
    def check(ctx):
        ok, details = True, []
        for c in checks:
            passed, detail = c(ctx)
            ok = ok and passed
            if detail not in details:
                details.append(detail)
        return ok, "; ".join(details)
    return check


def unchanged(which, lba):
    # A sector saved before the run must be the same after it.
    def check(ctx):
        same = h.read_sector(ctx[which], lba) == ctx["before"][(which, lba)]
        return same, f"{which} sector {lba} " + ("unchanged" if same else "CHANGED")
    return check


def zeroed(lba):
    def check(ctx):
        zero = h.read_sector(ctx["image"], lba) == bytes(SECTOR)
        return zero, f"sector {lba} " + ("cleared" if zero else "not cleared")
    return check


def boot_code(which):
    # The first 440 bytes are the boot code; the table and disk
    # signature are kept; the boot signature is 55 AA.
    def check(ctx):
        sec = h.read_sector(ctx[which], 0)
        old = ctx["before"][(which, 0)]
        with open(h.MBR_BIN, "rb") as f:
            code = f.read(440)
        ok = sec[:440] == code and sec[440:510] == old[440:510] and sec[510:512] == b"\x55\xaa"
        return ok, f"{which} MBR: " + ("boot code written, table kept" if ok else "not as expected")
    return check


def record(lba, entry1, entry2):
    # Entries 1 and 2 as (type, start, sectors); None for an empty entry.
    def check(ctx):
        sec = h.read_sector(ctx["image"], lba)
        e = h.read_entries(sec)
        got1 = None if e[0]["type"] == 0 else (e[0]["type"], e[0]["start"], e[0]["sectors"])
        got2 = None if e[1]["type"] == 0 else (e[1]["type"], e[1]["start"], e[1]["sectors"])
        ok = sec[510:512] == b"\x55\xaa" and got1 == entry1 and got2 == entry2
        return ok, f"record {lba}: entry 1 {got1}, entry 2 {got2}"
    return check


# CASES: a 64 MB blank disk, the first partition at 1 MB, so "all" is
# 63 MB
ALL = DISK_SECTORS - MB  # 129024
TEN = 10 * MB

# Two 10 MB logical partitions in an extended one over the whole disk:
# boot records at 2048 and 24576, partitions 1 MB after them.
TWO_LOGICAL = fdisk() + extended("", "", "10") + logical("", "10")
THREE_LOGICAL = TWO_LOGICAL + logical("", "10")
L1 = (2048, 0x06, MB, TEN)
L2 = (24576, 0x06, MB, TEN)
L3 = (47104, 0x06, MB, TEN)
EXT_ALL = (0, 0x0F, 2048, ALL)

CASES = [
    {
        "name": "primary",
        "steps": fdisk() + primary() + shot("01-made", "The new partition is listed") + quit_fdisk(),
        "check": expect_table(prim=[(0, 0x06, 2048, ALL)]),
        "expect": "entry 1: type 06 (FAT16), start 2048, all the disk after it",
    },
    {
        "name": "primary-size",
        "steps": fdisk() + primary("", "20") + primary() + shot("01-made", "Two primary partitions") + quit_fdisk(),
        "check": expect_table(prim=[(0, 0x06, 2048, 20 * MB), (1, 0x06, 43008, DISK_SECTORS - 43008)]),
        "expect": "entry 1: 20 MB from 2048; entry 2: from 43008 (the next 1 MB boundary) to the end",
    },
    {
        "name": "type-linux",
        "steps": fdisk() + primary("4") + quit_fdisk(),
        "check": expect_table(prim=[(0, 0x83, 2048, ALL)]),
        "expect": "entry 1 has type 83 (Linux)",
    },
    {
        "name": "type-hex",
        "steps": fdisk() + primary(("5", "0B")) + quit_fdisk(),
        "check": expect_table(prim=[(0, 0x0B, 2048, ALL)]),
        "expect": "entry 1 has type 0B, typed in hex",
    },
    {
        "name": "type-hex-refused",
        "steps": fdisk() + menu("1") + h.answer("1", 1) + h.answer("5", 1) + h.answer("0F", 2) +
                 shot("01-refused", "Type 0F refused: it is an extended type") + quit_fdisk(),
        "check": expect_table(),
        "expect": "type 0F is refused for a new partition; the table stays empty",
    },
    {
        "name": "delete",
        "steps": fdisk() + primary() + delete(1) + shot("01-deleted", "No partitions left") + quit_fdisk(),
        "check": expect_table(),
        "expect": "the table is empty",
    },
    {
        "name": "delete-declined",
        "steps": fdisk() + primary() + menu("3") + h.answer("1", 1) + h.answer("n", 2) +
                 shot("01-kept", "Nothing was changed") + quit_fdisk(),
        "check": expect_table(prim=[(0, 0x06, 2048, ALL)]),
        "expect": "N to the question: the partition is kept",
    },
    {
        "name": "active",
        "steps": fdisk() + primary() + active(1) + shot("01-active", "Partition 1 is the active partition") +
                 quit_fdisk(),
        "check": expect_table(prim=[(0, 0x06, 2048, ALL, 0x80)]),
        "expect": "entry 1 is active (status 80)",
    },
    {
        "name": "active-switch",
        "steps": fdisk() + primary("", "20") + primary() + active(1) + active(2) +
                 shot("01-active", "Partition 2 is the active one") + quit_fdisk(),
        "check": expect_table(prim=[(0, 0x06, 2048, 20 * MB, 0x00), (1, 0x06, 43008, DISK_SECTORS - 43008, 0x80)]),
        "expect": "only entry 2 is active: making it active clears entry 1's flag",
    },
    {
        "name": "active-extended-refused",
        "steps": fdisk() + extended() + active(1) + active(2) +
                 shot("01-refused", "Neither the extended nor a logical partition can be active") + quit_fdisk(),
        "check": expect_table(prim=[EXT_ALL + (0x00,)], logical=[(2048, 0x06, MB, ALL - MB)]),
        "expect": "no entry is made active: the extended partition (1) and the logical one (2) are refused",
    },
    {
        "name": "stale",
        "disk": old_fat_at(2048),
        "steps": fdisk() + primary() + shot("01-made", "The new partition has no drive letter until FORMAT") +
                 quit_fdisk() + h.command("DRIVES", 3) +
                 shot("02-drives", "The new partition is not listed (no letter until FORMAT)"),
        "check": all_of(expect_table(prim=[(0, 0x06, 2048, ALL)]), zeroed(2048)),
        "expect": "entry 1 as in the primary case, and its first sector cleared (no old file system left there)",
    },
    {
        "name": "logical",
        "steps": fdisk() + extended() + shot("01-logical", "Extended and logical partitions listed") + quit_fdisk(),
        "check": expect_table(prim=[EXT_ALL], logical=[(2048, 0x06, MB, ALL - MB)]),
        "expect": "an extended partition at 2048 holding one FAT16 logical partition whose boot record is at 2048",
    },
    {
        # 55 AA and an entry at 446 where the extended partition starts must
        # not be read as a boot record. The logical partition is cancelled
        # (type 9 is not in the list), so only the clearing writes there.
        "name": "extended-over-old-record",
        "disk": old_record_at(2048),
        "steps": fdisk() + menu("1") + h.answer("2", 1) + h.answer("", 1) + h.answer("9", 2) +
                 shot("01-extended", "The extended partition alone, no logical partitions") + quit_fdisk(),
        "check": all_of(expect_table(prim=[EXT_ALL]), zeroed(2048)),
        "expect": "an empty extended partition: no logical partition read from the old sector, which is cleared",
    },
    {
        "name": "logical-two",
        "steps": TWO_LOGICAL + shot("01-two", "Two logical partitions") + quit_fdisk(),
        "check": all_of(expect_table(prim=[EXT_ALL], logical=[L1, L2]),
                        record(2048, (0x06, MB, TEN), (0x05, 22528, MB + TEN))),
        "expect": "records at 2048 and 24576; the first links to the second (start 22528 from the extended partition)",
    },
    {
        "name": "primary-then-extended",
        "steps": fdisk() + primary("", "20") + extended() + shot("01-made", "Primary, extended, logical") +
                 quit_fdisk(),
        "check": expect_table(prim=[(0, 0x06, 2048, 20 * MB), (1, 0x0F, 43008, DISK_SECTORS - 43008)],
                              logical=[(43008, 0x06, MB, DISK_SECTORS - 43008 - MB)]),
        "expect": "a 20 MB primary partition, then the extended partition from 43008 with one logical partition",
    },
    {
        # The chain is read from the extended partition's start: when the first
        # logical goes, a record there must still lead to the others.
        "name": "delete-first-logical",
        "steps": TWO_LOGICAL + delete(2) + shot("01-deleted", "The second logical partition is still listed") +
                 quit_fdisk(),
        "check": all_of(expect_table(prim=[EXT_ALL], logical=[L2]),
                        record(2048, None, (0x05, 22528, MB + TEN))),
        "expect": "the logical partition at 24576 is kept; the record at 2048 has an empty entry 1 and links to it",
    },
    {
        "name": "delete-first-then-create",
        "steps": TWO_LOGICAL + delete(2) + logical("", "10") + shot("01-made", "Two logical partitions again") +
                 quit_fdisk(),
        "check": all_of(expect_table(prim=[EXT_ALL], logical=[L2, L3]),
                        record(2048, None, (0x05, 22528, MB + TEN))),
        "expect": "after deleting the first, a new logical partition goes after the last (47104); the chain still starts at 2048",
    },
    {
        "name": "delete-middle-logical",
        "steps": THREE_LOGICAL + delete(3) + shot("01-deleted", "The first and third logical partitions") +
                 quit_fdisk(),
        "check": all_of(expect_table(prim=[EXT_ALL], logical=[L1, L3]),
                        record(2048, (0x06, MB, TEN), (0x05, 45056, MB + TEN))),
        "expect": "the record at 2048 links straight to the one at 47104",
    },
    {
        "name": "delete-last-logical",
        "steps": TWO_LOGICAL + delete(3) + shot("01-deleted", "One logical partition left") + quit_fdisk(),
        "check": all_of(expect_table(prim=[EXT_ALL], logical=[L1]),
                        record(2048, (0x06, MB, TEN), None), record(24576, None, None)),
        "expect": "the first record's link is empty, and the deleted record's entries are cleared",
    },
    {
        "name": "delete-extended-refused",
        "steps": fdisk() + extended() + menu("3") + h.answer("1", 2) +
                 shot("01-refused", "Delete its logical partitions first") + quit_fdisk(),
        "check": expect_table(prim=[EXT_ALL], logical=[(2048, 0x06, MB, ALL - MB)]),
        "expect": "the extended partition is not deleted while it holds a logical partition",
    },
    {
        "name": "delete-extended",
        "steps": fdisk() + extended() + delete(2) + delete(1) + shot("01-deleted", "No partitions left") +
                 quit_fdisk(),
        "check": expect_table(),
        "expect": "the logical partition, then the extended one: the table is empty",
    },
    {
        "name": "mbr",
        "steps": h.command(f"FDISK {DISK} -MBR", 4) + shot("01-written", "Boot code written; the partition table is kept"),
        "keep": [("image", 0)],
        "check": all_of(expect_table(), boot_code("image")),
        "expect": "the first 440 bytes are the MBR boot code, the partition table is empty, and the signature is 55 AA",
    },
    {
        "name": "mbr-keeps-table",
        "steps": fdisk() + primary("", "20") + quit_fdisk() + h.command(f"FDISK {DISK} -MBR", 4) +
                 shot("01-written", "Boot code written; the partition table is kept"),
        "check": all_of(expect_table(prim=[(0, 0x06, 2048, 20 * MB)])),
        "mbr_code": True,
        "expect": "after -MBR the partition made before is still there, and the boot code is written",
    },
    {
        # The boot disk: -MBR writes its boot code (on a copy):
        "name": "boot-mbr",
        "system_copy": True,
        "keep": [("system", 0)],
        "steps": [("wait", 2)] + h.command(f"FDISK {h.SYSTEM_DISK} -MBR", 4) +
                 shot("01-boot-disk", "Boot code written to disk 1 (no refusal)"),
        "check": boot_code("system"),
        "expect": "the system disk's MBR gets the boot code; its partition table is kept",
    },
    {
        "name": "boot-menu-refused",
        "system_copy": True,
        "keep": [("system", 0)],
        "steps": fdisk(h.SYSTEM_DISK) + shot("01-refused", "Disk 1 is the disk ZDOS was started from"),
        "check": unchanged("system", 0),
        "expect": "FDISK refuses the disk ZDOS started from; its MBR is unchanged",
    },
    {
        "name": "superfloppy-refused",
        "disk": superfloppy,
        "keep": [("image", 0)],
        "steps": fdisk() + shot("01-refused", "One FAT volume with no partition table"),
        "check": unchanged("image", 0),
        "expect": "a disk that is one FAT volume is refused; its boot sector is unchanged",
    },
    {
        "name": "superfloppy-mbr-refused",
        "disk": superfloppy,
        "keep": [("image", 0)],
        "steps": h.command(f"FDISK {DISK} -MBR", 4) + shot("01-refused", "One FAT volume: it has no MBR"),
        "check": unchanged("image", 0),
        "expect": "-MBR on a disk that is one FAT volume is refused; its boot sector (BPB) is unchanged",
    },
    {
        "name": "floppy-mbr-refused",
        "floppy_copy": True,
        "keep": [("floppy", 0)],
        "steps": h.command(f"FDISK {h.FLOPPY_DISK} -MBR", 4) + shot("01-refused", "The floppy is one FAT volume"),
        "check": unchanged("floppy", 0),
        "expect": "-MBR on the floppy (one FAT volume) is refused; its boot sector is unchanged",
    },
    {
        "name": "ntfs-superfloppy-refused",
        "disk": foreign_superfloppy(b"NTFS    "),
        "keep": [("image", 0)],
        "steps": fdisk() + shot("01-refused", "One NTFS volume with no partition table"),
        "check": unchanged("image", 0),
        "expect": "a disk that is one NTFS volume is refused (its boot code is not read as partitions); "
                  "its boot sector is unchanged",
    },
    {
        "name": "exfat-superfloppy-mbr-refused",
        "disk": foreign_superfloppy(b"EXFAT   "),
        "keep": [("image", 0)],
        "steps": h.command(f"FDISK {DISK} -MBR", 4) + shot("01-refused", "One exFAT volume: it has no MBR"),
        "check": unchanged("image", 0),
        "expect": "-MBR on a disk that is one exFAT volume is refused; its boot sector is unchanged",
    },
    {
        "name": "gpt-refused",
        "disk": gpt,
        "keep": [("image", 0)],
        "steps": fdisk() + shot("01-refused", "GPT disks are not supported"),
        "check": unchanged("image", 0),
        "expect": "a GPT disk (type EE) is refused; its protective MBR is unchanged",
    },
    {
        "name": "past-2tb-refused",
        "disk": big,
        "steps": fdisk() + menu("1") + h.answer("1", 2) + shot("01-primary", "No primary partition past 2 TB") +
                 menu("1") + h.answer("2", 2) + shot("02-extended", "No extended partition past 2 TB") + quit_fdisk(),
        "check": expect_table(prim=[(0, 0x06, 2048, BIG_FIRST)]),
        "expect": "the free space starts at sector 2^32: no primary or extended partition is made there",
    },
]


def run_case(case):
    image = os.path.join(IMG, f"{case['name']}.img")
    if os.path.exists(image):
        os.remove(image)
    (case.get("disk") or blank)(image)
    ctx = {"image": image, "system": h.SYSTEM_IMG, "floppy": h.FLOPPY_IMG, "before": {}}
    if case.get("system_copy"):
        ctx["system"] = h.copy_to(h.SYSTEM_IMG, os.path.join(IMG, f"{case['name']}-system.img"))
    if case.get("floppy_copy"):
        ctx["floppy"] = h.copy_to(h.FLOPPY_IMG, os.path.join(IMG, f"{case['name']}-floppy.img"))
    for which, lba in case.get("keep", []):
        ctx["before"][(which, lba)] = h.read_sector(ctx[which], lba)
    sock = os.path.join(OUT, f"mon-{case['name']}.sock")
    args = h.qemu_args(sock, test=image, system=ctx["system"], system_snapshot=not case.get("system_copy"),
                       floppy=ctx["floppy"], floppy_snapshot=not case.get("floppy_copy"))
    shots = h.run_qemu(args, case["steps"], os.path.join(SHOTS, case["name"]), sock)
    ctx["prim"], ctx["logical"] = h.table_of(image)
    passed, detail = case["check"](ctx)
    if case.get("mbr_code"):
        with open(h.MBR_BIN, "rb") as f:
            code_ok = h.read_sector(image, 0)[:440] == f.read(440)
        passed = passed and code_ok
        detail += "; boot code " + ("written" if code_ok else "missing")
    # The big sparse disk and the copies are not kept:
    for path in (image, ctx["system"], ctx["floppy"]):
        if path not in (h.SYSTEM_IMG, h.FLOPPY_IMG) and os.path.getsize(path) > (1 << 30):
            os.remove(path)
    return passed, detail, shots


def main():
    if len(sys.argv) != 2 or sys.argv[1] != "run":
        print("Usage: fdisk-tests.py run")
        sys.exit(1)
    h.require(h.SYSTEM_IMG, h.DATA_IMG, h.FLOPPY_IMG, h.MBR_BIN)
    h.require(OLD_FAT, hint="make the CHKDSK test images first: chkdsk-tests.py make")
    os.makedirs(IMG, exist_ok=True)
    results = []
    for case in CASES:
        passed, detail, shots = run_case(case)
        results.append((case["name"], passed, case["expect"], detail, shots))
        print(f"{'PASS' if passed else 'FAIL'}  {case['name']}: {detail}", flush=True)
    h.write_results(os.path.join(OUT, "RESULTS.md"), "FDISK test results", results)
    sys.exit(1 if h.summary(results) else 0)


if __name__ == "__main__":
    main()
