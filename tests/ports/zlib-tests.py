#!/usr/bin/env python3
# zlib on ZDOS: ZLIBTEST on ZLDISK (FAT16), with files this computer's
# zlib and gzip made; its deflated files must match byte for byte at
# the same settings. The port's ZLIB.ZDL and ZLIBTEST.APP go into the
# image copy, so zig build is not needed.
#   zlib-tests.py [EDITION...]   default from ZDOS_EDITION /
#   ZDOS_ARCH (tests/common.py), metal x86_64:
#   ZDOS_EDITION=uefi ZDOS_ARCH=x86_64 python3 tests/ports/zlib-tests.py
import gzip
import io
import os
import shutil
import subprocess
import sys
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import common  # noqa: E402

OUT = os.environ.get("ZLIB_TESTS_OUT", os.path.join(common.BUILD, "zlib-tests"))
EDITIONS = {
    # name: (build folder, arm64)
    "metal-x86_64": ("metal-x86_64", False),
    "uefi-x86_64": ("uefi-x86_64", False),
    "metal-arm64": ("metal-arm64", True),
    "uefi-arm64": ("uefi-arm64", True),
    "bios-x86": ("bios-x86", False),
}


aavmf = common.aavmf


def known_text():
    words = b"zlib deflate inflate ZDOS window Huffman tree stream the of and a to compression".split()
    out, x = [], 2463534242
    for i in range(30000):
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        out.append(words[x % len(words)])
        if x % 13 == 0:
            out.append(b"\n")
    return b" ".join(out)


def make_disk(d):
    fat = os.path.join(d, "zldisk.img")
    subprocess.run(["mkfs.fat", "-F", "16", "-n", "ZLDISK", "-C", fat, str(64 * 1024)], check=True, capture_output=True)
    text = known_text()
    files = {"KNOWN.TXT": text}
    buf = io.BytesIO()
    with gzip.GzipFile(filename="known.txt", mode="wb", fileobj=buf, mtime=1700000000) as g:
        g.write(text)
    files["KNOWN.GZ"] = buf.getvalue()
    files["KNOWN.ZZ"] = zlib.compress(text, 9)
    raw = zlib.compressobj(1, zlib.DEFLATED, -15)
    files["KNOWN.RAW"] = raw.compress(text) + raw.flush()
    half = len(text) // 3
    files["MULTI.GZ"] = gzip.compress(text[:half], 6, mtime=0) + gzip.compress(text[half:], 1, mtime=0)
    try:  # this computer's gzip program, else Python's
        files["GZIP9.GZ"] = subprocess.run(["gzip", "-9", "-c"], input=text, capture_output=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        files["GZIP9.GZ"] = gzip.compress(text, 9)
    for name, data in files.items():
        p = os.path.join(d, name)
        with open(p, "wb") as f:
            f.write(data)
        subprocess.run(["mcopy", "-i", fat, p, "::/" + name], check=True)
    return fat



def qemu(edition, d, sock, system, fat):
    folder, arm = EDITIONS[edition]
    serial = ["-serial", f"file:{os.path.join(d, 'serial.txt')}", "-monitor", f"unix:{sock},server,nowait"]
    if edition == "bios-x86":
        return ["qemu-system-i386", "-machine", "pc", "-cpu", "pentium3", "-smp", "2", "-m", "256M",
                "-drive", f"file={system},format=raw,if=ide,index=0",
                "-drive", f"file={fat},format=raw,if=ide,index=1",
                "-boot", "c", "-display", "none", "-rtc", "base=localtime", "-nic", "none"] + serial
    code, settings = aavmf() if arm else common.ovmf()
    own = os.path.join(d, "VARS.fd")
    shutil.copyfile(settings, own)
    base = [
        "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
        "-drive", f"if=pflash,format=raw,file={own}",
        "-drive", f"file={system},if=none,id=nvme0,format=raw",
        "-device", "nvme,serial=ZDOS0001,drive=nvme0,bootindex=0",
        "-device", "qemu-xhci", "-device", "usb-kbd",
        "-drive", f"file={fat},if=none,id=zldisk,format=raw",
        "-display", "none", "-rtc", "base=localtime", "-nic", "none",
    ] + serial
    if arm:
        gfx = ["-device", "ramfb"] if edition.startswith("metal") else ["-device", "virtio-gpu-pci"]
        return (["qemu-system-aarch64", *common.arm_machine(), "-smp", "2", "-m", "512M"]
                + gfx + base + ["-device", "usb-storage,drive=zldisk"])
    return (["qemu-system-x86_64", *common.x86_accel(), "-machine", "q35", "-smp", "2", "-m", "512M", "-vga", "std"]
            + ["-device", "ide-hd,drive=zldisk,bus=ide.1"] + base)


def put_port(edition, system, d, fat):
    # Into the image copy: BIOS's C: is FAT at 1 MiB; the others'
    # get both onto ZLDISK, where the loader finds the library in
    # the program's folder. Returns the command to type:
    folder = os.path.join(common.BUILD, EDITIONS[edition][0])
    for p in ("LIBS_3RD/ZLIB.ZDL", "APPS_3RD/ZLIBTEST.APP"):
        if not os.path.exists(os.path.join(folder, p)):
            raise SystemExit(f"{folder}/{p} missing: run ports/libs/zlib/build.sh")
    if edition == "bios-x86":
        for src, dst in (("LIBS_3RD/ZLIB.ZDL", "::/LIBS/ZLIB.ZDL"), ("APPS_3RD/ZLIBTEST.APP", "::/APPS/ZLIBTEST.APP")):
            subprocess.run(["mcopy", "-o", "-i", system + "@@1M", os.path.join(folder, src), dst], check=True)
        return "ZLIBTEST"
    for src in ("LIBS_3RD/ZLIB.ZDL", "APPS_3RD/ZLIBTEST.APP"):
        subprocess.run(["mcopy", "-o", "-i", fat, os.path.join(folder, src), "::/"], check=True)
    return "D:\\ZLIBTEST"  # C: the system, D: ZLDISK


def mread(img, name):
    r = subprocess.run(["mtype", "-i", img, "::/" + name], capture_output=True)
    return r.stdout if r.returncode == 0 else None


def run_edition(edition):
    d = os.path.join(OUT, edition)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    system = os.path.join(d, "system.img")
    shutil.copyfile(os.path.join(common.BUILD, EDITIONS[edition][0], "system.img"), system)
    fat = make_disk(d)
    command = put_port(edition, system, d, fat)
    sock = os.path.join(d, "monitor.sock")
    arm = EDITIONS[edition][1]
    boot = 60 if arm else 20 if edition == "bios-x86" else 35
    began = time.time()
    steps = (common.command(command, 5)
             + [("until", lambda: b"# ZLIBTEST:" in (mread(fat, "ZLIBTEST.LOG") or b""), 900), ("wait", 3),
                ("shot", "zlibtest", "after ZLIBTEST")]
             + common.command("SHUTDOWN", 15))
    try:
        common.run_qemu(qemu(edition, d, sock, system, fat), steps, d, sock, boot_wait=boot)
    except BrokenPipeError:
        pass  # SHUTDOWN ended QEMU before its monitor was told to quit
    return check(edition, d, fat, time.time() - began)


def check(edition, d, fat, seconds):
    results = []

    def result(name, ok, detail=""):
        results.append((name, ok, detail))

    log = (mread(fat, "ZLIBTEST.LOG") or b"").decode(errors="replace")
    with open(os.path.join(d, "ZLIBTEST.LOG"), "w") as f:
        f.write(log)
    result("ZLIBTEST finished", "# ZLIBTEST:" in log)
    for line in log.splitlines():
        if line.startswith("ok - ") or line.startswith("not ok - "):
            result("ZLIBTEST " + line.split(" - ", 1)[1], line.startswith("ok"))

    # Byte for byte what this computer's zlib makes at the same settings:
    manifest = (mread(fat, "MANIFEST.TXT") or b"").decode(errors="replace").splitlines()
    data, same, stored, differ = {}, 0, 0, []

    def load(name):
        if name not in data:
            data[name] = mread(fat, name) or b""
        return data[name]

    for line in manifest:
        f = line.split()
        if f[0] == "CRC":
            b = load(f[1])
            result(f"crc32 and adler32 of {f[1]} as this computer's",
                   (zlib.crc32(b), zlib.adler32(b)) == (int(f[2]), int(f[3])) and len(b) == 200000)
        elif f[0] == "DEF":
            name, src, level, wbits, mem, strategy = f[1], f[2], *map(int, f[3:])
            got = mread(fat, name) or b""
            if level == 0:  # stored blocks' sizes follow the caller's buffers: inflated instead
                try:
                    ok = zlib.decompress(got, 47 if wbits > 0 else -15) == load(src)
                except zlib.error:
                    ok = False
                stored += ok
                if not ok:
                    differ.append(f"{name} (level 0, does not inflate)")
                continue
            c = zlib.compressobj(level, zlib.DEFLATED, wbits, mem, strategy)
            want = c.compress(load(src)) + c.flush()
            if got == want:
                same += 1
            else:
                differ.append(f"{name} ({src} level {level} windowBits {wbits} memLevel {mem} strategy {strategy})")
        elif f[0] == "COMPRESS":
            result("compress() output as this computer's zlib.compress", mread(fat, f[1]) == zlib.compress(load(f[2])))
    result(f"deflate output byte for byte as this computer's zlib {zlib.ZLIB_RUNTIME_VERSION} "
           f"({same} files, levels 1-9; {stored} level-0 files inflated by it)", same > 0 and not differ, "; ".join(differ[:5]))

    # The gz files ZLIBTEST wrote, through this computer's gzip:
    out = mread(fat, "OUT.GZ")
    want = mread(fat, "OUT.TXT")
    try:
        result("OUT.GZ (gzwrite, gzprintf ...) read by this computer", gzip.decompress(out) == want and len(want) > 0)
    except Exception as e:  # noqa: BLE001
        result("OUT.GZ (gzwrite, gzprintf ...) read by this computer", False, str(e))
    try:
        result("APPEND.GZ (two members) read by this computer",
               gzip.decompress(mread(fat, "APPEND.GZ")) == b"first member\nsecond member\n")
    except Exception as e:  # noqa: BLE001
        result("APPEND.GZ (two members) read by this computer", False, str(e))
    r = subprocess.run(["fsck.fat", "-n", fat], capture_output=True, text=True)
    result("ZLDISK's FAT afterwards (fsck.fat -n)", r.returncode == 0)

    passed = sum(1 for r in results if r[1])
    speed = [line for line in log.splitlines() if line.startswith("# ")]
    with open(os.path.join(d, "results.md"), "w") as f:
        f.write(f"# zlib on {edition}\n\n{passed} of {len(results)} passed ({seconds:.0f} s)\n\n")
        for name, ok, detail in results:
            f.write(f"- {'PASS' if ok else 'FAIL'} {name}{': ' + detail if detail and not ok else ''}\n")
        f.write("\n```\n" + "\n".join(speed) + "\n```\n")
    print(f"{edition}: {passed} of {len(results)} passed ({seconds:.0f} s)")
    for line in speed:
        print("  " + line)
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
