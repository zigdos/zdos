#!/usr/bin/env python3
# 7-Zip on ZDOS: 7ZZ.APP unpacks archives the host made and packs
# files the host's 7z unpacks, compared byte for byte; DOS paths and
# hostile names too. The port's 7ZZ.APP goes onto a test disk, so
# zig build is not needed.
#   7z-tests.py [EDITION...]   default from ZDOS_EDITION / ZDOS_ARCH
#   (tests/common.py), metal x86_64
#   SEVENZIP_RAR=FILE.rar      a RAR archive to unpack too
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import common  # noqa: E402

OUT = os.environ.get("SEVENZIP_TESTS_OUT", os.path.join(common.BUILD, "7z-tests"))
EDITIONS = {
    # name: (build folder, arm64)
    "metal-x86_64": ("metal-x86_64", False),
    "uefi-x86_64": ("uefi-x86_64", False),
    "metal-arm64": ("metal-arm64", True),
    "uefi-arm64": ("uefi-arm64", True),
    "bios-x86": ("bios-x86", False),
}
PASSWORD = "Zdos-7z"

# The archives this computer makes, what ZDOS does with each, and
# where the files land (tar inside gzip & co: unpacked twice):
UNPACK = [
    # (archive, folder, how this computer makes it)
    ("LZMA2.7Z", "O7Z", ["7z", "a", "-t7z", "-m0=LZMA2", "-mx5"]),
    ("PPMD.7Z", "OPPMD", ["7z", "a", "-t7z", "-m0=PPMd"]),
    ("BZIP2.7Z", "OBZ7", ["7z", "a", "-t7z", "-m0=BZip2"]),
    ("AES.7Z", "OAES", ["7z", "a", "-t7z", f"-p{PASSWORD}", "-mhe=on"]),
    ("DEFL.ZIP", "OZIP", ["7z", "a", "-tzip", "-mm=Deflate"]),
    ("TAR.TAR", "OTAR", ["7z", "a", "-ttar"]),
]
TARRED = [
    # (archive, folder, compressor command reading the tar)
    ("TAR.TGZ", "OTGZ", ["gzip", "-9", "-c"]),
    ("TAR.TBZ", "OTBZ", ["bzip2", "-9", "-c"]),
    ("TAR.TXZ", "OTXZ", ["xz", "-6", "-c"]),
    ("TAR.TZS", "OTZS", ["zstd", "-19", "-c", "-q"]),
]
PACK = [
    # (archive, 7ZZ's options, what, the names stored: "src" SRC/...,
    # "sub" SRC/SUB/..., "bare" SUB's files alone, "text" TEXT.TXT);
    # DOS's spellings of paths (\, D:) as on Windows
    ("P.7Z", "-t7z -mx3 -mmt=2", "SRC/*", "src"),
    ("PAES.7Z", f"-t7z -mx1 -p{PASSWORD} -mhe=on", "SRC/*", "src"),
    ("P.ZIP", "-tzip -mx5", "SRC\\*", "src"),
    ("PDRIVE.7Z", "-t7z -mx1", "D:\\SRC", "src"),
    ("PREL.7Z", "-t7z -mx1", "SRC\\SUB\\*.TXT", "sub"),
    ("PABS.7Z", "-t7z -mx1", "D:\\SRC\\SUB\\*.TXT", "bare"),
    ("P.GZ", "-tgzip -mx5", "SRC/TEXT.TXT", "text"),
    ("P.BZ2", "-tbzip2 -mx5", "D:\\SRC\\TEXT.TXT", "text"),
    ("P.XZ", "-txz -mx3", "/D:/SRC/TEXT.TXT", "text"),
]
# Names that would leave the folder they're unpacked into:
HOSTILE = ["D:/ESC1.TXT", "a\\..\\..\\ESC2.TXT", "../ESC3.TXT", "C:/ESC4.TXT", "OK/FINE.TXT"]


def known_files():
    # A text, random bytes, a folder with a small and an empty file:
    words = b"seven zip archive LZMA dictionary ZDOS solid block stream the of and a to".split()
    text, x = [], 2463534242
    for i in range(40000):
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        text.append(words[x % len(words)])
        if x % 11 == 0:
            text.append(b"\r\n")
    rand = bytearray()
    for i in range(200000):
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        rand.append(x & 0xFF)
    return {
        "TEXT.TXT": b" ".join(text),
        "RAND.BIN": bytes(rand),
        "SUB/NOTE.TXT": b"A note in a folder.\r\n" * 37,
        "SUB/EMPTY.TXT": b"",
    }


def rar4_stored(files):
    # A RAR 4 archive of stored (unpacked) files: this computer has
    # no RAR packer. Blocks: CRC16 (crc32's low half) of the rest.
    def block(kind, flags, body, data=b""):
        head = struct.pack("<BHH", kind, flags, 7 + len(body)) + body
        return struct.pack("<H", zlib.crc32(head) & 0xFFFF) + head + data
    dos_time = (2026 - 1980) << 25 | 11 << 21 | 14 << 16 | 12 << 11
    out = b"Rar!\x1a\x07\x00" + block(0x73, 0, struct.pack("<HI", 0, 0))
    for name, data in files.items():
        n = name.replace("/", "\\").encode()
        body = struct.pack("<IIBIIBBHI", len(data), len(data), 0, zlib.crc32(data), dos_time,
                           20, 0x30, len(n), 0x20) + n
        out += block(0x74, 0x8000, body, data)
    return out + block(0x7B, 0x4000, b"")


def run(cmd, cwd=None, data=None):
    return subprocess.run(cmd, cwd=cwd, input=data, capture_output=True, check=True).stdout


def make_disk(d, files):
    fat = os.path.join(d, "szdisk.img")
    run(["mkfs.fat", "-F", "32", "-n", "SZDISK", "-C", fat, str(128 * 1024)])
    with tempfile.TemporaryDirectory(dir=d) as t:
        src = os.path.join(t, "SRC")
        for name, data in files.items():
            os.makedirs(os.path.dirname(os.path.join(src, name)), exist_ok=True)
            with open(os.path.join(src, name), "wb") as f:
                f.write(data)
        made = os.path.join(t, "made")
        os.makedirs(made)
        names = sorted(files)
        for archive, _, cmd in UNPACK:
            run(cmd + [os.path.join(made, archive)] + names, cwd=src)
        tar = run(["tar", "-c", "--format=ustar", "-C", src] + names)
        for archive, _, cmd in TARRED:
            with open(os.path.join(made, archive), "wb") as f:
                f.write(run(cmd, data=tar))
        rar = rar4_stored(files)
        with open(os.path.join(made, "STORED.RAR"), "wb") as f:
            f.write(rar)
        # The RAR made by hand, as this computer's unrar sees it:
        r = subprocess.run(["unrar", "t", os.path.join(made, "STORED.RAR")], capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit("the stored RAR this test makes is wrong (unrar t):\n" + r.stdout)
        with zipfile.ZipFile(os.path.join(made, "HOSTILE.ZIP"), "w") as z:
            for n in HOSTILE:
                z.writestr(n, n.encode())
        sample = os.environ.get("SEVENZIP_RAR")
        if sample:
            shutil.copyfile(sample, os.path.join(made, "SAMPLE.RAR"))
        run(["mcopy", "-s", "-i", fat, src, "::/"])
        for f in sorted(os.listdir(made)):
            run(["mcopy", "-i", fat, os.path.join(made, f), "::/" + f])
    return fat


def script(sample):
    # RUN.CMD: each step's output into a log; failures into FAILS.TXT
    lines = ["@ECHO OFF", "D:", "CD \\"]

    def step(name, cmd):
        lines.append(f"7ZZ {cmd} > {name}.LOG 2>&1")
        lines.append(f"IF ERRORLEVEL 1 ECHO {name} >> FAILS.TXT")

    for archive, folder, cmd in UNPACK:
        step(folder, f"x {archive} -o{folder} -y" + (f" -p{PASSWORD}" if "AES" in archive else ""))
    for archive, folder, _ in TARRED:
        step(folder + "1", f"x {archive} -oZ{folder} -y")
        step(folder, f"x Z{folder}/* -o{folder} -y")
    step("ORAR", "x STORED.RAR -oORAR -y")
    step("ODRIVE", "x D:\\LZMA2.7Z -oD:\\ODRIVE -y")
    step("OHOST", "x HOSTILE.ZIP -oOHOST -y")
    if sample:
        step("OSAMPLE", "x SAMPLE.RAR -oOSAMPLE -y")
    for archive, opts, what, _ in PACK:
        step(archive.replace(".", ""), f"a {opts} {archive} {what}")
    step("TEST7Z", "t P.7Z")
    step("TESTAES", f"t PAES.7Z -p{PASSWORD}")
    step("WRONGPW", "t PAES.7Z -pwrong")
    lines.append("ECHO done > DONE.TXT")
    return "\r\n".join(lines) + "\r\n"


def qemu(edition, d, sock, system, fat):
    folder, arm = EDITIONS[edition]
    serial = ["-serial", f"file:{os.path.join(d, 'serial.txt')}", "-monitor", f"unix:{sock},server,nowait"]
    if edition == "bios-x86":
        return ["qemu-system-i386", "-machine", "pc", "-cpu", "pentium3", "-smp", "2", "-m", "256M",
                "-drive", f"file={system},format=raw,if=ide,index=0",
                "-drive", f"file={fat},format=raw,if=ide,index=1",
                "-boot", "c", "-display", "none", "-rtc", "base=localtime", "-nic", "none"] + serial
    code, settings = common.aavmf() if arm else common.ovmf()
    own = os.path.join(d, "VARS.fd")
    shutil.copyfile(settings, own)
    base = [
        "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
        "-drive", f"if=pflash,format=raw,file={own}",
        "-drive", f"file={system},if=none,id=nvme0,format=raw",
        "-device", "nvme,serial=ZDOS0001,drive=nvme0,bootindex=0",
        "-device", "qemu-xhci", "-device", "usb-kbd",
        "-drive", f"file={fat},if=none,id=szdisk,format=raw",
        "-display", "none", "-rtc", "base=localtime", "-nic", "none",
    ] + serial
    if arm:
        gfx = ["-device", "ramfb"] if edition.startswith("metal") else ["-device", "virtio-gpu-pci"]
        return (["qemu-system-aarch64", *common.arm_machine(), "-smp", "2", "-m", "512M"]
                + gfx + base + ["-device", "usb-storage,drive=szdisk"])
    return (["qemu-system-x86_64", *common.x86_accel(), "-machine", "q35", "-smp", "2", "-m", "512M", "-vga", "std"]
            + ["-device", "ide-hd,drive=szdisk,bus=ide.1"] + base)


def mread(img, name):
    r = subprocess.run(["mtype", "-i", img, "::/" + name], capture_output=True)
    return r.stdout if r.returncode == 0 else None


def tree(root):
    # {"SUB/NOTE.TXT": bytes} of a folder, names in capitals (FAT):
    out = {}
    for base, _, names in os.walk(root):
        for n in names:
            p = os.path.join(base, n)
            with open(p, "rb") as f:
                out[os.path.relpath(p, root).replace(os.sep, "/").upper()] = f.read()
    return out


def differences(got, want):
    want = {k.upper(): v for k, v in want.items()}
    bad = [k for k in want if got.get(k) != want[k]]
    bad += [k + " (extra)" for k in got if k not in want]
    return ", ".join(sorted(bad))


def run_edition(edition):
    d = os.path.join(OUT, edition)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    app = os.path.join(common.BUILD, EDITIONS[edition][0], "APPS_3RD", "7ZZ.APP")
    if not os.path.exists(app):
        raise SystemExit(f"{app} missing: run ports/tools/7z/build.sh")
    system = os.path.join(d, "system.img")
    shutil.copyfile(os.path.join(common.BUILD, EDITIONS[edition][0], "system.img"), system)
    files = known_files()
    sample = os.environ.get("SEVENZIP_RAR")
    fat = make_disk(d, files)
    run(["mcopy", "-i", fat, app, "::/7ZZ.APP"])
    with open(os.path.join(d, "RUN.CMD"), "w", newline="") as f:
        f.write(script(sample))
    run(["mcopy", "-i", fat, os.path.join(d, "RUN.CMD"), "::/RUN.CMD"])
    sock = os.path.join(d, "monitor.sock")
    arm = EDITIONS[edition][1]
    boot = 60 if arm else 20 if edition == "bios-x86" else 35
    began = time.time()
    steps = (common.command("D:\\RUN", 5)
             + [("until", lambda: mread(fat, "DONE.TXT") is not None, 1800), ("wait", 3)]
             + common.command("SHUTDOWN", 15))
    try:
        common.run_qemu(qemu(edition, d, sock, system, fat), steps, d, sock, boot_wait=boot)
    except BrokenPipeError:
        pass  # SHUTDOWN ended QEMU before its monitor was told to quit
    return check(edition, d, fat, files, sample, time.time() - began)


def check(edition, d, fat, files, sample, seconds):
    results = []

    def result(name, ok, detail=""):
        results.append((name, bool(ok), detail))

    result("RUN.CMD finished", mread(fat, "DONE.TXT") is not None)
    fails = (mread(fat, "FAILS.TXT") or b"").decode(errors="replace").split()
    got = os.path.join(d, "got")
    shutil.rmtree(got, ignore_errors=True)
    os.makedirs(got)
    run(["mcopy", "-s", "-n", "-i", fat, "::/*", got])
    for f in os.listdir(got):
        if f.upper().endswith(".LOG"):
            shutil.copyfile(os.path.join(got, f), os.path.join(d, f.upper()))

    def unpacked(folder, want, title):
        p = os.path.join(got, folder)
        tree_got = tree(p) if os.path.isdir(p) else {}
        bad = differences(tree_got, want) if tree_got else "nothing unpacked"
        result(title, folder not in fails and not bad, bad or (f"7ZZ failed: {folder}.LOG" if folder in fails else ""))

    for archive, folder, cmd in UNPACK:
        unpacked(folder, files, f"unpacks {archive} ({' '.join(cmd[2:]) or cmd[2]})")
    for archive, folder, cmd in TARRED:
        unpacked(folder, files, f"unpacks {archive} ({cmd[0]} of tar)")
    unpacked("ORAR", files, "unpacks STORED.RAR (RAR 4, stored)")
    unpacked("ODRIVE", files, "unpacks D:\\LZMA2.7Z into -oD:\\ODRIVE")
    # Hostile names: all inside OHOST (':' and '\\' made '_'):
    outside = sorted(os.path.relpath(os.path.join(b, f), got) for b, _, fs in os.walk(got) for f in fs
                     if f.upper().startswith("ESC") and not os.path.relpath(b, got).upper().startswith("OHOST"))
    inside = tree(os.path.join(got, "OHOST")) if os.path.isdir(os.path.join(got, "OHOST")) else {}
    result("hostile names (D:/, C:/, ..\\, ../) stay inside the folder unpacked into",
           not outside and len(inside) == len(HOSTILE), f"outside: {outside}; inside: {sorted(inside)}")
    if sample:
        with tempfile.TemporaryDirectory(dir=d) as t:
            run(["unrar", "x", "-idq", sample, t + os.sep])
            unpacked("OSAMPLE", tree(t), f"unpacks {os.path.basename(sample)} as unrar does")

    # What ZDOS packed, unpacked here:
    for archive, opts, what, names in PACK:
        name = archive.replace(".", "")
        p = os.path.join(got, archive)
        want = {
            "src": {"SRC/" + k: v for k, v in files.items()},
            "sub": {"SRC/" + k: v for k, v in files.items() if k.startswith("SUB/")},
            "bare": {k[4:]: v for k, v in files.items() if k.startswith("SUB/")},
            "text": {"TEXT.TXT": files["TEXT.TXT"]},
        }[names]
        if not os.path.exists(p):
            result(f"packs {archive} ({opts} {what})", False, "no archive")
            continue
        with tempfile.TemporaryDirectory(dir=d) as t:
            r = subprocess.run(["7z", "x", f"-p{PASSWORD}", f"-o{t}", "-y", p], capture_output=True, text=True)
            have = tree(t)
            if names == "text" and len(have) == 1:
                have = {"TEXT.TXT": next(iter(have.values()))}  # gzip & co: the name may be the archive's
            bad = "this computer's 7z: " + r.stdout[-200:] if r.returncode else differences(have, want)
        result(f"packs {archive} ({opts} {what}), unpacked here", name not in fails and not bad, bad)
    result("tests P.7Z (7ZZ t)", "TEST7Z" not in fails)
    result("tests PAES.7Z with its password", "TESTAES" not in fails)
    result("PAES.7Z with a wrong password fails", "WRONGPW" in fails)
    r = subprocess.run(["fsck.fat", "-n", fat], capture_output=True, text=True)
    result("SZDISK's FAT afterwards (fsck.fat -n)", r.returncode == 0)

    passed = sum(1 for r in results if r[1])
    with open(os.path.join(d, "results.md"), "w") as f:
        f.write(f"# 7-Zip on {edition}\n\n{passed} of {len(results)} passed ({seconds:.0f} s)\n\n")
        for name, ok, detail in results:
            f.write(f"- {'PASS' if ok else 'FAIL'} {name}{': ' + detail if detail and not ok else ''}\n")
    print(f"{edition}: {passed} of {len(results)} passed ({seconds:.0f} s)", flush=True)
    for name, ok, detail in results:
        if not ok:
            print(f"  FAIL {name}{': ' + detail if detail else ''}", flush=True)
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
