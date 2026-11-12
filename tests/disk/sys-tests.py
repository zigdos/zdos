#!/usr/bin/env python3
# SYS in QEMU, each edition its way; the second boot starts from the
# disk SYS made bootable:
#   sys-tests.py               default metal x86_64 (tests/common.py)
#   ZDOS_EDITION=bios ZDOS_ARCH=x86 python3 tests/disk/sys-tests.py
# Metal, UEFI: an EFI system partition (its files, the firmware boot
# entry, then booted from it), one with older files and -O, and a
# plain FAT one (BOOTX64.EFI or BOOTAA64.EFI). BIOS: an active FAT16 partition behind ZDOS's MBR
# (boot sector, ZIGDOS.SYS, then booted from it: AUTOEXEC.CMD writes
# BOOTED.TXT). Results in build/sys-tests-<edition>/RESULTS.md.

import json
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import common as h  # noqa: E402

D = h.suite_dir("sys-tests")
MIB = 2048  # sectors
ESP_TYPE = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
BOOT_FILE = "BOOTAA64.EFI" if h.ARCH == "arm64" else "BOOTX64.EFI"
ENV = dict(os.environ, MTOOLS_SKIP_CHECK="1")


def mread(img, offset_sectors, name):
    # A file of the FAT volume at that offset, or None:
    r = subprocess.run(["mtype", "-i", f"{img}@@{offset_sectors * 512}", "::" + name], capture_output=True, env=ENV)
    return r.stdout if r.returncode == 0 else None


def put(part, name, data):
    path = os.path.join(D, "put.tmp")
    with open(path, "wb") as f:
        f.write(data)
    subprocess.run(["mmd", "-D", "s", "-i", part, "::" + os.path.dirname(name)], capture_output=True, env=ENV)
    subprocess.run(["mcopy", "-o", "-i", part, path, "::" + name], check=True, env=ENV)


def system_boot_file():
    # The system disk's own boot file (partition 1, its ESP):
    img = h.system_copy()
    r = subprocess.run(["sfdisk", "-J", img], capture_output=True, text=True, check=True)
    start = json.loads(r.stdout)["partitiontable"]["partitions"][0]["start"]
    return mread(img, start, "/EFI/BOOT/" + BOOT_FILE)


def no_bootindex(args):
    # QEMU's bootindex would put the system disk first again:
    return [a.replace(",bootindex=0", "") for a in args]


def efi_cases(results):
    want = system_boot_file()
    sock = os.path.join(D, "m.sock")
    vars_ = os.path.join(D, f"VARS-{h.NAME}.fd")

    # ESP: E: after DISKLET (the boot ESP is D:)
    esp = os.path.join(D, "esp.part")
    h.mkfs(esp, "32", 40 * 1024, "TESTESP")
    disk = h.gpt_from_parts(os.path.join(D, "esp.img"), 42 * MIB, [(esp, MIB, 40 * MIB, ESP_TYPE)])
    case = os.path.join(D, "esp")
    os.makedirs(case)
    h.run_qemu(h.edition_args(sock, test=disk), h.command("DISKLET", 3) + h.command("SYS E:", 4) + h.answer("y", 8)
               + [("shot", "sys")], case, sock)
    ours = mread(disk, MIB, "/EFI/ZDOS/ZIGDOS.EFI")
    results.append(("esp: \\EFI\\ZDOS\\ZIGDOS.EFI is the system's boot file", want is not None and ours == want,
                    "", "missing" if ours is None else "", [("sys", "SYS E:")]))
    fallback = mread(disk, MIB, "/EFI/BOOT/" + BOOT_FILE)
    results.append((f"esp: \\EFI\\BOOT\\{BOOT_FILE} too", fallback == want, "", "", []))
    raw = open(vars_, "rb").read()
    entry = "ZDOS".encode("utf-16-le") in raw and "ZIGDOS.EFI".encode("utf-16-le") in raw
    results.append(("esp: the firmware boot entry ZDOS", entry, "", "", []))
    shutil.copyfile(vars_, vars_ + ".saved")
    args = no_bootindex(h.edition_args(sock, test=disk))
    shutil.copyfile(vars_ + ".saved", vars_)
    h.run_qemu(args, h.command("DISKLET", 3) + h.command("DRIVES > E:\\DRIVES.TXT", 3) + [("shot", "booted")], case, sock)
    drives = (mread(disk, MIB, "/DRIVES.TXT") or b"").decode(errors="replace")
    line = next((ln for ln in drives.splitlines() if "TESTESP" in ln), "")
    results.append(("esp: the second boot starts from it", "(boot)" in line, "", line.strip() or "no DRIVES.TXT",
                    [("booted", "DRIVES")]))

    # -O: no questions; another system's fallback file and an older
    # ZDOS replaced in place (no ZDOSSYS.TMP):
    espo = os.path.join(D, "espo.part")
    h.mkfs(espo, "32", 40 * 1024, "TESTESP")
    subprocess.run(["mmd", "-i", espo, "::/EFI"], check=True, env=ENV)
    put(espo, "/EFI/BOOT/" + BOOT_FILE, b"another system")
    put(espo, "/EFI/ZDOS/ZIGDOS.EFI", b"an older ZDOS")
    disk = h.gpt_from_parts(os.path.join(D, "espo.img"), 42 * MIB, [(espo, MIB, 40 * MIB, ESP_TYPE)])
    case = os.path.join(D, "espo")
    os.makedirs(case)
    h.run_qemu(h.edition_args(sock, test=disk), h.command("DISKLET", 3) + h.command("SYS E: -O", 8)
               + [("shot", "sys")], case, sock)
    ours = mread(disk, MIB, "/EFI/ZDOS/ZIGDOS.EFI")
    fallback = mread(disk, MIB, "/EFI/BOOT/" + BOOT_FILE)
    tmp = mread(disk, MIB, "/EFI/ZDOS/ZDOSSYS.TMP")
    results.append(("esp -O: unasked, ZIGDOS.EFI and another system's fallback file replaced in place",
                    want is not None and ours == want and fallback == want and tmp is None, "",
                    f"ZIGDOS.EFI {'ok' if ours == want else 'old'}, fallback {'ok' if fallback == want else 'old'}"
                    + (", ZDOSSYS.TMP left" if tmp is not None else ""), [("sys", "SYS E: -O")]))

    # A plain FAT volume (a USB stick): D: at start
    stick = os.path.join(D, "stick.part")
    h.mkfs(stick, "16", 32 * 1024, "STICK")
    disk = h.gpt_from_parts(os.path.join(D, "stick.img"), 34 * MIB, [(stick, MIB, 32 * MIB, h.TYPE_BASIC)])
    case = os.path.join(D, "stick")
    os.makedirs(case)
    h.run_qemu(h.edition_args(sock, test=disk), h.command("DISKLET", 3) + h.command("SYS D:", 4) + h.answer("y", 8)
               + [("shot", "sys")], case, sock)
    got = mread(disk, MIB, "/EFI/BOOT/" + BOOT_FILE)
    results.append((f"stick: \\EFI\\BOOT\\{BOOT_FILE} is the system's boot file", want is not None and got == want,
                    "", "missing" if got is None else "", [("sys", "SYS D:")]))


def bios_case(results):
    # ZDOS's MBR, one active FAT16 partition with the floppy's files
    # and an AUTOEXEC.CMD that leaves a mark:
    part = os.path.join(D, "fat16.part")
    h.mkfs(part, "16", 32 * 1024, "SYSTEST")
    for name in ("/APPS/COMMAND.APP", "/CONF/SYSTEM.CFG"):
        put(part, name, mread(h.FLOPPY_IMG, 0, name))
    put(part, "/SCRIPTS/AUTOEXEC.CMD", b"@ECHO OFF\r\nECHO booted > C:\\BOOTED.TXT\r\n")
    disk = os.path.join(D, "fat16.img")
    h.make_disk(disk, 34 * MIB)
    with open(h.MBR_BIN, "rb") as f:
        code = f.read()[:440]
    with open(disk, "r+b") as f:
        f.write(code)
    h.write_table(disk, 0, [(0x06, MIB, 32 * MIB, 0x80)])
    with open(disk, "r+b") as d, open(part, "rb") as p:
        d.seek(MIB * 512)
        shutil.copyfileobj(p, d)
    before = h.read_sector(disk, MIB)
    case = os.path.join(D, "fat16")
    os.makedirs(case)
    sock = os.path.join(case, "m.sock")
    # Then again with -O: ZIGDOS.SYS is there, it asks nothing
    h.run_qemu(h.qemu_args(sock, test=disk), h.command(f"SYS {h.TEST_LETTER}:", 4) + h.answer("y", 6)
               + [("shot", "sys")] + h.command(f"SYS {h.TEST_LETTER}: -O", 6) + [("shot", "sys-o")], case, sock)
    after = h.read_sector(disk, MIB)
    results.append(("fat16: ZIGDOS.SYS copied", mread(disk, MIB, "/ZIGDOS.SYS") is not None, "", "",
                    [("sys", f"SYS {h.TEST_LETTER}:")]))
    results.append(("fat16: SYS -O again: unasked, in place (no ZDOSSYS.TMP)",
                    len(mread(disk, MIB, "/ZIGDOS.SYS") or b"") > 0 and mread(disk, MIB, "/ZDOSSYS.TMP") is None,
                    "", "", [("sys-o", f"SYS {h.TEST_LETTER}: -O")]))
    # The BPB kept, but "hidden sectors": where the volume starts
    hidden = int.from_bytes(after[28:32], "little")
    results.append(("fat16: boot code written, BPB kept, hidden sectors set",
                    after[11:28] == before[11:28] and after[32:36] == before[32:36] and hidden == MIB
                    and after[62:510] != before[62:510] and after[510:512] == b"\x55\xaa", "", f"hidden sectors {hidden}", []))
    h.run_qemu(h.qemu_args(sock, system=disk, system_snapshot=False), [("wait", 10), ("shot", "booted")], case, sock)
    booted = (mread(disk, MIB, "/BOOTED.TXT") or b"").decode(errors="replace")
    results.append(("fat16: it starts ZDOS (AUTOEXEC.CMD ran)", "booted" in booted, "", "", [("booted", "after the boot")]))


def main():
    shutil.rmtree(D, ignore_errors=True)
    os.makedirs(D)
    results = []
    if h.EDITION == "bios":
        h.require(h.SYSTEM_IMG, h.FLOPPY_IMG, h.MBR_BIN)
        bios_case(results)
    else:
        h.require_system()
        efi_cases(results)
    h.write_results(os.path.join(D, "RESULTS.md"), f"SYS ({h.NAME})", results)
    for name, ok, _, detail, _ in results:
        print(("PASS  " if ok else "FAIL  ") + name + (f": {detail}" if detail else ""))
    sys.exit(1 if h.summary(results) else 0)


if __name__ == "__main__":
    main()
