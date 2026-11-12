#!/usr/bin/env python3
# Minix V3 driver test: mfs-tests.sh makes the GPT disk;
# a short ash test runs in QEMU, then the image and the guest's
# PASS/FAIL log are checked.
#   mfs-tests.py run
# Default metal x86_64; another edition (common.py):
#   ZDOS_EDITION=bios ZDOS_ARCH=x86 python3 tests/disk/mfs-tests.py run
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import common as h  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "mfs-tests.sh")
OUT = h.suite_dir("mfs-tests")
IMG = os.path.join(OUT, "mfs.img")
MFS_START = 2048  # sectors, same as mfs-tests.sh
MFS_TIMEOUT = 600


def shell(command):
    env = dict(os.environ, MFS_OUT=OUT)
    p = subprocess.run(["bash", SCRIPT, command], env=env, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True)
    return p.returncode, p.stdout


def minix_log(log_name="fstest.log"):
    """Read a root log file from the first GPT partition while QEMU runs."""
    try:
        with open(IMG, "rb") as f:
            f.seek(MFS_START * h.SECTOR + 1024)
            sb = f.read(1024)
            u16 = lambda b, n: int.from_bytes(b[n:n + 2], "little")
            u32 = lambda b, n: int.from_bytes(b[n:n + 4], "little")
            if len(sb) != 1024 or u16(sb, 24) != 0x4D5A:
                return ""
            bs = u16(sb, 28)
            imap, zmap, ninodes = u16(sb, 6), u16(sb, 8), u32(sb, 0)
            zones = u32(sb, 20)
            inode_start = 2 + imap + zmap

            def read_block(zone):
                if not zone or zone >= zones:
                    return bytes(bs)
                f.seek(MFS_START * h.SECTOR + zone * bs)
                data = f.read(bs)
                return data if len(data) == bs else bytes(bs)

            def read_inode(number):
                if number < 1 or number > ninodes:
                    return None
                block_no = inode_start + (number - 1) // (bs // 64)
                offset = ((number - 1) % (bs // 64)) * 64
                f.seek(MFS_START * h.SECTOR + block_no * bs + offset)
                raw = f.read(64)
                if len(raw) != 64:
                    return None
                return u32(raw, 8), [u32(raw, 24 + 4 * i) for i in range(10)]

            def data_zone(zones_for_file, logical):
                per = bs // 4
                if logical < 7:
                    return zones_for_file[logical]
                logical -= 7
                if logical < per:
                    table = read_block(zones_for_file[7]) if zones_for_file[7] else bytes(bs)
                    return u32(table, logical * 4)
                logical -= per
                if not zones_for_file[8]:
                    return 0
                outer = read_block(zones_for_file[8])
                leaf_zone = u32(outer, (logical // per) * 4)
                if not leaf_zone:
                    return 0
                leaf = read_block(leaf_zone)
                return u32(leaf, (logical % per) * 4)

            def read_file(number):
                entry = read_inode(number)
                if entry is None:
                    return b""
                size, zone_map = entry
                result = bytearray()
                while len(result) < size:
                    logical = len(result) // bs
                    zone = data_zone(zone_map, logical)
                    data = read_block(zone) if zone else bytes(bs)
                    result.extend(data[:min(bs, size - len(result))])
                return bytes(result)

            root = read_inode(1)
            if root is None:
                return ""
            root_data = read_file(1)
            for pos in range(0, min(root[0], len(root_data)), 64):
                entry = root_data[pos:pos + 64]
                ino = u32(entry, 0)
                name = entry[4:64].split(b"\0", 1)[0]
                if ino and name.lower() == log_name.lower().encode():
                    return read_file(ino).decode("ascii", "replace").replace("\r", "")
    except (OSError, ValueError, IndexError):
        return ""
    return ""


def remove_artifacts(keep_image=False):
    for name in ("mfs.img", "mfs.fs", "mfs_fat.fs", "fstest.sh", "mfs_seed", "mfs_fat_seed"):
        if keep_image and name in ("mfs.img", "mfs.fs", "mfs_fat.fs"):
            continue
        path = os.path.join(OUT, name)
        if os.path.exists(path):
            if os.path.isdir(path):
                shutil.rmtree(path)
            else:
                os.remove(path)


def main():
    if len(sys.argv) != 2 or sys.argv[1] != "run":
        raise SystemExit("Usage: mfs-tests.py run")
    h.require_system()
    for tool in ("mkfs.fat", "mcopy", "sfdisk"):
        if shutil.which(tool) is None:
            raise SystemExit(f"{tool} is missing")
    h.mkmfs3()  # mfs-tests.sh make formats with it
    os.makedirs(OUT, exist_ok=True)
    shots = []
    passed = False
    detail = ""
    try:
        rc, output = shell("make")
        if rc:
            detail = "mfs-tests.sh make failed: " + (output.strip().splitlines()[-1] if output.strip() else "no output")
        else:
            # Through DRIVES (letters differ between the editions): the Minix
            # one has no label, the tools one is MFS_TOOLS. UEFI's and metal's
            # C: is Minix too (and not "boot": ZDOS started from the ESP).
            steps = [("wait", 2)] + h.command("ASH", 3) + h.cd_label("-i minix | grep -v C:", 2) + \
                [("shot", "01-ash", "ash in the Minix volume")] + \
                h.command("ash /$(DRIVES | grep MFS_TOOLS | awk '{print $1}')/fstest.sh", 1) + \
                [("until", lambda: "fstest done" in minix_log(), MFS_TIMEOUT),
                 ("wait", 2),
                 ("shot", "02-done", "fstest.sh's last steps and completion")]
            sock = os.path.join(OUT, "mfs-monitor.sock")
            shots = h.run_qemu(h.machine_args(sock, IMG, OUT), steps,
                               os.path.join(OUT, "shots"), sock, boot_wait=h.BOOT_WAIT)
            log = minix_log()
            with open(os.path.join(OUT, "guest-log.txt"), "w", encoding="utf-8") as f:
                f.write(log)
            rc, output = shell("check")
            with open(os.path.join(OUT, "check-output.txt"), "w", encoding="utf-8") as f:
                f.write(output)
            failures = [line for line in (log + "\n" + output).splitlines() if line.startswith("FAIL ")]
            done = "fstest done" in log
            passed = rc == 0 and done and not failures
            if passed:
                passed_lines = sum(line.startswith("PASS ") for line in log.splitlines())
                detail = f"{passed_lines} guest checks passed; Minix V3 structure and FAT checks passed (fsck.minix is 1 KiB only)"
            else:
                lines = output.strip().splitlines()
                useful = [line.strip() for line in lines if any(word in line.lower() for word in
                          ("error", "fail", "wrong", "invalid", "warning", "file system"))]
                host_detail = "; ".join(useful[-5:] if useful else lines[-4:]) or "host check failed"
                missing = "guest script did not finish" if not done else ""
                failed = ", ".join(line.split("(", 1)[0].removeprefix("FAIL ").strip() for line in failures[:5])
                if len(failures) > 5:
                    failed += f" (+{len(failures) - 5} more)"
                detail = "; ".join(x for x in (missing, failed, host_detail) if x)
    finally:
        # A failed run keeps its disk image for inspection:
        remove_artifacts(keep_image=not passed)

    result = ("mfs", passed, "Small-file I/O, directory operations, permissions and Minix V3 structure checks",
              detail, shots)
    h.write_results(os.path.join(OUT, "RESULTS.md"), f"Minix V3 test results ({h.EDITION})", [result])
    print(f"{'PASS' if passed else 'FAIL'}  mfs: {detail}")
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
