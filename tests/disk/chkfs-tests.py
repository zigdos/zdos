#!/usr/bin/env python3
# CHKMFS / CHKEXT2 test (metal x86_64, ARM64 or BIOS; default metal
# x86_64, another: tests/common.py):
#   chkfs-tests.py [drives]
# Test disk: p1 FAT (output), p2 ext2, p3 ext2 damaged, p4 Minix, p5
# Minix damaged (the system disk's Minix volume; BIOS, whose system
# disk is FAT: one made from the checked tree. chkfs-damage.py: also a
# cross-link, a garbage inode,
# ext2 a stale backup superblock). Each checked; the damaged: -F (the
# copy for the cross-link), checked (the garbage inode left: -D's),
# -D (it is deleted), checked clean; then e2fsck -fn must pass.
# "drives" only runs DRIVES.
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import common as h  # noqa: E402

h.only("metal-x86_64", "metal-arm64", "bios-x86")

D = h.suite_dir("chkfs-tests")
SYSTEM = h.EDITION_SYSTEM_IMG
DAMAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "chkfs-damage.py")
MIB = 2048  # sectors


FROM_SYSTEM = h.EDITION != "bios"
MFS_START, MFS_SIZE = h.minix_volume(SYSTEM) if FROM_SYSTEM else (0, 32 * MIB)
# (name, start sector, sectors):
PARTS = [("out", 2048, 16 * MIB), ("ext2", 18 * MIB, 16 * MIB), ("ext2bad", 34 * MIB, 16 * MIB),
         ("mfs", 50 * MIB, MFS_SIZE), ("mfsbad", 50 * MIB + MFS_SIZE, MFS_SIZE)]
DISK_SECTORS = 50 * MIB + 2 * MFS_SIZE + MIB  # GPT's backup at the end
# From the edition's first test letter (D:, BIOS E:):
LETTERS = {name: h.next_letter(h.TEST_LETTER, i) for i, (name, _, _) in enumerate(PARTS)}


def part_image(name):
    return os.path.join(D, name + ".part")


def make():
    shutil.rmtree(D, ignore_errors=True)
    os.makedirs(D)
    tree = h.checker_tree(os.path.join(D, "tree"))
    h.mkfs(part_image("out"), "16", 16 * 1024, "CHKOUT")
    # ext2bad: 4 groups of 1024 blocks, for backups in groups 1 and 3:
    for name, bs, groups in (("ext2", "1024", []), ("ext2bad", "4096", ["-g", "1024"])):
        subprocess.run(["mke2fs", "-q", "-F", "-t", "ext2", "-b", bs, *groups, "-L", name.upper(), "-d", tree,
                        part_image(name), "16M"], check=True)
    # Minix: the system volume's (p2 of system.img), or from the tree:
    for name in ("mfs", "mfsbad"):
        if FROM_SYSTEM:
            h.extract(SYSTEM, MFS_START, MFS_SIZE, part_image(name))
        else:
            h.mfsdir(part_image(name), MFS_SIZE, tree)
    subprocess.run([sys.executable, DAMAGE, "ext2", part_image("ext2bad")], check=True)
    subprocess.run([sys.executable, DAMAGE, "mfs", part_image("mfsbad")], check=True)
    return h.gpt_from_parts(os.path.join(D, "test.img"), DISK_SECTORS, [
        (part_image(name), s, n, h.TYPE_BASIC if name == "out" else h.TYPE_LINUX) for name, s, n in PARTS])


def qemu(disk, sock):
    # The edition's machine (tests/common.py), the console to serial.txt:
    return h.machine_args(sock, disk, D) + ["-serial", f"file:{os.path.join(D, 'serial.txt')}"]


def extract(disk, name):
    _, s, n = next(p for p in PARTS if p[0] == name)
    return h.extract(disk, s, n, os.path.join(D, name + ".after"))


def main():
    disk = make()
    sock = os.path.join(D, "mon.sock")
    L = LETTERS
    o = L["out"]
    if len(sys.argv) > 1 and sys.argv[1] == "drives":
        steps = h.command(f"DRIVES > {o}:\\DRIVES.TXT", 3) + h.command("DRIVES", 3) + [("shot", "drives")]
    else:
        steps = []
        for name, tool in (("ext2", "CHKEXT2"), ("mfs", "CHKMFS")):
            steps += h.command(f"{tool} {L[name]}: > {o}:\\{name}.TXT", 10)
            bad = name + "bad"
            steps += h.command(f"{tool} {L[bad]}: > {o}:\\{bad}.TXT", 10)
            # Yes to the repair, no to the restart:
            steps += h.command(f"{tool} {L[bad]}: -F > {o}:\\{bad}F.TXT", 10) + h.answer("Y", 20) + h.answer("N", 3)
            steps += h.command(f"{tool} {L[bad]}: > {o}:\\{bad}2.TXT", 10)
            steps += h.command(f"{tool} {L[bad]}: -D > {o}:\\{bad}D.TXT", 10) + h.answer("Y", 20) + h.answer("N", 3)
            steps += h.command(f"{tool} {L[bad]}: > {o}:\\{bad}3.TXT", 10)
            steps += h.command(f"DIR {L[bad]}:\\lost+found > {o}:\\{bad}LF.TXT", 3)
        steps += [("shot", "end")]
    h.run_qemu(qemu(disk, sock), steps, D, sock)
    out = extract(disk, "out")
    names = ["DRIVES"] if len(sys.argv) > 1 else [n for b in ("ext2", "mfs") for n in (b, b + "bad", b + "badF", b + "bad2", b + "badD", b + "bad3", b + "badLF")]
    texts = {}
    for n in names:
        r = subprocess.run(["mtype", "-i", out, f"::/{n}.TXT"], capture_output=True, text=True)
        texts[n] = r.stdout.replace("\r", "")
        print(f"===== {n}.TXT\n{r.stdout or r.stderr}")
    if len(sys.argv) > 1:
        return
    r = subprocess.run(["e2fsck", "-fn", extract(disk, "ext2bad")], capture_output=True, text=True)
    print(f"===== e2fsck -fn (repaired ext2): exit {r.returncode}\n{r.stdout}")
    results = verdict(texts, r.returncode)
    h.write_results(os.path.join(D, "RESULTS.md"), f"CHKMFS / CHKEXT2 test results ({h.NAME})", results)
    sys.exit(1 if h.summary(results) else 0)


# (name, passed, expected, detail, shots) per file system and run:
def verdict(t, e2fsck_exit):
    def case(name, expect, *checks):
        failed = [what for what, ok in checks if not ok]
        return (name, not failed, expect, "; ".join(failed) if failed else "as expected", [])

    def has(n, text):
        return (f"{n}.TXT has '{text}'", text in t.get(n, ""))

    def lacks(n, text):
        return (f"{n}.TXT has no '{text}'", text not in t.get(n, ""))

    res = []
    for b in ("ext2", "mfs"):
        bad = b + "bad"
        ext = b == "ext2"
        res.append(case(f"{b}-clean", "the undamaged volume: no errors (ext2: its backups match)",
                        has(b, "No errors found")))
        res.append(case(f"{b}-check", "the damage found: the cross-link (-F copies it), the garbage inode (-D's)"
                        + (", the stale backup" if ext else ""),
                        has(bad, "cross-linked"), has(bad, "(-D deletes this file)"),
                        *([has(bad, "backup superblocks of 1 groups differ")] if ext else [])))
        res.append(case(f"{b}-fix", "-F: the cross-linked file gets its own copy"
                        + (", the backup rewritten" if ext else "") + "; the garbage inode stays (-D's)",
                        has(bad + "F", "Check this file: fixed crosslink"),
                        has(bad + "F", "-D fixes the rest and deletes them"),
                        *([has(bad + "F", "fixed: the backup superblocks")] if ext else [])))
        res.append(case(f"{b}-left", "after -F only the garbage inode is left, and -D is named",
                        has(bad + "2", "(-D deletes this file)"), lacks(bad + "2", "cross-linked"),
                        lacks(bad + "2", "backup")))
        res.append(case(f"{b}-delete", "-D deletes the garbage inode's file",
                        has(bad + "D", "deleted:"), has(bad + "D", " 0 could not be fixed.")))
        res.append(case(f"{b}-clean-after", "after -D: no errors", has(bad + "3", "No errors found")))
    res.append(("e2fsck", e2fsck_exit == 0, "e2fsck -fn passes on the repaired ext2",
                f"exit {e2fsck_exit}", []))
    return res


if __name__ == "__main__":
    main()
