#!/usr/bin/env python3
# ext2 test suite, unattended: ext2-tests.sh make builds the image, ash
# runs the test script in QEMU, ext2-tests.sh check reads it back.
#   ext2-tests.py run [BLOCK_SIZE...] [big]
# "big": files past 2, 4, 16 and 18 GiB (sparse, a few GB on the host).
# Default metal x86_64; another edition (common.py):
#   ZDOS_EDITION=uefi ZDOS_ARCH=x86_64 python3 tests/disk/ext2-tests.py run
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import common as h  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "ext2-tests.sh")
OUT = h.suite_dir("ext2-tests")
SHOTS = os.path.join(OUT, "shots")
IMG = os.path.join(OUT, "ext2.img")
BIG_IMG = os.path.join(OUT, "ext2big.img")
BLOCKS = ("1024", "4096", "65536")
BIG_LABELS = ("ZBIG2G", "ZBIG4G", "ZBIG18")
# Seconds to wait for the scripts in ZDOS:
ZTEST_TIME = 900
ZBIG_TIME = 1200


def script(command, big=False, block=None):
    # (exit code, output)
    env = dict(os.environ, EXT2_OUT=OUT, BIG="1" if big else "0")
    if block:
        env["BLOCK"] = block
    p = subprocess.run(["bash", SCRIPT, command], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True)
    return p.returncode, p.stdout


def partition_starts(image):
    # In entry order.
    problems, entries = h.read_gpt(image, os.path.getsize(image) // h.SECTOR)
    if problems:
        raise SystemExit(f"{image}: " + "; ".join(problems))
    return [e[1] for e in entries if e is not None]


def log_says(image, start, log, last):
    # done(): the volume at start has log, and its text has the line last.
    def done():
        p = subprocess.run(["debugfs", "-R", f"cat /{log}", f"{image}?offset={start * h.SECTOR}"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return any(line.strip() == last for line in p.stdout.decode(errors="replace").splitlines())
    return done


def clean_up():
    # The big seed folders hold sparse files of many GB:
    for name in os.listdir(OUT):
        path = os.path.join(OUT, name)
        if name.endswith((".img", ".fs")):
            os.remove(path)
        elif name in ("ext2_seed", "ext2big_seed"):
            shutil.rmtree(path)


def check_result(name, rc, output):
    # Saved in full:
    with open(os.path.join(OUT, f"{name}-check.txt"), "w") as f:
        f.write(output)
    fails = [line.strip()[5:] for line in output.splitlines() if line.strip().startswith("FAIL ")]
    total = next((line for line in reversed(output.splitlines()) if line.startswith("passed ")), "no summary")
    detail = total + ("" if not fails else ": " + "; ".join(fails[:6]) + (" ..." if len(fails) > 6 else ""))
    return rc == 0, detail


def run_normal(block):
    name = f"block{block}"
    rc, out = script("make", block=block)
    if rc != 0:
        return name, False, "ext2-tests.sh make failed: " + out.strip().splitlines()[-1], []
    done = {"ok": False}
    finished = log_says(IMG, partition_starts(IMG)[0], "fstest.log", "fstest done")

    def until():
        done["ok"] = finished()
        return done["ok"]

    # Volumes by label (letters differ between BIOS and UEFI); fstest.sh
    # finds ZFAT itself:
    steps = [("wait", 2)] + h.command("ASH", 3) + h.cd_label("ZTEST", 2) + \
        [("shot", "01-ash", "ash in the ext2 volume (ZTEST)")] + \
        h.command("fstest.sh", 1) + [("until", until, ZTEST_TIME), ("wait", 2)] + \
        [("shot", "02-done", "fstest.sh's last steps: PASS lines, fstest done")]
    sock = os.path.join(OUT, f"mon-{name}.sock")
    shots = h.run_qemu(h.machine_args(sock, IMG, OUT), steps, os.path.join(SHOTS, name), sock,
                       boot_wait=h.BOOT_WAIT)
    rc, out = script("check")
    passed, detail = check_result(name, rc, out)
    if not done["ok"]:
        passed = False
        detail = f"fstest.sh didn't finish in {ZTEST_TIME} s; " + detail
    return name, passed, detail, shots


def run_big():
    name = "big"
    rc, out = script("make", big=True)
    if rc != 0:
        return name, False, "BIG=1 ext2-tests.sh make failed: " + out.strip().splitlines()[-1], []
    starts = partition_starts(BIG_IMG)
    finished = {}
    steps = [("wait", 2)] + h.command("ASH", 3)
    for i, label in enumerate(BIG_LABELS):
        done = log_says(BIG_IMG, starts[i], "bigfiles.log", "bigfiles done")

        def until(done=done, label=label):
            finished[label] = done()
            return finished[label]

        steps += h.cd_label(label, 2) + h.command("bigfiles.sh", 1) + \
            [("until", until, ZBIG_TIME), ("wait", 2),
             ("shot", f"0{i + 1}-{label.lower()}", f"bigfiles.sh on {label}")]
    sock = os.path.join(OUT, f"mon-{name}.sock")
    shots = h.run_qemu(h.machine_args(sock, BIG_IMG, OUT), steps, os.path.join(SHOTS, name), sock,
                       boot_wait=h.BOOT_WAIT)
    rc, out = script("check", big=True)
    passed, detail = check_result(name, rc, out)
    late = [label for label in BIG_LABELS if not finished.get(label)]
    if late:
        passed = False
        detail = f"bigfiles.sh didn't finish on {', '.join(late)}; " + detail
    return name, passed, detail, shots


EXPECT = {
    "big": "bigfiles.sh on ZBIG2G, ZBIG4G, ZBIG18: files past 2, 4, 16 and 18 GiB read, appended, deleted; "
           "e2fsck clean and every change as expected",
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] != "run" or any(a not in BLOCKS + ("big",) for a in sys.argv[2:]):
        print("Usage: ext2-tests.py run [1024 | 4096 | 65536 | big ...]")
        sys.exit(1)
    h.require_system()
    for tool in ("debugfs", "e2fsck", "mke2fs", "sfdisk", "mkfs.fat", "mcopy", "mattrib", "mtype"):
        if shutil.which(tool) is None:
            raise SystemExit(f"{tool} is missing (e2fsprogs, util-linux, dosfstools, mtools)")
    os.makedirs(OUT, exist_ok=True)
    wanted = sys.argv[2:] or list(BLOCKS) + ["big"]
    results = []
    for what in wanted:
        try:
            if what == "big":
                name, passed, detail, shots = run_big()
            else:
                name, passed, detail, shots = run_normal(what)
        finally:
            clean_up()
        expect = EXPECT.get(name, f"fstest.sh with {what}-byte blocks: every step PASS, e2fsck clean, "
                                  "every change (files, links, permissions, FAT attributes) as expected")
        results.append((name, passed, expect, detail, shots))
        print(f"{'PASS' if passed else 'FAIL'}  {name}: {detail}", flush=True)
    h.write_results(os.path.join(OUT, "RESULTS.md"), f"ext2 test results ({h.EDITION})", results)
    sys.exit(1 if h.summary(results) else 0)


if __name__ == "__main__":
    main()
