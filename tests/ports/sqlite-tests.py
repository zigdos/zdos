#!/usr/bin/env python3
# SQLite on ZDOS: SQLTEST and the sqlite3 shell on SQLDISK (FAT16) and
# SQLEXT (ext2), then SQLTEST CRASH with the power pulled mid-commit;
# after it CHKEXT2 -F on SQLEXT, a restart and SQLTEST CHECK. The
# host's SQLite checks the databases too.
#   sqlite-tests.py [EDITION...]   default from ZDOS_EDITION /
#   ZDOS_ARCH (tests/common.py), metal x86_64:
#   ZDOS_EDITION=uefi ZDOS_ARCH=x86_64 python3 tests/ports/sqlite-tests.py
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import common  # noqa: E402

OUT = os.path.join(common.BUILD, "sqlite-tests")
MB = 1024 * 1024
EXT_OFFSET = MB  # the ext2 partition starts at 1 MiB
CRASH_SECONDS = 30

EDITIONS = {
    # name: (build folder, arm64)
    "metal-x86_64": ("metal-x86_64", False),
    "uefi-x86_64": ("uefi-x86_64", False),
    "metal-arm64": ("metal-arm64", True),
    "uefi-arm64": ("uefi-arm64", True),
    "bios-x86": ("bios-x86", False),
}

# The shell's script (stdin), and what it must print:
SHELL_SQL = b"""CREATE TABLE fruit(name TEXT, n INTEGER);
INSERT INTO fruit VALUES('apple', 3), ('pear', 5), ('plum', 7);
.tables
SELECT name, n * 2 FROM fruit ORDER BY n DESC;
SELECT 'total', sum(n) FROM fruit;
"""
SHELL_WANT = ["fruit", "plum|14", "pear|10", "apple|6", "total|15"]


aavmf = common.aavmf


def make_disks(d):
    fat = os.path.join(d, "sqldisk.img")
    subprocess.run(["mkfs.fat", "-F", "16", "-n", "SQLDISK", "-C", fat, str(64 * 1024)], check=True, capture_output=True)
    sql = os.path.join(d, "SHELL.SQL")
    with open(sql, "wb") as f:
        f.write(SHELL_SQL)
    subprocess.run(["mcopy", "-i", fat, sql, "::/SHELL.SQL"], check=True)
    ext = os.path.join(d, "sqlext.img")
    with open(ext, "wb") as f:
        f.truncate(65 * MB)
    subprocess.run(["sfdisk", "-q", ext], input=b"start=2048, type=83\n", check=True, capture_output=True)
    subprocess.run(["mke2fs", "-q", "-F", "-t", "ext2", "-L", "SQLEXT", "-E", f"offset={EXT_OFFSET}", ext, "64M"],
                   check=True, capture_output=True)
    return fat, ext


def qemu(edition, d, sock, system, fat, ext):
    folder, arm = EDITIONS[edition]
    serial = ["-serial", f"file:{os.path.join(d, 'serial.txt')}", "-monitor", f"unix:{sock},server,nowait"]
    if edition == "bios-x86":
        return ["qemu-system-i386", "-machine", "pc", "-cpu", "pentium3", "-smp", "2", "-m", "256M",
                "-drive", f"file={system},format=raw,if=ide,index=0",
                "-drive", f"file={fat},format=raw,if=ide,index=1",
                "-drive", f"file={ext},format=raw,if=ide,index=2",
                "-boot", "c", "-display", "none", "-rtc", "base=localtime", "-nic", "none"] + serial
    code, settings = aavmf() if arm else common.ovmf()
    own = os.path.join(d, "VARS.fd")
    if not os.path.exists(own):
        shutil.copyfile(settings, own)
    base = [
        "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
        "-drive", f"if=pflash,format=raw,file={own}",
        "-drive", f"file={system},if=none,id=nvme0,format=raw",
        "-device", "nvme,serial=ZDOS0001,drive=nvme0,bootindex=0",
        "-device", "qemu-xhci", "-device", "usb-kbd",
        "-drive", f"file={fat},if=none,id=sqldisk,format=raw",
        "-drive", f"file={ext},if=none,id=sqlext,format=raw",
        "-display", "none", "-rtc", "base=localtime", "-nic", "none",
    ] + serial
    if arm:
        gfx = ["-device", "ramfb"] if edition.startswith("metal") else ["-device", "virtio-gpu-pci"]
        return (["qemu-system-aarch64", *common.arm_machine(), "-smp", "2", "-m", "512M"]
                + gfx + base + ["-device", "usb-storage,drive=sqldisk", "-device", "usb-storage,drive=sqlext"])
    return (["qemu-system-x86_64", *common.x86_accel(), "-machine", "q35", "-smp", "2", "-m", "512M", "-vga", "std",
             "-device", "ide-hd,drive=sqldisk,bus=ide.1", "-device", "ide-hd,drive=sqlext,bus=ide.2"] + base)


def mread(img, name):
    r = subprocess.run(["mtype", "-i", img, "::/" + name], capture_output=True)
    return r.stdout if r.returncode == 0 else None


def fat_file(img, name, to):
    return subprocess.run(["mcopy", "-n", "-o", "-i", img, "::/" + name, to], capture_output=True).returncode == 0


def ext_file(img, name, to, d):
    part = os.path.join(d, "sqlext-part.img")
    with open(img, "rb") as src, open(part, "wb") as dst:
        src.seek(EXT_OFFSET)
        shutil.copyfileobj(src, dst)
    r = subprocess.run(["debugfs", "-R", f"dump {name} {to}", part], capture_output=True)
    os.remove(part)
    return r.returncode == 0 and os.path.exists(to)


def run_edition(edition):
    d = os.path.join(OUT, edition)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    folder, arm = EDITIONS[edition]
    system = os.path.join(d, "system.img")
    shutil.copyfile(os.path.join(common.BUILD, folder, "system.img"), system)
    fat, ext = make_disks(d)
    sock = os.path.join(d, "monitor.sock")
    boot = 60 if arm else 20 if edition == "bios-x86" else 35

    def has(name, marker):
        return lambda: marker in (mread(fat, name) or b"")

    # The tests, the shell, then commits until QEMU quits: the power goes:
    began = time.time()
    steps = (common.command("SQLTEST", 5)
             + [("until", has("SQLTEST.LOG", b"# SQLTEST:"), 600), ("wait", 2)]
             + common.command('SQLITE3 %SQLDISK%\\SQLTEST\\TEST.DB "SELECT count(*), sum(id) FROM t;" > %SQLDISK%\\SHELL1.TXT', 10)
             + common.command("SQLITE3 %SQLDISK%\\SHELL.DB < %SQLDISK%\\SHELL.SQL > %SQLDISK%\\SHELL2.TXT", 10)
             + [("shot", "tests", "after SQLTEST and the shell")]
             + common.command("SQLTEST CRASH", CRASH_SECONDS)
             + [("shot", "crash", "the moment the power goes")])
    common.run_qemu(qemu(edition, d, sock, system, fat, ext), steps, d, sock, boot_wait=boot)

    # The drives' letters, from the startup list:
    serial = os.path.join(d, "serial.txt")
    shutil.copyfile(serial, os.path.join(d, "serial-crash.txt"))
    letters = drive_letters(serial)
    fat_at, ext_at = letters.get("SQLDISK", "D"), letters.get("SQLEXT", "E")

    # Power back: an ext2 drive cut mid-change is read only until
    # CHKEXT2 -F and a restart, as the startup list says. Its
    # questions: fix (Y), restart now (N); a clean drive asks none:
    steps = (common.command(f"CHKEXT2 {ext_at}: -F > {fat_at}:\\CHKEXT2.TXT", 10)
             + common.answer("Y", 20) + common.answer("N", 3)
             + [("until", lambda: bool(mread(fat, "CHKEXT2.TXT")), 60), ("wait", 2)]
             + common.command("SHUTDOWN", 15))
    try:
        common.run_qemu(qemu(edition, d, sock, system, fat, ext), steps, d, sock, boot_wait=boot)
    except BrokenPipeError:
        pass  # SHUTDOWN ended QEMU before its monitor was told to quit
    shutil.copyfile(serial, os.path.join(d, "serial-repair.txt"))
    cut_mid_change = f"Drive {ext_at}: unfinished change" in open(serial, errors="replace").read()

    # After the restart:
    steps = (common.command("SQLTEST CHECK", 5)
             + [("until", has("CHECK.LOG", b"# SQLTEST:"), 300), ("wait", 2),
                ("shot", "check", "SQLTEST CHECK after the power failure")]
             + common.command("SHUTDOWN", 15))
    try:
        common.run_qemu(qemu(edition, d, sock, system, fat, ext), steps, d, sock, boot_wait=boot)
    except BrokenPipeError:
        pass  # SHUTDOWN ended QEMU before its monitor was told to quit
    return check(edition, d, fat, ext, time.time() - began, cut_mid_change)


def drive_letters(serial):
    # "  E:  SQLEXT      ext2 ...": label -> letter
    found = {}
    for line in open(serial, errors="replace"):
        m = re.match(r"\s+([A-Z]):\s+(SQLDISK|SQLEXT)\s", line)
        if m:
            found[m.group(2)] = m.group(1)
    return found


def tap(results, prefix, text):
    for line in text.splitlines():
        if line.startswith("ok - ") or line.startswith("not ok - "):
            results.append((prefix + line.split(" - ", 1)[1], line.startswith("ok"), ""))


def host_check(path):
    # This computer's SQLite on a copy: whole, and what is in it:
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        return db.execute("PRAGMA integrity_check").fetchone()[0], db
    except sqlite3.DatabaseError as e:
        return str(e), None


def check(edition, d, fat, ext, seconds, cut_mid_change):
    results = []

    def result(name, ok, detail=""):
        results.append((name, ok, detail))

    for name in ("SQLTEST.LOG", "CHECK.LOG", "SHELL1.TXT", "SHELL2.TXT", "CHKEXT2.TXT"):
        with open(os.path.join(d, name), "wb") as f:
            f.write(mread(fat, name) or b"")
    log = open(os.path.join(d, "SQLTEST.LOG"), errors="replace").read()
    result("SQLTEST finished", "# SQLTEST:" in log)
    tap(results, "SQLTEST ", log)
    shell1 = open(os.path.join(d, "SHELL1.TXT"), errors="replace").read()
    result("sqlite3 shell: a query from the command line", "2001|2003001" in shell1, shell1.strip()[:80])
    shell2 = open(os.path.join(d, "SHELL2.TXT"), errors="replace").read()
    missing = [w for w in SHELL_WANT if w not in shell2]
    result("sqlite3 shell: a script from stdin (.tables, SELECT)", not missing, "missing: " + ", ".join(missing))
    chk = open(os.path.join(d, "CHKEXT2.TXT"), errors="replace").read().strip()
    result("SQLEXT checked after the power failure (CHKEXT2 -F)", bool(chk),
           ("it was cut mid-change: " if cut_mid_change else "it was clean: ") + (chk.splitlines()[-1] if chk else "no output"))
    check_log = open(os.path.join(d, "CHECK.LOG"), errors="replace").read()
    result("SQLTEST CHECK finished", "# SQLTEST:" in check_log)
    tap(results, "after the power failure: ", check_log)

    # The same databases through this computer's SQLite:
    for disk, get in (("SQLDISK", lambda n, to: fat_file(fat, n, to)),
                      ("SQLEXT", lambda n, to: ext_file(ext, "/" + n, to, d))):
        for name, test in (("TEST.DB", "test"), ("CRASH.DB", "crash")):
            local = os.path.join(d, f"{disk}-{name}")
            if not get("SQLTEST/" + name, local):
                result(f"{disk} {name} copied out", False)
                continue
            verdict, db = host_check(local)
            result(f"{disk} {name}: this computer's integrity_check", verdict == "ok", verdict)
            if db is None:
                continue
            if test == "test":
                rows = db.execute("SELECT count(*), sum(id) FROM t").fetchone()
                result(f"{disk} TEST.DB: this computer reads its rows", rows == (2001, 2003001), str(rows))
            else:
                counter = db.execute("SELECT n FROM counter").fetchone()[0]
                rows, last = db.execute("SELECT count(*), max(n) FROM log").fetchone()
                result(f"{disk} CRASH.DB: {counter} commits kept, none half", counter == rows == last and counter >= 10,
                       f"counter {counter}, rows {rows}, last {last}")
            db.close()

    # For the report: a FAT volume cut mid-write may need CHKDSK, which is
    # no SQLite failure:
    r = subprocess.run(["fsck.fat", "-n", fat], capture_output=True, text=True)
    result("SQLDISK's FAT after the power failure (fsck.fat -n)", r.returncode == 0,
           (r.stdout + r.stderr).strip().splitlines()[-1] if r.returncode else "")

    passed = sum(1 for r in results if r[1])
    with open(os.path.join(d, "results.md"), "w") as f:
        f.write(f"# SQLite on {edition}\n\n{passed} of {len(results)} passed ({seconds:.0f} s)\n\n")
        for name, ok, detail in results:
            f.write(f"- {'PASS' if ok else 'FAIL'} {name}{': ' + detail if detail and not ok else ''}\n")
    print(f"{edition}: {passed} of {len(results)} passed ({seconds:.0f} s)")
    for name, ok, detail in results:
        if not ok:
            print(f"  FAIL {name}{': ' + detail if detail else ''}")
    return passed == len(results)


def main():
    editions = sys.argv[1:] or [common.NAME]
    for e in editions:
        if e not in EDITIONS:
            raise SystemExit(f"unknown edition {e} ({', '.join(EDITIONS)})")
    ok = all([run_edition(e) for e in editions])
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
