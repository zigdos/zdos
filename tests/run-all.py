#!/usr/bin/env python3
# ZDOS's own tests except the disk and port suites, unattended,
# on metal x86_64 (default), ARM64 or BIOS; another (tests/common.py):
#   ZDOS_ARCH=arm64 python3 tests/run-all.py
#   ZDOS_EDITION=bios ZDOS_ARCH=x86 python3 tests/run-all.py
#   run-all.py [--only GROUP,...] [--skip GROUP,...] [--no-host] [--list]
#
# GUEST TESTS (TESTS below) run inside one VM:
#   1. The host makes a test disk: D: FAT (the script),
#      E: Minix and F: FAT (the volumes the tests work on; on
#      BIOS E:, F:, G:, after its data disk's D:).
#   2. It writes runall.sh to D: and types "ash /D:/runall.sh".
#   3. runall.sh runs each test from a folder of its own.
#      A "both" test runs twice, on E: and on F:: rights, names and POSIX
#      behaviour differ between them. Pass: exit code 0.
#   4. Markers on the serial console (@@START, then @@END with
#      the exit code) tell the host what ran. At the end: SHUTDOWN.
# A test past its time limit, or a crash, stops the VM: that test
# is marked TIMEOUT or CRASH, and a new boot goes on with the next.
#
# HOST SUITES (HOST below) follow: net and input, each starting
# VMs of its own. Pass: exit code 0.
#
# Results: build/run-all-metal/RESULTS.md.
import argparse
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import common as h  # noqa: E402

h.only("metal-x86_64", "metal-arm64", "bios-x86")

OUT = h.suite_dir("run-all")
DISK = os.path.join(OUT, "test.img")
MIB = 2048  # sectors

# GUEST TESTS: (group, name, where, seconds, command). where: both (from
# a folder on the Minix and on the FAT work volume) or once (from the
# Minix one). Pass: exit code 0. C:/SCRIPTS is the system's own copy.
# Which program tests what:
#   DEMO api     the program API from Zig (DEMO's other groups: below)
#   DEMOC        the C side of it: each group, zdos.h's structs
#   POSIXTEST    the C SDK's POSIX layer; POSIXTEST net: its sockets
#   ZDLTEST      .ZDL libraries (ZCRYPT against Zig's crypto)
#   demoa.sh, DEMOB.CMD   ash and COMMAND (also rights on FAT and Minix)
TESTS = [
    ("api", "demo", "both", 600, "DEMO api"),
    ("api", "democ", "both", 120, "DEMOC"),
    ("api", "zdl", "once", 120, "ZDLTEST"),
    ("posix", "posix", "both", 300, "POSIXTEST"),
    ("shells", "ash", "both", 900, "ash C:/SCRIPTS/demoa.sh"),
    ("shells", "batch", "both", 180, "COMMAND -c C:/SCRIPTS/DEMOB.CMD"),
    ("scripts", "lua", "both", 120, "lua C:/SCRIPTS/luademo.lua"),
    ("scripts", "quickjs", "both", 120, "qjs C:/SCRIPTS/jsdemo.js"),
    ("scripts", "gcstress", "once", 600, "micropython C:/SCRIPTS/gcstress.py"),
    ("scripts", "stest", "both", 900, "ash C:/SCRIPTS/stest.sh"),
    ("apps", "archives", "both", 300, "ash C:/SCRIPTS/archives.sh"),
    ("net", "loopback", "once", 60, "POSIXTEST net -L"),
    ("apps", "ver", "once", 30, "VER"),
    ("apps", "mem", "once", 30, "MEM"),
    ("apps", "drives", "once", 30, "DRIVES"),
    ("apps", "devices", "once", 30, "DEVICES"),
]

# DEMO's other groups: (name, seconds, keys the host types after the
# start: (seconds, key) each), so the ones that wait for keys end
DEMO_GROUPS = [
    ("colors", 30, []),
    ("tree", 30, []),
    ("keyboard", 30, [(3, "a"), (1, "esc"), (0.5, "esc")]),
    ("keys", 30, [(3, "a"), (1, "esc")]),
    ("mouse", 30, [(4, "esc")]),
    ("gfx", 30, [(4, "spc")]),
    ("rgb", 30, [(4, "spc")]),
    ("sound", 60, []),
    ("tasks", 120, []),
    ("cores", 180, []),
]
TESTS += [("demo", "demo-" + n, "once", secs, f"DEMO {n}", keys) for n, secs, keys in DEMO_GROUPS]

# Tests left out on an edition: BIOS has no true color (DEMO gfx
# tests its 320 x 200)
NOT_ON = {"demo-rgb": ("bios-x86",)}

# HOST SUITES: (group, name, script under tests/, editions it has). Each
# boots its own machines on this edition (ZDOS_EDITION / ZDOS_ARCH are
# passed on); pass: exit code 0.
BOTH = ("metal-x86_64", "metal-arm64")
ALL = BOTH + ("bios-x86",)
HOST = [
    ("net", "net", "net/net-tests.py", ALL),
    ("net", "nat", "net/nat-tests.py", ("metal-x86_64",)),
    ("net", "route", "net/route-tests.py", ("metal-x86_64",)),
    ("net", "ssh", "net/ssh-tests.py", ALL),
    ("net", "httpz", "net/httpz-tests.py", ALL),
    ("input", "keys", "input/key-release-tests.py", BOTH),  # QEMU's USB keyboard
    ("ports", "sqlite", "ports/sqlite-tests.py", ALL),
    ("ports", "zlib", "ports/zlib-tests.py", ALL),
    ("ports", "ffmpeg", "ports/ffmpeg-tests.py", ("metal-x86_64",)),
]

# The test disk: p1 FAT (runall.sh), p2 Minix, p3 FAT; letters from
# the edition's first test letter (D:, BIOS E:):
PARTS = [("tests", 2048, 64 * MIB), ("mfs", 2048 + 64 * MIB, 256 * MIB),
         ("fat", 2048 + 320 * MIB, 256 * MIB)]
DISK_SECTORS = 2048 + 576 * MIB + MIB
LETTER = {name: chr(ord(h.TEST_LETTER) + i) for i, name in enumerate(("tests", "mfs", "fat"))}


def runs(groups):
    # (name, fs, seconds, command) in order; fs: mfs or fat:
    out = []
    for group, name, where, seconds, command, *keys in TESTS:
        if group not in groups or h.NAME in NOT_ON.get(name, ()):
            continue
        for fs in (("mfs", "fat") if where == "both" else ("mfs",)):
            out.append((name, fs, seconds, command, keys[0] if keys else []))
    return out


def make_disk():
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    parts = []
    for name, start, sectors in PARTS:
        part = os.path.join(OUT, name + ".part")
        if name == "mfs":
            subprocess.run([h.mkmfs3(), part, str(sectors * 512), "-b", "4096", "-i", "8192"], check=True,
                           stdout=subprocess.DEVNULL)
        else:
            h.mkfs(part, "32", sectors // 2, "ZTESTS" if name == "tests" else "ZWORKFAT")
        parts.append((part, start, sectors, h.TYPE_LINUX if name == "mfs" else h.TYPE_BASIC))
    h.gpt_from_parts(DISK, DISK_SECTORS, parts)
    for part, *_ in parts:
        os.remove(part)


def script(todo):
    # runall.sh for what is left: each test in a folder of its own, its
    # TEMP there too (POSIX's /tmp), then a marker with its exit code.
    lines = ["#!/C:/APPS/ASH.APP", "# runall.sh: made by tests/run-all.py", 'echo "@@BEGIN"']
    for name, fs, _, command, _ in todo:
        letter = LETTER[fs]
        folder = f"/{letter}:/t/{name}"
        temp = f"{letter}:\\t\\{name}"
        lines += [f'echo "@@START {name} {fs}"',
                  f"mkdir -p {folder} && cd {folder} && TEMP='{temp}' {command}",
                  f'echo "@@END {name} {fs} $?"']
    lines += ['echo "@@DONE"', "SHUTDOWN", ""]
    return "\n".join(lines)


def put_script(text):
    path = os.path.join(OUT, "runall.sh")
    with open(path, "w", newline="\n") as f:
        f.write(text)
    _, start, _ = PARTS[0]
    subprocess.run(["mcopy", "-o", "-i", f"{DISK}@@{start * 512}", path, "::/runall.sh"], check=True)


def boot(todo, n):
    # One boot through what it gets to: [(name, fs, code or TIMEOUT/CRASH, output)].
    put_script(script(todo))
    sock = os.path.join(OUT, f"mon-{n}.sock")
    serial = os.path.join(OUT, f"serial-{n}.txt")
    if os.path.exists(sock):
        os.remove(sock)
    args = h.machine_args(sock, DISK, OUT) + ["-serial", f"file:{serial}"]
    proc = subprocess.Popen(args, cwd=h.ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    done = []
    try:
        mon = h.Monitor(sock)
        time.sleep(h.BOOT_WAIT)
        for ch in f"ash /{LETTER['tests']}:/runall.sh":
            mon.cmd("sendkey " + h.key_name(ch))
            time.sleep(0.05)
        mon.cmd("sendkey ret")
        current, since, began = None, time.time(), time.time() + 60
        pending = []  # (when, key) for the running test
        while True:
            log = read_log(serial)
            ends = re.findall(r"^@@END (\S+) (\S+) (\d+)\s*$", log, re.M)
            starts = re.findall(r"^@@START (\S+) (\S+)\s*$", log, re.M)
            while len(done) < len(ends):
                name, fs, code = ends[len(done)]
                done.append((name, fs, int(code), output_of(log, name, fs)))
            if "@@DONE" in log:
                proc.wait(timeout=60)
                return done, True
            if len(starts) > len(done):
                now = starts[len(done)]
                if now != current:
                    current, since = now, time.time()
                    plan = next(t[4] for t in todo if (t[0], t[1]) == now)
                    at = since
                    pending = []
                    for secs, key in plan:
                        at += secs * h.SLOW
                        pending.append((at, key))
                while pending and time.time() >= pending[0][0]:
                    mon.cmd("sendkey " + pending.pop(0)[1])
                limit = next(t[2] for t in todo if (t[0], t[1]) == now) * h.SLOW
                if time.time() - since > limit:
                    done.append((now[0], now[1], "TIMEOUT", output_of(log, *now)))
                    return done, False
            elif "@@BEGIN" not in log and time.time() > began:
                return done, False  # runall.sh never started
            if proc.poll() is not None:
                if len(starts) > len(done):
                    done.append((starts[len(done)][0], starts[len(done)][1], "CRASH", output_of(log, *starts[len(done)])))
                return done, False
            time.sleep(0.5)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        if os.path.exists(sock):
            os.remove(sock)


def read_log(path):
    if not os.path.exists(path):
        return ""
    raw = open(path, "rb").read().decode("utf-8", "replace")
    return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", raw).replace("\r", "")


def output_of(log, name, fs):
    # The test's lines, from its START marker:
    m = re.search(rf"^@@START {re.escape(name)} {fs}\s*$", log, re.M)
    if not m:
        return ""
    rest = log[m.end():]
    end = re.search(r"^@@(END|START|DONE)\b", rest, re.M)
    return rest[:end.start()] if end else rest


def guest(groups):
    todo = runs(groups)
    if not todo:
        return []
    make_disk()
    results, n = [], 0
    while todo:
        n += 1
        done, finished = boot(todo, n)
        for name, fs, code, output in done:
            results.append(guest_result(name, fs, code, output))
            print(f"{'PASS' if code == 0 else 'FAIL'}  {name} ({fs}): {code}", flush=True)
        todo = todo[len(done):]
        if finished:
            break
        if not done:
            # Nothing ran: the boot or runall.sh failed; the rest is marked so.
            for name, fs, _, _, _ in todo:
                results.append(guest_result(name, fs, "NOT RUN", f"boot {n} ran nothing: see serial-{n}.txt"))
            break
    return results


def guest_result(name, fs, code, output):
    tail = " | ".join(line.strip() for line in output.strip().splitlines()[-3:] if line.strip())
    detail = f"exit {code}" if isinstance(code, int) else str(code)
    return (f"{name}-{fs}", code == 0, f"exit code 0 (run from {'a Minix' if fs == 'mfs' else 'a FAT'} volume)",
            f"{detail}; {tail}" if tail else detail, [])


def host(groups):
    results = []
    for group, name, rel, editions in HOST:
        if group not in groups:
            continue
        if h.NAME not in editions:
            print(f"skipped  {name} (host suite): not on {h.NAME}", flush=True)
            continue
        log = os.path.join(OUT, f"host-{name}.log")
        started = time.time()
        with open(log, "w") as f:
            code = subprocess.run([sys.executable, os.path.join(HERE, rel)], cwd=os.path.dirname(os.path.join(HERE, rel)),
                                  stdout=f, stderr=subprocess.STDOUT).returncode
        secs = int(time.time() - started)
        results.append((name, code == 0, f"{rel} on {h.NAME}: exit code 0", f"exit {code} in {secs} s; log host-{name}.log", []))
        print(f"{'PASS' if code == 0 else 'FAIL'}  {name} (host suite): exit {code}", flush=True)
    return results


def main():
    groups = sorted({t[0] for t in TESTS} | {t[0] for t in HOST})
    ap = argparse.ArgumentParser(description="ZDOS tests without the disk and port suites")
    ap.add_argument("--only", help="groups: " + ",".join(groups))
    ap.add_argument("--skip", help="groups to leave out")
    ap.add_argument("--no-host", action="store_true", help="only the guest tests")
    ap.add_argument("--list", action="store_true", help="list the tests")
    a = ap.parse_args()
    chosen = set(a.only.split(",")) if a.only else set(groups)
    chosen -= set(a.skip.split(",")) if a.skip else set()
    unknown = chosen - set(groups)
    if unknown:
        raise SystemExit(f"unknown groups: {', '.join(sorted(unknown))} (have {', '.join(groups)})")
    if a.list:
        for name, fs, secs, command, _ in runs(chosen):
            print(f"guest  {name:10} {fs:4} {secs:4} s  {command}")
        for group, name, rel, editions in HOST:
            if group in chosen and not a.no_host:
                print(f"host   {name:10}           {rel}" + ("" if h.NAME in editions else f"  (not on {h.NAME})"))
        return
    h.require_system()
    results = guest(chosen)
    if not a.no_host:
        results += host(chosen)
    h.write_results(os.path.join(OUT, "RESULTS.md"), f"ZDOS tests ({h.NAME})", results)
    sys.exit(1 if h.summary(results) else 0)


if __name__ == "__main__":
    main()
