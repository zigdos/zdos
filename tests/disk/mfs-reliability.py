#!/usr/bin/env python3
# Repeated MFS tests and recovery after abrupt VM power cuts.
# Usage: tests/disk/mfs-reliability.py [--rounds N] [--crash-cycles N]
# Default metal x86_64 (not UEFI); another edition (common.py):
#   ZDOS_EDITION=bios ZDOS_ARCH=x86 python3 tests/disk/mfs-reliability.py
# Works only on images under build/mfs-reliability[-<edition>]/. After
# a cut mid-write the volume isn't clean: ZDOS mounts it read only, so
# the recovery runs CHKMFS -F first.

import argparse
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import common as h  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = h.suite_dir("mfs-reliability")
MINIX = h.TEST_LETTER  # the test disk: p1 Minix, p2 FAT (the guest script)
FAT = h.next_letter(h.TEST_LETTER)
WORK = os.path.join(OUT, "work")
IMAGE = os.path.join(WORK, "mfs.img")
MFS_IMAGE = os.path.join(WORK, "mfs.fs")
FAT_IMAGE = os.path.join(WORK, "mfs_fat.fs")
TEST_SCRIPT = os.path.join(WORK, "reliability-guest.sh")
SHELL_TESTS = os.path.join(HERE, "mfs-tests.sh")
FUNCTIONAL_TESTS = os.path.join(HERE, "mfs-tests.py")
MFS_START = 2048
MFS_TIMEOUT = 600

CRASH_GUEST = r'''#!/bin/ash
# writerun.sh: rewrites files on the test volume until the host cuts the power:
mkdir crash_dir || exit 2
printf 'initial\n' > crash_dir/current.txt || exit 3
printf '0\n' > crash_tick.txt || exit 4
i=0
while [ "$i" -lt 20000 ]; do
    printf 'temporary payload %d\n' "$i" > crash_dir/new.tmp || exit 5
    mv crash_dir/new.tmp crash_dir/current.txt || exit 6
    printf 'secondary payload %d\n' "$i" > crash_dir/secondary.txt || exit 7
    rm crash_dir/secondary.txt || exit 8
    printf '%d\n' "$i" > crash_tick.txt || exit 9
    i=$((i + 1))
done
printf 'completed\n' > crash_tick.txt
'''

RECOVERY_GUEST = r'''#!/bin/ash
mkdir recovery_dir || exit 2
printf 'after crash\n' > recovery_dir/check.txt || exit 3
if [ "$(cat recovery_dir/check.txt)" = 'after crash' ]; then
    printf 'recovery ok\n' > recovery.log
else
    printf 'recovery failed\n' > recovery.log
fi
'''


def load_mfs_runner():
    spec = importlib.util.spec_from_file_location("mfs_tests", FUNCTIONAL_TESTS)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load mfs-tests.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mfs_runner = load_mfs_runner()


def command(*args, **kwargs):
    return subprocess.run(args, check=False, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, errors="replace", **kwargs)


def prepare_image():
    # 1 KiB blocks: fsck.minix checks no others (mfs-tests.sh makes 4 KiB)
    env = dict(os.environ, MFS_OUT=WORK, MFS_BLOCK_SIZE=os.environ.get("MFS_BLOCK_SIZE", "1024"))
    result = command("bash", SHELL_TESTS, "make", env=env)
    if result.returncode:
        raise RuntimeError("mfs-tests.sh make failed:\n" + result.stdout[-4000:])


def inject_guest_script(source, name):
    disk_sectors = os.path.getsize(IMAGE) // h.SECTOR
    problems, partitions = h.read_gpt(IMAGE, disk_sectors)
    if problems:
        raise RuntimeError("test GPT invalid: " + "; ".join(problems))
    used = [entry for entry in partitions if entry is not None]
    if len(used) < 2:
        raise RuntimeError("test disk is missing its FAT helper partition")
    _, first, last = used[1]
    sectors = last - first + 1
    subprocess.run(["dd", "if=" + IMAGE, "of=" + FAT_IMAGE, "bs=512",
                    "skip=" + str(first), "count=" + str(sectors),
                    "status=none"], check=True)
    with open(TEST_SCRIPT, "w", encoding="ascii", newline="\n") as f:
        f.write(source)
    result = command("mcopy", "-o", "-i", FAT_IMAGE, TEST_SCRIPT, "::/" + name)
    if result.returncode:
        raise RuntimeError("could not copy guest test to FAT partition:\n" + result.stdout)
    subprocess.run(["dd", "if=" + FAT_IMAGE, "of=" + IMAGE, "bs=512",
                    "seek=" + str(first), "conv=notrunc", "status=none"], check=True)


def minix_log(name):
    import struct

    with open(IMAGE, "rb") as f:
        f.seek(MFS_START * h.SECTOR + 1024)
        sb = f.read(1024)
        if len(sb) != 1024 or struct.unpack_from("<H", sb, 24)[0] != 0x4D5A:
            return ""
        u16 = lambda data, off: struct.unpack_from("<H", data, off)[0]
        u32 = lambda data, off: struct.unpack_from("<I", data, off)[0]
        block_size = u16(sb, 28)
        zones = u32(sb, 20)
        inode_count = u32(sb, 0)
        inode_start = 2 + u16(sb, 6) + u16(sb, 8)

        def zone_data(zone):
            if zone == 0 or zone >= zones:
                return bytes(block_size)
            f.seek(MFS_START * h.SECTOR + zone * block_size)
            data = f.read(block_size)
            return data if len(data) == block_size else bytes(block_size)

        def inode_data(number):
            if number < 1 or number > inode_count:
                return None
            per_block = block_size // 64
            offset = MFS_START * h.SECTOR + (inode_start + (number - 1) // per_block) * block_size
            offset += ((number - 1) % per_block) * 64
            f.seek(offset)
            raw = f.read(64)
            if len(raw) != 64:
                return None
            return u32(raw, 8), [u32(raw, 24 + 4 * i) for i in range(10)]

        def file_data(number):
            item = inode_data(number)
            if item is None:
                return b""
            size, pointers = item
            per = block_size // 4
            out = bytearray()
            for logical in range((size + block_size - 1) // block_size):
                if logical < 7:
                    zone = pointers[logical]
                elif logical - 7 < per:
                    zone = u32(zone_data(pointers[7]), (logical - 7) * 4) if pointers[7] else 0
                elif pointers[8]:
                    index = logical - 7 - per
                    leaf = u32(zone_data(pointers[8]), (index // per) * 4)
                    zone = u32(zone_data(leaf), (index % per) * 4) if leaf else 0
                else:
                    zone = 0
                out.extend(zone_data(zone))
            return bytes(out[:size])

        root = file_data(1)
        wanted = name.lower().encode("ascii")
        for off in range(0, len(root) - 63, 64):
            ent = root[off:off + 64]
            number = u32(ent, 0)
            entry_name = ent[4:64].split(b"\0", 1)[0].lower()
            if number and entry_name == wanted:
                return file_data(number).decode("ascii", "replace").replace("\r", "")
    return ""


def stop_qemu_at_update(cycle):
    """Run the mutating guest and kill QEMU as soon as its tick advances."""
    sock = os.path.join(WORK, f"crash-{cycle}.sock")
    if os.path.exists(sock):
        os.remove(sock)
    proc = subprocess.Popen(h.qemu_args(sock, test=IMAGE), cwd=h.ROOT,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        mon = h.Monitor(sock)
        time.sleep(h.BOOT_WAIT)
        for i, text in enumerate(("ASH", f"cd /{MINIX}:/", f"ash /{FAT}:/writerun.sh")):
            for ch in text:
                mon.cmd("sendkey " + h.key_name(ch))
                time.sleep(0.05)
            mon.cmd("sendkey ret")
            time.sleep((3, 2, 1)[i])

        deadline = time.time() + MFS_TIMEOUT
        while time.time() < deadline:
            text = minix_log("crash_tick.txt").strip()
            try:
                tick = int(text)
            except ValueError:
                if text == "completed":
                    raise RuntimeError("guest workload completed before the power cut")
            else:
                if tick >= cycle + 1:
                    # Stop at once, then kill QEMU without
                    # a guest shutdown or QEMU's disk flush:
                    mon.cmd("stop")
                    proc.kill()
                    proc.wait(timeout=10)
                    return tick
            time.sleep(0.25)
        raise RuntimeError("timed out waiting for the guest to begin its update loop")
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        if os.path.exists(sock):
            os.remove(sock)


def crash_once(cycle):
    prepare_image()
    inject_guest_script(CRASH_GUEST, "writerun.sh")
    sock = os.path.join(WORK, f"crash-{cycle}.sock")
    tick = stop_qemu_at_update(cycle)

    consistent, detail = check_fsck(f"crash-{cycle}-after-cut")
    leaked = not consistent and only_leaks(f"crash-{cycle}-after-cut")
    # A leak (in use, nothing uses it) is what a cut between the
    # map and the inode leaves: CHKMFS -F's to repair, on a volume
    # marked not clean; anything else is damage:
    if not consistent and (not leaked or minix_clean()):
        raise RuntimeError(f"post-cut filesystem is inconsistent; no repair was attempted; {detail}")

    inject_guest_script(RECOVERY_GUEST, "recovery.sh")
    recovery = {"done": False}

    def recovery_done():
        recovery["done"] = "recovery ok" in minix_log("recovery.log")
        return recovery["done"]

    # Cut mid-write: not clean, so read only until CHKMFS -F marks it
    # clean (yes to the repair, no to the restart):
    clean = minix_clean()
    repair = [] if clean else (h.command(f"CHKMFS {MINIX}: -F", 10) + h.answer("y", 10) + h.answer("n", 3))
    recovery_steps = ([ ("wait", 2) ] + h.command("ASH", 3) + repair +
                      h.command(f"cd /{MINIX}:/", 2) +
                      h.command(f"ash /{FAT}:/recovery.sh", 1) +
                      [("until", recovery_done, 90)])
    h.run_qemu(h.qemu_args(sock, test=IMAGE), recovery_steps,
               os.path.join(OUT, "shots", f"recovery-{cycle}"), sock)
    if not recovery["done"]:
        raise RuntimeError(f"filesystem did not complete recovery writes in cycle {cycle}")
    fsck = check_fsck(f"crash-{cycle}-after-recovery")
    if not fsck[0]:
        raise RuntimeError(f"fsck after recovery {cycle} failed: {fsck[1]}")

    saved = os.path.join(OUT, f"crash-{cycle}.img")
    shutil.copy2(IMAGE, saved)
    block_kib = int(os.environ.get("MFS_BLOCK_SIZE", "1024")) // 1024
    detail = (f"Minix V3 {block_kib} KiB block size; cut after guest update {tick}; "
              f"post-cut fsck {'clean' if consistent else 'only leaks'}; "
              f"{'marked clean' if clean else 'not marked clean: CHKMFS -F, then'} "
              "recovery write/read passed; final fsck clean")
    return detail


def only_leaks(label):
    # fsck.minix's problem lines, all leaks: in use with nothing
    # using it, or a link count above the names counted:
    with open(os.path.join(OUT, label + "-fsck.txt"), encoding="utf-8") as f:
        lines = [ln.strip() for ln in f if ln.strip()]
    problems = [ln for ln in lines if not ln.startswith(("Forcing", "-")) and not re.match(r"^\d+ ", ln)]

    def leak(ln):
        m = re.search(r"i_nlinks=(\d+), counted=(\d+)", ln)
        unused = "marked in use, no file uses it" in ln or "not used, marked used in the bitmap" in ln
        return unused or (m is not None and int(m[1]) > int(m[2]))
    return bool(problems) and all(leak(ln) for ln in problems)


def minix_clean():
    # The superblock's clean flag (bit 0 at byte 14):
    import struct

    with open(IMAGE, "rb") as f:
        f.seek(MFS_START * h.SECTOR + 1024)
        sb = f.read(32)
    return struct.unpack_from("<H", sb, 14)[0] & 1 != 0


def check_fsck(label):
    disk_sectors = os.path.getsize(IMAGE) // h.SECTOR
    _, partitions = h.read_gpt(IMAGE, disk_sectors)
    first_partition = next(entry for entry in partitions if entry is not None)
    _, first, last = first_partition
    subprocess.run(["dd", "if=" + IMAGE, "of=" + MFS_IMAGE, "bs=512",
                    "skip=" + str(first), "count=" + str(last - first + 1),
                    "status=none"], check=True)
    result = command("fsck.minix", "-f", "-v", MFS_IMAGE, stdin=subprocess.DEVNULL)
    path = os.path.join(OUT, label + "-fsck.txt")
    with open(path, "w", encoding="utf-8") as f:
        f.write(result.stdout)
    return result.returncode == 0, f"fsck.minix exit {result.returncode}; report: {path}"


def run_functional(round_number):
    result = command(sys.executable, FUNCTIONAL_TESTS, "run")
    text = result.stdout.strip()
    print(text, flush=True)
    if result.returncode:
        raise RuntimeError(f"existing MFS functional suite failed on round {round_number}")
    return text.splitlines()[-1] if text else "existing MFS suite passed"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rounds", type=int, default=1,
                        help="fresh-image functional suite repetitions (default: 1)")
    parser.add_argument("--crash-cycles", type=int, default=2,
                        help="abrupt power-cut and recovery cycles (default: 2; 0 disables)")
    args = parser.parse_args()
    if args.rounds < 1 or args.crash_cycles < 0:
        parser.error("--rounds must be >= 1 and --crash-cycles must be >= 0")
    if args.crash_cycles and os.environ.get("MFS_BLOCK_SIZE", "1024") != "1024":
        parser.error("fsck.minix only checks 1 KiB Minix blocks; run crash cycles with MFS_BLOCK_SIZE=1024")

    h.require_system()
    qemu = "qemu-system-x86_64" if h.EDITION != "bios" else "qemu-system-i386"
    for tool in (qemu, "mkfs.fat", "fsck.minix",
                 "mcopy", "sfdisk", "truncate", "dd"):
        if shutil.which(tool) is None:
            raise SystemExit(f"{tool} is missing")
    h.mkmfs3()  # mfs-tests.sh make formats with it
    os.makedirs(WORK, exist_ok=True)
    results = []
    keep_failed_image = False
    try:
        for round_number in range(1, args.rounds + 1):
            try:
                detail = run_functional(round_number)
                results.append((f"functional-{round_number}", True,
                                "Existing MFS guest operations and offline Minix consistency check", detail, []))
            except Exception as exc:
                results.append((f"functional-{round_number}", False,
                                "Existing MFS guest operations and offline Minix consistency check", str(exc), []))
                print(f"FAIL  functional-{round_number}: {exc}", flush=True)
                break
        functional_ok = all(item[1] for item in results)
        for cycle in range(1, args.crash_cycles + 1) if functional_ok else ():
            try:
                detail = crash_once(cycle)
                results.append((f"crash-{cycle}", True,
                                "Abrupt QEMU power cut; filesystem stays consistent; post-crash writes work",
                                detail, []))
                print(f"PASS  crash-{cycle}: {detail}", flush=True)
            except Exception as exc:
                keep_failed_image = os.path.exists(IMAGE)
                if keep_failed_image:
                    shutil.copy2(IMAGE, os.path.join(OUT, f"failed-crash-{cycle}.img"))
                results.append((f"crash-{cycle}", False,
                                "Abrupt QEMU power cut; filesystem stays consistent; post-crash writes work",
                                str(exc), []))
                print(f"FAIL  crash-{cycle}: {exc}", flush=True)
                break
    finally:
        for name in ("mfs.fs", "mfs_fat.fs", "reliability-guest.sh") + (() if keep_failed_image else ("mfs.img",)):
            path = os.path.join(WORK, name)
            if os.path.exists(path):
                os.remove(path)

    h.write_results(os.path.join(OUT, "RESULTS.md"), "MFS reliability results", results)
    sys.exit(1 if h.summary(results) else 0)


if __name__ == "__main__":
    main()
