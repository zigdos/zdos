#!/usr/bin/env python3
# CHKDSK test suite:
#   chkdsk-tests.py make | run
# Default metal x86_64; another edition (common.py; sys-damaged is BIOS's):
#   ZDOS_EDITION=bios ZDOS_ARCH=x86 python3 tests/disk/chkdsk-tests.py run
# Each case runs on its own image copy.
# Without -F nothing may change; with -F the volume must pass fsck.fat -n.
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import common as h  # noqa: E402

OUT = h.suite_dir("chkdsk-tests")
IMG = h.CHKDSK_IMAGES
RUN = os.path.join(OUT, "copies")  # the copies the cases change
SHOTS = os.path.join(OUT, "shots")
KINDS = {"fat12": ("12", 1440), "fat16": ("16", 16384), "fat32": ("32", 65536)}
FILES = [("A.TXT", 10000), ("B.TXT", 5000)]
SUB_FILES = [("SUB", "C.TXT", 3000), ("SUB2", "D.TXT", 2000)]
DAMAGE = ("mismatch", "lost", "crosslink", "size", "foldercross", "orphan")
SECTOR = h.SECTOR

# The logical partition of ext.img: start and size:
EXT_LOGICAL = (36864, 32768)


def populate(path, subs=True):
    src = os.path.join(IMG, "sources")
    os.makedirs(src, exist_ok=True)
    for name, size in FILES:
        p = os.path.join(src, name)
        with open(p, "wb") as f:
            f.write(bytes((i * 7) & 0xFF for i in range(size)))
        h.run("mcopy", "-i", path, p, f"::/{name}")
    if subs:
        for folder, name, size in SUB_FILES:
            h.run("mmd", "-i", path, f"::/{folder}")
            p = os.path.join(src, name)
            with open(p, "wb") as f:
                f.write(bytes((i * 11) & 0xFF for i in range(size)))
            h.run("mcopy", "-i", path, p, f"::/{folder}/{name}")


def mkfs(kind, path, label, kib=None):
    option, default_kib = KINDS[kind]
    h.mkfs(path, option, kib or default_kib, label)


def damage(v, how):
    a = v.find(h.name83("A.TXT"))
    b = v.find(h.name83("B.TXT"))
    a_clusters = v.chain(v.first_cluster(a))
    if how == "mismatch":
        v.fat_set(a_clusters[1], 0, copies=(1,))
    elif how == "lost":
        v.fat_set(a_clusters[1], 0)
    elif how == "crosslink":
        v.fat_set(v.first_cluster(b), a_clusters[0])
    elif how == "size":
        v.set_size(a, 1)
    elif how == "foldercross":
        # SUB2 points at SUB's clusters: two folders share them:
        sub = v.find(h.name83("SUB"))
        sub2 = v.find(h.name83("SUB2"))
        v.set_first(sub2, v.first_cluster(sub))
    elif how == "orphan":
        # A long-name entry with no short entry after it:
        pos = v.free_slot()
        lfn = bytearray(32)
        lfn[0] = 0x41
        lfn[1:11] = "TEST".encode("utf-16-le") + b"\x00\x00"
        lfn[11] = 0x0F
        v.write(pos, bytes(lfn))
    elif how == "fsinfo":
        # FAT32 only: FSInfo's free cluster count is wrong:
        v.write(v.fsinfo * SECTOR + 488, struct.pack("<I", 12345))


def make_superfloppy_images():
    cases = {}
    for kind in KINDS:
        clean = os.path.join(IMG, f"{kind}-clean.img")
        mkfs(kind, clean, f"CHK-{kind.upper()}")
        populate(clean)
        cases[f"{kind}-clean"] = clean
        for how in DAMAGE + (("fsinfo",) if kind == "fat32" else ()):
            path = h.copy_to(clean, os.path.join(IMG, f"{kind}-{how}.img"))
            damage(h.Vol(path), how)
            cases[f"{kind}-{how}"] = path
    return cases


def make_ext_images():
    # 40 MB: a primary FAT16 (16 MB), an extended one holding a FAT16:
    disk = os.path.join(IMG, "ext.img")
    h.make_disk(disk, 81920)
    h.write_table(disk, 0, [(0x06, 2048, 32768), (0x05, 34816, 47104)])
    h.write_table(disk, 34816, [(0x06, 2048, 32768)])  # logical partition, from this record
    primary = os.path.join(IMG, "ext-part1.img")
    logical = os.path.join(IMG, "ext-part3.img")
    mkfs("fat16", primary, "CHK-PRI", 16384)
    populate(primary)
    mkfs("fat16", logical, "CHK-LOG", 16384)
    populate(logical)
    for lba, part in ((2048, primary), (EXT_LOGICAL[0], logical)):
        with open(part, "rb") as f:
            h.write_sector(disk, lba, f.read())
    # The same disk with a damaged logical partition: A.TXT's chain cut:
    damaged = h.copy_to(disk, os.path.join(IMG, "ext-lost.img"))
    damage(h.Vol(damaged, base=EXT_LOGICAL[0] * SECTOR), "lost")
    return {"ext-clean": disk, "ext-lost": damaged}


GPT_SECTORS = 81920
GPT_PART = (2048, 32768)  # GPT entry 2 (entry 1 empty: partition 2, numbered by slot)


def make_gpt_images():
    # GPT: entry 1 empty, a FAT16 in entry 2; the same with a lost chain;
    # and a protective MBR whose GPT header is missing:
    disk = os.path.join(IMG, "gpt.img")
    h.make_disk(disk, GPT_SECTORS)
    h.write_gpt(disk, GPT_SECTORS, [None, (h.GPT_BASIC_DATA, GPT_PART[0], sum(GPT_PART) - 1, "chk")])
    part = os.path.join(IMG, "gpt-part2.img")
    mkfs("fat16", part, "CHK-GPT", 16384)
    populate(part)
    with open(part, "rb") as f:
        h.write_sector(disk, GPT_PART[0], f.read())
    damaged = h.copy_to(disk, os.path.join(IMG, "gpt-lost.img"))
    damage(h.Vol(damaged, base=GPT_PART[0] * SECTOR), "lost")
    no_header = os.path.join(IMG, "gpt-no-header.img")
    h.make_disk(no_header, GPT_SECTORS)
    h.write_table(no_header, 0, [(0xEE, 1, GPT_SECTORS - 1)])
    return {"gpt-clean": disk, "gpt-lost": damaged, "gpt-no-header": no_header}


def make_sys_image():
    # The system disk with a test file's chain cut, not the boot files:
    path = h.copy_to(h.SYSTEM_IMG, os.path.join(IMG, "sys-damaged.img"))
    start = h.read_entries(h.read_sector(path, 0))[0]["start"]
    # A 10 KB file: two clusters at least, so there is a chain to cut:
    src = os.path.join(IMG, "sources", "TEST.TXT")
    with open(src, "wb") as f:
        f.write(bytes((i * 13) & 0xFF for i in range(10000)))
    h.run("mcopy", "-i", f"{path}@@{start * SECTOR}", src, "::/TEST.TXT")
    v = h.Vol(path, base=start * SECTOR)
    test = v.find(h.name83("TEST.TXT"))
    chain = v.chain(v.first_cluster(test))
    if len(chain) < 2:
        raise SystemExit("TEST.TXT needs two clusters for this test")
    v.fat_set(chain[1], 0)
    return {"sys-damaged": path}


def make():
    h.require(h.SYSTEM_IMG)
    os.makedirs(os.path.join(IMG, "sources"), exist_ok=True)
    images = {}
    images.update(make_superfloppy_images())
    images.update(make_ext_images())
    images.update(make_gpt_images())
    images.update(make_sys_image())
    for name, path in sorted(images.items()):
        print(f"{name}: {path}")
    return images


# RUNNING THE CASES IN QEMU

def steps_check(disk, part, wait, fix):
    # List, check, and when fix is set, repair, then recheck:
    s = h.command(f"CHKDSK {disk}", 4) + [("shot", "01-disk-list", "Disks, and the partitions of this disk")]
    s += h.command(f"CHKDSK {disk} {part}", wait)
    s += [("shot", "02-check", "What the check finds" + (" (expect problems)" if fix else " (expect no errors)"))]
    if fix:
        s += h.command(f"CHKDSK {disk} {part} -F", wait) + h.answer("y", wait)
        s += [("shot", "03-repair", "The repairs made, and the check after them")]
        s += h.answer("n", 3) + [("shot", "04-after-restart-declined", "Restart question declined")]
        s += h.command(f"CHKDSK {disk} {part}", wait) + [("shot", "05-recheck", "Expect: No errors found")]
    return s


EXPECT = {
    "clean": "no errors; the disk is not changed",
    "mismatch": "FAT copies differ in 1 entry; repair copies FAT 1 over FAT 2",
    "lost": "chain ends early; lost clusters; repair saves them as FOUND.000\\FILE0000.CHK",
    "crosslink": "B.TXT cross-linked with A.TXT; repair copies B's data to FOUND.000\\FILE0000.CHK",
    "size": "A.TXT size 1 but chain 5; repair cuts the chain and saves the rest as a .CHK",
    "foldercross": "SUB2 uses SUB's clusters; repair copies SUB2 to FOUND.000\\DIR0000, SUB2 becomes empty",
    "orphan": "orphan long-name entry in the root; repair deletes it",
    "fsinfo": "FSInfo says 12345 free clusters, the FAT has another count; repair sets FSInfo from the FAT",
}

# Damages whose repair saves something in FOUND.000:
SAVES_FOUND = ("lost", "crosslink", "size", "foldercross")

CASES = []
for kind in KINDS:
    wait = {"fat32": 45, "fat16": 15, "fat12": 10}[kind]
    CASES.append({"name": f"{kind}-clean", "image": f"{kind}-clean.img", "disk": h.TEST_DISK, "part": 1,
                  "wait": wait, "fix": False, "how": "clean", "expect": EXPECT["clean"]})
    for how in DAMAGE + (("fsinfo",) if kind == "fat32" else ()):
        CASES.append({"name": f"{kind}-{how}", "image": f"{kind}-{how}.img", "disk": h.TEST_DISK, "part": 1,
                      "wait": wait, "fix": True, "how": how, "expect": EXPECT[how]})
CASES += [
    {"name": "ext-clean", "image": "ext.img", "disk": h.TEST_DISK, "part": 3, "wait": 15, "fix": False,
     "how": "clean", "volume": EXT_LOGICAL,
     "expect": "three partitions listed (primary, extended, logical); no errors in partition 3; the disk is not changed"},
    {"name": "ext-lost", "image": "ext-lost.img", "disk": h.TEST_DISK, "part": 3, "wait": 15, "fix": True,
     "how": "lost", "volume": EXT_LOGICAL, "untouched": ("ext.img", range(2048, 2048 + 32768)),
     "expect": "logical partition 3 damaged; repair as for a lost chain, only inside partition 3"},
    {"name": "gpt-clean", "image": "gpt.img", "disk": h.TEST_DISK, "part": 2, "wait": 15, "fix": False,
     "how": "clean",
     "expect": "GPT listing: partition 2 (entry 1 empty), FAT; no errors in partition 2; the disk is not changed"},
    {"name": "gpt-lost", "image": "gpt-lost.img", "disk": h.TEST_DISK, "part": 2, "wait": 15, "fix": True,
     "how": "lost", "volume": GPT_PART, "untouched": ("gpt.img", h.gpt_tables(GPT_SECTORS)),
     "expect": "GPT partition 2 damaged; repair as for a lost chain, only inside it; both GPT copies unchanged"},
    {"name": "gpt-no-header", "image": "gpt-no-header.img", "disk": h.TEST_DISK, "part": 1, "wait": 5,
     "fix": False, "how": "gpt",
     "expect": "a protective MBR without a GPT header: the partition table can't be read; the disk is not changed"},
]


def sys_steps():
    return [("wait", 30)] + \
        h.command("DIR", 4) + [("shot", "01-dir-before", "C: is damaged: DIR (may show errors)")] + \
        h.command("TYPE TEST.TXT", 4) + [("shot", "02-type-before", "TEST.TXT: expect a disk error")] + \
        h.command(f"CHKDSK {h.SYSTEM_DISK} 1", 45) + [("shot", "03-check", "Expect: TEST.TXT chain ends early, lost clusters")] + \
        h.command(f"CHKDSK {h.SYSTEM_DISK} 1 -F", 45) + h.answer("y", 45) + \
        [("shot", "04-repair", "Repairs made; expect the restart question")] + \
        h.answer("y", 30) + [("shot", "05-after-restart", "Expect: ZDOS has restarted and started again from C:")] + \
        h.command("DIR", 4) + [("shot", "06-dir-after", "Expect: DIR works")] + \
        h.command("TYPE TEST.TXT", 4) + [("shot", "07-type-after", "Expect: TEST.TXT reads normally")] + \
        h.command(f"CHKDSK {h.SYSTEM_DISK} 1", 45) + [("shot", "08-recheck", "Expect: No errors found")]


def check_after(case, image, before):
    # (passed, detail) for the image after the case:
    if not case["fix"]:
        same = h.file_hash(image) == before
        return same, "disk unchanged" if same else "CHKDSK without -F changed the disk"
    base, sectors = case.get("volume", (0, None))
    notes = []
    ok, text = h.fsck(image, base, sectors)
    passed = ok is not False
    notes.append(f"fsck.fat: {text}")
    v = h.Vol(image, base=base * SECTOR)
    if case["how"] in SAVES_FOUND:
        found = v.find(h.name83("FOUND.000")) is not None
        passed = passed and found
        notes.append("FOUND.000 " + ("made" if found else "missing"))
    if v.kind == "fat32" and v.fsinfo:
        stored = h.u32(v.read(v.fsinfo * SECTOR, SECTOR), 488)
        counted = v.free_clusters()
        passed = passed and stored == counted
        notes.append(f"FSInfo free {stored}, FAT free {counted}")
    if "untouched" in case:
        # Only the damaged partition may change:
        name, sectors = case["untouched"]
        clean = os.path.join(IMG, name)
        changed = [lba for lba in sectors if h.read_sector(image, lba) != h.read_sector(clean, lba)]
        passed = passed and not changed
        notes.append("the rest untouched" if not changed else f"{len(changed)} sectors outside it CHANGED")
    return passed, "; ".join(notes)


def run_all():
    h.require_system()
    os.makedirs(RUN, exist_ok=True)
    results = []
    for case in CASES:
        src = os.path.join(IMG, case["image"])
        if not os.path.exists(src):
            print("missing image", case["image"], "- run make first")
            continue
        image = h.copy_to(src, os.path.join(RUN, case["name"] + ".img"))
        before = h.file_hash(image)
        steps = steps_check(case["disk"], case["part"], case["wait"], case["fix"])
        sock = os.path.join(OUT, f"mon-{case['name']}.sock")
        shots = h.run_qemu(h.qemu_args(sock, test=image), steps, os.path.join(SHOTS, case["name"]), sock)
        passed, detail = check_after(case, image, before)
        results.append((case["name"], passed, case["expect"], detail, shots))
        print(f"{'PASS' if passed else 'FAIL'}  {case['name']}: {detail}", flush=True)
    src = os.path.join(IMG, "sys-damaged.img")
    if h.EDITION != "bios":
        print("sys-damaged: BIOS only (its C: is FAT; metal's is Minix)")
    elif os.path.exists(src):
        # The system disk itself is repaired: a copy, read back after:
        image = h.copy_to(src, os.path.join(RUN, "sys-damaged.img"))
        sock = os.path.join(OUT, "mon-sys-damaged.sock")
        shots = h.run_qemu(h.qemu_args(sock, system=image, system_snapshot=False), sys_steps(),
                           os.path.join(SHOTS, "sys-damaged"), sock)
        start = h.read_entries(h.read_sector(image, 0))[0]
        ok, text = h.fsck(image, start["start"], start["sectors"])
        results.append(("sys-damaged", ok is not False, "C: damaged; repair from C:, restart, C: works again",
                        f"fsck.fat on C:: {text}", shots))
        print(f"{'PASS' if ok is not False else 'FAIL'}  sys-damaged: {text}", flush=True)
    else:
        print("missing image sys-damaged.img - run make first")
    h.write_results(os.path.join(OUT, "RESULTS.md"), "CHKDSK test results", results)
    sys.exit(1 if h.summary(results) else 0)


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("make", "run"):
        print("Usage: chkdsk-tests.py make | run")
        sys.exit(1)
    if sys.argv[1] == "make":
        make()
    else:
        run_all()
