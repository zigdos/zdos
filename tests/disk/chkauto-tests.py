#!/usr/bin/env python3
# The checkers' -A (CHKEXT2 and CHKMFS; CHKDSK shares it), on
# metal x86_64, ARM64 or BIOS (default metal x86_64; another:
# tests/common.py):
#   chkauto-tests.py
# Test disk (GPT): ext2 p1 undamaged (D:), p2 damaged (E:), p3 damaged
# without a drive letter (GPT attribute 63); Minix p4 undamaged (F:),
# p5 damaged (G:), p6 damaged without a letter. Per file system:
#   clean      X: -A on the undamaged: nothing to fix, no restart
#   no-letter  disk 1 partition N -A: fixed, no letter: no restart
#   restart    X: -A on the damaged one with a letter: fixed, the
#              countdown, a restart
#   works      after it the volume is written (it was read only
#              while unclean)
# The serial console tells it apart: ECHO @@ marks each phase, each
# boot prints one "ZDOS version". ext2 is checked on the host too.
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import common as h  # noqa: E402

h.only("metal-x86_64", "metal-arm64", "bios-x86")

D = h.suite_dir("chkauto-tests")
DAMAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "chkfs-damage.py")
MIB = 2048  # sectors
NO_LETTER = h.NO_LETTER
# Minix: the system disk's volume; BIOS (a FAT system disk): one
# made from the checked tree
FROM_SYSTEM = h.EDITION != "bios"
MFS_START, MFS_SIZE = h.minix_volume(h.EDITION_SYSTEM_IMG) if FROM_SYSTEM else (0, 32 * MIB)
EXT = 16 * MIB
# (name, kind, start sector, sectors, GPT attributes), in letter order:
PARTS = [("ext2-clean", "ext2", 2048, EXT, ""), ("ext2-bad", "ext2", 2048 + EXT, EXT, ""),
         ("ext2-hidden", "ext2", 2048 + 2 * EXT, EXT, NO_LETTER),
         ("mfs-clean", "mfs", 2048 + 3 * EXT, MFS_SIZE, ""),
         ("mfs-bad", "mfs", 2048 + 3 * EXT + MFS_SIZE, MFS_SIZE, ""),
         ("mfs-hidden", "mfs", 2048 + 3 * EXT + 2 * MFS_SIZE, MFS_SIZE, NO_LETTER)]
DISK_SECTORS = 2048 + 3 * EXT + 3 * MFS_SIZE + MIB  # GPT's backup at the end
TOOLS = {"ext2": "CHKEXT2", "mfs": "CHKMFS"}


def letters():
    # The edition's first test letter on (D:, BIOS E:), skipping
    # those without one:
    out, letter = {}, h.TEST_LETTER
    for name, _, _, _, attrs in PARTS:
        if not attrs:
            out[name] = letter
            letter = h.next_letter(letter)
    return out


def part_image(name):
    return os.path.join(D, name + ".part")


def make():
    shutil.rmtree(D, ignore_errors=True)
    os.makedirs(D)
    tree = h.checker_tree(os.path.join(D, "tree"))
    for name, kind, _, _, _ in PARTS:
        if kind == "ext2":
            subprocess.run(["mke2fs", "-q", "-F", "-t", "ext2", "-b", "4096", "-g", "1024", "-L", name.upper(),
                            "-d", tree, part_image(name), "16M"], check=True)
        elif FROM_SYSTEM:
            # The system volume's (p2 of system.img):
            h.extract(h.EDITION_SYSTEM_IMG, MFS_START, MFS_SIZE, part_image(name))
        else:
            h.mfsdir(part_image(name), MFS_SIZE, tree)
        if not name.endswith("clean"):
            subprocess.run([sys.executable, DAMAGE, kind, part_image(name)], check=True, stdout=subprocess.DEVNULL)
    return h.gpt_from_parts(os.path.join(D, "test.img"), DISK_SECTORS,
                            [(part_image(name), s, n, h.TYPE_LINUX, a) for name, _, s, n, a in PARTS])


def extract(disk, name):
    _, _, s, n, _ = next(p for p in PARTS if p[0] == name)
    return h.extract(disk, s, n, os.path.join(D, name + ".after"))


def e2fsck(path):
    return subprocess.run(["e2fsck", "-fn", path], capture_output=True, text=True).returncode


def phase(name, line, wait):
    # A marker on the serial console, then the command:
    return h.command(f"ECHO @@{name}", 2) + h.command(line, wait)


def steps():
    L = letters()
    s = []
    for kind in ("ext2", "mfs"):
        s += phase(f"{kind}-clean", f"{TOOLS[kind]} {L[kind + '-clean']}: -A", 15)
    for kind in ("ext2", "mfs"):
        number = [p[0] for p in PARTS].index(kind + "-hidden") + 1
        s += phase(f"{kind}-no-letter", f"{TOOLS[kind]} {h.TEST_DISK} {number} -A", 30)
    s += [("shot", "01-before-restarts", "the clean and no-letter phases: no restart")]
    # Each restart: the repair, the 10 s countdown, then the boot:
    for kind in ("ext2", "mfs"):
        x = L[kind + "-bad"]
        s += phase(f"{kind}-restart", f"{TOOLS[kind]} {x}: -A", 30 + 10 + h.BOOT_WAIT + 5)
        s += phase(f"{kind}-works", f"ECHO after > {x}:\\AFTER.TXT", 3) + h.command(f"TYPE {x}:\\AFTER.TXT", 3)
        s += [("shot", f"02-{kind}-restarted", f"after the restart: {x}: written")]
    return s


def segments(log):
    # The text after each marker's output line, to the next marker:
    marks = [(m.group(1), m.end()) for m in re.finditer(r"^@@(\S+)\s*$", log, re.M)]
    out = {}
    for i, (name, end) in enumerate(marks):
        out[name] = log[end:marks[i + 1][1] if i + 1 < len(marks) else len(log)]
    return out


def main():
    h.require_system()
    disk = make()
    sock = os.path.join(D, "mon.sock")
    serial = os.path.join(D, "serial.txt")
    args = h.machine_args(sock, disk, D) + ["-serial", f"file:{serial}"]
    shots = h.run_qemu(args, steps(), os.path.join(D, "shots"), sock)

    raw = open(serial, "rb").read().decode("utf-8", "replace") if os.path.exists(serial) else ""
    log = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", raw).replace("\r", "")
    seg = segments(log)
    boots, countdowns = log.count("ZDOS version"), log.count("Restarting in 10 seconds")

    def text(name):
        return seg.get(name, "")

    results = []
    for kind in ("ext2", "mfs"):
        tool = TOOLS[kind]
        t = text(f"{kind}-clean")
        ok = "No errors found" in t and "Restarting" not in t
        detail = "no errors, no restart" if ok else "output: " + " | ".join(t.strip().splitlines()[-3:])
        if kind == "ext2":
            code = e2fsck(extract(disk, "ext2-clean"))
            ok = ok and code == 0
            detail += f"; e2fsck exit {code}"
        results.append((f"{kind}-clean", ok, f"{tool} X: -A on an undamaged volume: no errors, no restart",
                        detail, shots if kind == "ext2" else []))
        t = text(f"{kind}-no-letter")
        ok = "It has no drive letter: no restart needed." in t and "Restarting" not in t and "fixed" in t
        detail = "fixed, no restart" if ok else "output: " + " | ".join(t.strip().splitlines()[-3:])
        if kind == "ext2":
            code = e2fsck(extract(disk, "ext2-hidden"))
            ok = ok and code == 0
            detail += f"; e2fsck exit {code}"
        results.append((f"{kind}-no-letter", ok,
                        f"{tool} disk partition -A on a damaged volume without a letter: fixed, no restart", detail, []))
        t = text(f"{kind}-restart")
        ok = "Restarting in 10 seconds" in t and "ZDOS version" in t
        results.append((f"{kind}-restart", ok,
                        f"{tool} X: -A on a damaged volume with a letter: fixed, the countdown, ZDOS starts again",
                        "restarted" if ok else "output: " + " | ".join(t.strip().splitlines()[-3:]), []))
        t = text(f"{kind}-works")
        ok = re.search(r"^after\s*$", t, re.M) is not None
        detail = "AFTER.TXT written and read back" if ok else "output: " + " | ".join(t.strip().splitlines()[-3:])
        if kind == "ext2":
            after = subprocess.run(["debugfs", "-R", "cat /AFTER.TXT", extract(disk, "ext2-bad")],
                                   capture_output=True, text=True).stdout.strip()
            code = e2fsck(extract(disk, "ext2-bad"))
            ok = ok and after == "after" and code == 0
            detail += f"; on the host AFTER.TXT {after!r}, e2fsck exit {code}"
        results.append((f"{kind}-works", ok, "after the restart the repaired volume is writable", detail, []))
    results.append(("boots", boots == 3 and countdowns == 2,
                    "two restarts in all (3 boots, 2 countdowns): only the damaged volumes with a letter",
                    f"{boots} boots, {countdowns} countdowns", []))
    h.write_results(os.path.join(D, "RESULTS.md"), f"CHKEXT2 / CHKMFS -A test results ({h.NAME})", results)
    for name, ok, _, detail, _ in results:
        print(f"{'PASS' if ok else 'FAIL'}  {name}: {detail}", flush=True)
    sys.exit(1 if h.summary(results) else 0)


if __name__ == "__main__":
    main()
