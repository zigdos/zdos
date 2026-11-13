#!/usr/bin/env python3
# ZC driven by keys on a FAT and a Minix volume: copy merged into
# an existing folder (overwrite with All), make folder, move merged,
# quick search (Ctrl+S; Alt+letter, then a copy), Shift+Down
# selection, delete, sort, help, viewer (F3; Enter only on text
# files), command line, Ctrl+O. The Minix run uses the dark theme.
# checks.sh (on the test disk) checks the files after each run and
# writes OK / BAD lines to RESFAT.TXT and RESMFS.TXT on the FAT
# volume, which the host reads. The screens are kept as screenshots.
#   ZDOS_EDITION=bios ZDOS_ARCH=x86 python3 tests/apps/zc-tests.py
#   ZDOS_EDITION=metal ZDOS_ARCH=x86_64 python3 tests/apps/zc-tests.py
#   ZDOS_EDITION=uefi ZDOS_ARCH=x86_64 python3 tests/apps/zc-tests.py
# Results: build/zc-tests[-EDITION]/RESULTS.md.
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import common as h  # noqa: E402

OUT = h.suite_dir("zc-tests")
DISK = os.path.join(OUT, "test.img")
MIB = 2048  # sectors
# p1 FAT (labelled), p2 Minix (found by its size in DRIVES):
FAT_START, FAT_SECTORS = 2048, 64 * MIB
MFS_START, MFS_MIB = 2048 + 64 * MIB, 77
DISK_SECTORS = MFS_START + MFS_MIB * MIB + MIB

CHECKS = r"""#!/C:/APPS/ASH.APP
# checks.sh: made by tests/apps/zc-tests.py
t() { name=$1; shift; if "$@" > /dev/null 2>&1; then echo "OK $name"; else echo "BAD $name"; fi; }
t copy-new-file      diff SRC/a.txt DST/SRC/a.txt
t copy-overwrite     diff SRC/b.txt DST/SRC/b.txt
t copy-into-subdir   diff SRC/sub/c.txt DST/SRC/sub/c.txt
t copy-big-file      diff SRC/big.bin DST/SRC/big.bin
t merge-kept-old     [ -f DST/SRC/sub/old.txt ]
t source-kept        [ -f SRC/a.txt ]
t mkdir              [ -d NEWDIR ]
t move-source-gone   [ ! -e MOVESRC ]
t move-merged-file   [ -f DST/MOVESRC/x.txt ]
t move-merged-deep   [ -f DST/MOVESRC/deep/y.txt ]
t move-kept-old      [ -f DST/MOVESRC/deep/z.txt ]
t delete-tree        [ ! -e TRASH ]
t alt-search-copy    [ -d DST/NEWDIR ]
t select-copy-f1     [ -f DST/f1.txt ]
t select-copy-f2     [ -f DST/f2.txt ]
t select-not-f3      [ ! -e DST/f3.txt ]
t command-line       grep -q ZCCMD CMDLINE.TXT
t hidden-command     grep -q ZCHIDDEN HIDDEN.TXT
t zc-cfg-made        [ -f "$HOME/ZC.CFG" ]
t zc-cfg-theme       grep -q "theme=$1" "$HOME/ZC.CFG"
echo "DONE"
"""


def tree(root):
    # The same files on both volumes:
    def put(rel, data):
        path = os.path.join(root, *rel.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
    put("SRC/a.txt", b"new a\n")
    put("SRC/b.txt", b"new b, longer than the old one\n" * 20)
    put("SRC/sub/c.txt", b"new c\n")
    put("SRC/big.bin", bytes(range(256)) * (4 * 1024 * 4))  # 4 MiB
    put("DST/SRC/b.txt", b"old b\n")
    put("DST/SRC/sub/old.txt", b"old, stays\n")
    put("MOVESRC/x.txt", b"x\n")
    put("MOVESRC/deep/y.txt", b"y\n")
    put("DST/MOVESRC/deep/z.txt", b"z, stays\n")
    put("TRASH/t1.txt", b"t1\n")
    put("TRASH/inner/t2.txt", b"t2\n")
    for n in (1, 2, 3):
        put(f"f{n}.txt", f"file {n}\n".encode())
    put("lib.zdl", bytes(range(256)) * 8)
    put("readme.txt", "".join(f"Line {i}: the viewer shows this text.\n" for i in range(1, 200)).encode())
    put("checks.sh", CHECKS.encode())


def make():
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    files = os.path.join(OUT, "files")
    tree(files)
    fat = os.path.join(OUT, "fat.part")
    h.mkfs(fat, "16", FAT_SECTORS // 2, "ZCFAT")
    env = dict(os.environ, MTOOLS_SKIP_CHECK="1")
    for name in sorted(os.listdir(files)):
        subprocess.run(["mcopy", "-s", "-i", fat, os.path.join(files, name), "::/"], check=True, env=env)
    mfs = os.path.join(OUT, "mfs.part")
    h.mfsdir(mfs, MFS_MIB * MIB, files)
    h.gpt_from_parts(DISK, DISK_SECTORS, [(fat, FAT_START, FAT_SECTORS, h.TYPE_BASIC),
                                          (mfs, MFS_START, MFS_MIB * MIB, h.TYPE_LINUX)])
    os.remove(fat)
    os.remove(mfs)


def keys(*names, wait=0.6):
    out = []
    for n in names:
        out += [("key", n), ("wait", wait)]
    return out


def search(text):
    # Ctrl+S, the name, Esc: the cursor stays on it.
    return keys("ctrl-s") + [("text", text), ("wait", 1)] + keys("esc")


def zc_run(tag):
    # One run of ZC in the volume's root; tag: fat or mfs.
    s = h.command("ZC", 6)
    s += [("shot", f"{tag}-01-panels", "both panels in the volume's root")]
    # The right panel into DST:
    s += keys("tab", "ret", "tab", wait=1)
    # SRC copied into DST (DST\SRC exists: merged; b.txt: All):
    s += search("SRC") + keys("f5", wait=2) + keys("ret", wait=6)
    s += [("shot", f"{tag}-02-overwrite", "the overwrite question for b.txt")]
    s += keys("a", wait=25)
    s += [("shot", f"{tag}-03-copied", "after the copy: DST in the right panel")]
    # A folder:
    s += keys("f7", wait=2) + [("text", "NEWDIR"), ("wait", 1)] + keys("ret", wait=3)
    # MOVESRC moved into DST (merged):
    s += search("MOVESRC") + keys("f6", wait=2) + keys("ret", wait=8)
    # TRASH deleted:
    s += search("TRASH") + keys("f8", wait=2) + keys("ret", wait=5)
    # f1.txt and f2.txt selected with Shift+Down, copied to DST:
    s += search("f1") + keys("shift-down", "shift-down")
    s += [("shot", f"{tag}-05-selected", "f1.txt and f2.txt selected (magenta)")]
    s += keys("f5", wait=2) + keys("ret", wait=6)
    # Alt+N finds NEWDIR, which is copied to DST:
    s += keys("alt-n", wait=1) + keys("esc")
    s += [("shot", f"{tag}-04-alt-search", "cursor on NEWDIR (Alt+N)")]
    s += keys("f5", wait=2) + keys("ret", wait=4)
    # Sort by size, largest first; then back to names:
    s += keys("f9", wait=2) + keys("down", "down", "down") + keys("ret", wait=2)
    s += [("shot", f"{tag}-06-sorted", "sorted by size, largest first: Size with an arrow")]
    s += keys("f9", wait=2) + keys("home", "ret", wait=2)
    s += keys("f1", wait=2) + [("shot", f"{tag}-07-help", "F1's key list")] + keys("esc", wait=2)
    s += search("readme") + keys("f3", wait=3)
    s += [("shot", f"{tag}-08-viewer", "readme.txt in the viewer (F3)")] + keys("esc", wait=2)
    # Enter views text files (textfiles=), not others:
    s += search("readme") + keys("ret", wait=3)
    s += [("shot", f"{tag}-08b-enter-text", "readme.txt in the viewer (Enter)")] + keys("esc", wait=2)
    s += search("lib") + keys("ret", wait=3)
    s += [("shot", f"{tag}-08c-enter-binary", "panels, no viewer: Enter on lib.zdl does nothing")]
    s += keys("esc", wait=1)
    # The command line, then Ctrl+O's:
    s += [("text", "ECHO ZCCMD > CMDLINE.TXT"), ("wait", 1)] + keys("ret", wait=5)
    s += keys("ctrl-o", wait=3)
    s += [("shot", f"{tag}-09-hidden", "panels hidden: the screen before, command line and keys")]
    s += [("text", "ECHO ZCHIDDEN > HIDDEN.TXT"), ("wait", 1)] + keys("ret", wait=5)
    s += [("shot", f"{tag}-10-hidden-run", "the command ran; command line and keys at the bottom")]
    s += keys("ctrl-o", wait=3)
    s += [("shot", f"{tag}-11-back", "the panels again")]
    s += keys("f10", wait=2) + keys("ret", wait=4)
    return s


def steps():
    fat = "/$(DRIVES | grep ZCFAT | awk '{print $1}')"
    mfs = f"/$(DRIVES | grep 'minix.* {MFS_MIB} MB' | awk '{{print $1}}')"
    s = h.command("ash", 4)
    s += h.command(f"cd {fat}/", 3)
    s += zc_run("fat")
    s += h.command("ash checks.sh blue > RESFAT.TXT", 15)
    # The Minix run in the dark theme:
    s += h.command(f"sed 's/theme=blue/theme=dark/' \"$HOME/ZC.CFG\" > {fat}/DARK.CFG", 3)
    s += h.command(f"cp {fat}/DARK.CFG \"$HOME/ZC.CFG\"", 3)
    s += h.command(f"cd {mfs}/", 3)
    s += zc_run("mfs")
    s += h.command(f"ash checks.sh dark > {fat}/RESMFS.TXT", 15)
    s += h.command("DRIVES", 3) + [("shot", "drives", "the drives, if a volume wasn't found")]
    return s


def results_of(name):
    data = h.mtools_read(DISK, FAT_START, name)
    if data is None:
        raise SystemExit("mtools (mtype) is needed")
    return data.decode("utf-8", "replace").replace("\r", "")


def main():
    h.require_system()
    make()
    sock = os.path.join(OUT, "mon.sock")
    shots = h.run_qemu(h.machine_args(sock, DISK, OUT), steps(), os.path.join(OUT, "shots"), sock)

    results = []
    for fs, name in (("fat", "RESFAT.TXT"), ("mfs", "RESMFS.TXT")):
        text = results_of(name)
        lines = re.findall(r"^(OK|BAD) (\S+)$", text, re.M)
        if not lines:
            results.append((f"{fs}: checks ran", False, "OK / BAD lines in " + name,
                            "none: ZC or the checks didn't run (see the screenshots)", []))
        for verdict, check in lines:
            results.append((f"{fs}: {check}", verdict == "OK", "OK", verdict, []))
        if lines and "DONE" not in text:
            results.append((f"{fs}: checks finished", False, "DONE", "missing", []))
    results.append(("screens", None, "as the notes say", "", shots))
    h.write_results(os.path.join(OUT, "RESULTS.md"), f"ZC tests: {h.NAME}", results)
    failed = h.summary(results)
    for name, passed, *_ in results:
        if passed is False:
            print(f"  FAIL {name}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
