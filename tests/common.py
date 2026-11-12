#!/usr/bin/env python3
# Shared parts of the test suites: the edition under test, paths,
# QEMU, typing keys through the monitor, screenshots; disk images
# from tests/images.py. chkdsk-tests.py make first: its images serve
# chkdsk-checks.py and fdisk-tests.py too.
#
# THE EDITION: ZDOS_EDITION (bios, metal, uefi) and ZDOS_ARCH
# (x86, x86_64, arm64), default metal x86_64 (under KVM):
#   python3 tests/disk/fat-tests.py run
#   ZDOS_EDITION=uefi ZDOS_ARCH=x86_64 python3 tests/disk/fat-tests.py run
#   ZDOS_EDITION=bios ZDOS_ARCH=x86 python3 tests/disk/fdisk-tests.py run
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
BUILD = os.path.join(ROOT, "build")
BIOS = os.path.join(BUILD, "bios-x86")
SYSTEM_IMG = os.path.join(BIOS, "system.img")
DATA_IMG = os.path.join(BIOS, "data.img")
FLOPPY_IMG = os.path.join(BIOS, "floppy.img")
MBR_BIN = os.path.join(BIOS, "mbr.bin")
SECTOR = 512

# Disk numbers from QEMU's drives: 0 the floppy, 1 the system disk
# (IDE 0), 2 the data disk (IDE 1), 3 the test disk (IDE 2).
FLOPPY_DISK, SYSTEM_DISK, DATA_DISK, TEST_DISK = 0, 1, 2, 3
# After C: and the data disk's one volume (D:, ext2):
TEST_LETTER = "E"

# THE EDITION UNDER TEST: EDITION and ARCH; NAME as its build
# folder (metal-x86_64). On UEFI the letters differ and FAT is the
# firmware's driver, so suites find their volumes by label
# (cd_label). Suites for one edition say so (only).

if "ZDOS_PLATFORM" in os.environ:
    raise SystemExit("ZDOS_PLATFORM is gone: ZDOS_EDITION=bios|metal|uefi ZDOS_ARCH=x86|x86_64|arm64")
EDITION = os.environ.get("ZDOS_EDITION", "metal")
ARCH = os.environ.get("ZDOS_ARCH", "x86_64")
NAME = f"{EDITION}-{ARCH}"
EDITIONS = ("bios-x86", "metal-x86_64", "metal-arm64", "uefi-x86_64", "uefi-arm64")
if NAME not in EDITIONS:
    raise SystemExit(f"ZDOS_EDITION={EDITION} ZDOS_ARCH={ARCH}: no such edition (have {', '.join(EDITIONS)})")


def only(*names):
    # For a suite of some editions: stop, saying how to run it.
    if NAME in names:
        return
    first = names[0].split("-")
    raise SystemExit(f"{os.path.basename(sys.argv[0])}: runs on {', '.join(names)} only, not {NAME}: "
                     f"ZDOS_EDITION={first[0]} ZDOS_ARCH={first[1]} python3 {sys.argv[0]}")
# The edition's build folder and system disk (BIOS: SYSTEM_IMG above).
# The tests boot a copy: the user's QEMU may hold system.img locked.
EDITION_DIR = os.path.join(BUILD, NAME)
EDITION_SYSTEM_IMG = os.path.join(EDITION_DIR, "system.img")
TEST_SYSTEM = os.path.join(BUILD, "test-system", NAME + ".img")
UEFI_SYSTEM_IMG = os.path.join(BUILD, "uefi-x86_64", "system.img")
METAL_SYSTEM_IMG = os.path.join(BUILD, "metal-x86_64", "system.img")
if EDITION in ("metal", "uefi"):
    # Disks: 0 the system disk (NVMe), 1 the test disk (x86: AHCI,
    # ARM64: virtio); no floppy, no data disk. C: Minix, the ESP no
    # letter: the test disk's volumes from D:
    FLOPPY_DISK, SYSTEM_DISK, DATA_DISK, TEST_DISK = None, 0, None, 1
    TEST_LETTER = "D"


# THE HOST: ITS CPU, ACCELERATION AND FIRMWARE (as the run-*.sh scripts)

DARWIN = platform.system() == "Darwin"


def _out(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()
    except OSError:
        return ""


def host_cpu():
    # x86, arm64 (also under Rosetta) or other:
    if DARWIN and _out("sysctl", "-n", "hw.optional.arm64") == "1":
        return "arm64"
    m = platform.machine().lower()
    if m in ("x86_64", "amd64") or re.fullmatch(r"i.86", m):
        return "x86"
    return "arm64" if m in ("arm64", "aarch64") else "other"


def accel(family):
    # The guest's CPU family (x86, arm64): kvm, hvf or tcg; ZDOS_ACCEL
    # chooses (ZDOS_ACCEL=tcg: emulated even where KVM is).
    if os.environ.get("ZDOS_ACCEL"):
        return os.environ["ZDOS_ACCEL"]
    if host_cpu() == family:
        if DARWIN:
            if _out("sysctl", "-n", "kern.hv_support") == "1":
                return "hvf"
        elif os.access("/dev/kvm", os.R_OK | os.W_OK):
            return "kvm"
    return "tcg"


def x86_accel():
    # -accel, and the host's CPU when it isn't emulated:
    a = accel("x86")
    return ["-accel", a] + ([] if a == "tcg" else ["-cpu", "host"])


def arm_machine():
    # ARM64's virt machine, its -accel and -cpu, as run-metal-arm64.sh:
    a = accel("arm64")
    if a == "tcg":
        return ["-accel", "tcg", "-machine", "virt", "-cpu", "cortex-a57"]
    machine = "virt,gic-version=max" if a == "kvm" else "virt"
    return ["-accel", a, "-machine", machine, "-cpu", "host"]


ACCEL = "tcg" if EDITION == "bios" else accel("arm64" if ARCH == "arm64" else "x86")
# Emulated, the UEFI and metal editions are slower: waits and limits
# scale by SLOW (BIOS's are for emulation already).
SLOW = 1 if EDITION == "bios" or ACCEL in ("kvm", "hvf") else int(os.environ.get("ZDOS_SLOW", "3"))
# Seconds from QEMU's start to the ZDOS prompt (OVMF takes longer):
BOOT_WAIT = (9 if EDITION == "bios" else 25) * SLOW


def brew(pkg=None):
    # Homebrew's prefix (of pkg); "" without Homebrew:
    if not shutil.which("brew"):
        return ""
    return _out("brew", "--prefix", *([pkg] if pkg else []))


if DARWIN:
    # Keg-only, so not on PATH: sfdisk, fsck.minix (util-linux);
    # mke2fs, e2fsck, debugfs (e2fsprogs)
    for _pkg in ("util-linux", "e2fsprogs"):
        _prefix = brew(_pkg)
        for _sub in ("bin", "sbin"):
            _d = os.path.join(_prefix, _sub)
            if _prefix and os.path.isdir(_d) and _d not in os.environ["PATH"].split(os.pathsep):
                os.environ["PATH"] = _d + os.pathsep + os.environ["PATH"]


def _firmware(pairs, what):
    for code, settings in pairs:
        if os.path.exists(code) and os.path.exists(settings):
            return code, settings
    raise SystemExit(f"{what} for QEMU not found")


def ovmf():
    # (code, settings) of x86_64's UEFI firmware, as run-uefi-x86_64.sh finds it:
    dirs = ("/usr/share/edk2/ovmf", "/usr/share/OVMF", "/usr/share/edk2/x64", "/usr/share/ovmf")
    q = os.path.join(brew(), "share", "qemu")
    return _firmware([(os.path.join(d, "OVMF_CODE.fd"), os.path.join(d, "OVMF_VARS.fd")) for d in dirs] +
                     [(os.path.join(q, "edk2-x86_64-code.fd"), os.path.join(q, "edk2-i386-vars.fd")),
                      (os.path.join(ROOT, "firmware", "OVMF_CODE.fd"), os.path.join(ROOT, "firmware", "OVMF_VARS.fd"))],
                     "UEFI firmware (edk2-ovmf / ovmf; macOS: brew install qemu)")


def aavmf():
    # ARM64's, as run-metal-arm64.sh finds it (pflash code and settings):
    dirs = ("/usr/share/edk2/aarch64", "/usr/share/AAVMF", "/usr/share/qemu-efi-aarch64")
    names = (("QEMU_EFI-silent-pflash.raw", "vars-template-pflash.raw"), ("QEMU_EFI-pflash.raw", "vars-template-pflash.raw"),
             ("AAVMF_CODE.fd", "AAVMF_VARS.fd"))
    q = os.path.join(brew(), "share", "qemu")
    return _firmware([(os.path.join(d, c), os.path.join(d, v)) for d in dirs for c, v in names] +
                     [(os.path.join(q, "edk2-aarch64-code.fd"), os.path.join(q, "edk2-arm-vars.fd")),
                      (os.path.join(ROOT, "firmware", "AAVMF_CODE.fd"), os.path.join(ROOT, "firmware", "AAVMF_VARS.fd"))],
                     "ARM64 UEFI firmware (edk2-aarch64 / qemu-efi-aarch64; macOS: brew install qemu)")


def build_step(name=NAME):
    # zig build <step> for an edition:
    return {"bios-x86": "x86", "metal-x86_64": "x86_64", "metal-arm64": "arm64"}.get(name, name)


def next_letter(letter, n=1):
    return chr(ord(letter) + n)


def suite_dir(name):
    # build/NAME for BIOS, build/NAME-<edition>-<arch> for the others.
    return os.path.join(BUILD, name if NAME == "bios-x86" else f"{name}-{NAME}")


# chkdsk-tests.py make's images, per edition (editions run at once):
CHKDSK_IMAGES = os.path.join(suite_dir("chkdsk-tests"), "images")


def require_system():
    # The edition's system disk (BIOS: also its data disk and floppy), and
    # the firmware for UEFI and metal.
    if EDITION == "bios":
        require(SYSTEM_IMG, DATA_IMG, FLOPPY_IMG)
        return
    require(EDITION_SYSTEM_IMG, hint=f"build it first: zig build {build_step()}")
    aavmf() if ARCH == "arm64" else ovmf()
    system_copy()


def system_copy():
    # A fresh copy when system.img is newer:
    src, dst = EDITION_SYSTEM_IMG, TEST_SYSTEM
    if not os.path.exists(dst) or os.path.getmtime(dst) < os.path.getmtime(src):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
    return dst


def edition_args(sock, test=None, test_snapshot=False):
    # Metal and UEFI, x86_64 or ARM64, as their run-*.sh: the system
    # disk (a snapshot of the copy) on NVMe, the test disk (x86: AHCI,
    # ARM64: virtio), a USB keyboard for sendkey and a mouse (metal x86:
    # no 8042; UEFI x86: the firmware's PS/2 ones).
    own = os.path.join(os.path.dirname(sock), f"VARS-{NAME}.fd")
    os.makedirs(os.path.dirname(own), exist_ok=True)
    if ARCH == "arm64":
        code, settings = aavmf()
        args = ["qemu-system-aarch64", *arm_machine(), "-device", "ramfb", "-device", "qemu-xhci", "-device", "usb-kbd",
                "-device", "usb-mouse"]
        test_device = ["-device", "virtio-blk-pci,drive=test0"]
    else:
        code, settings = ovmf()
        args = ["qemu-system-x86_64", *x86_accel(), "-vga", "std"]
        if EDITION == "metal":
            args += ["-machine", "q35,i8042=off", "-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-mouse"]
        else:
            args += ["-machine", "q35"]
        test_device = ["-device", "ide-hd,drive=test0,bus=ide.0"]
    shutil.copyfile(settings, own)
    args += [
        "-smp", "2", "-m", "512M",
        "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
        "-drive", f"if=pflash,format=raw,file={own}",
        "-drive", f"file={system_copy()},if=none,id=nvme0,format=raw,snapshot=on",
        "-device", "nvme,serial=ZDOS0001,drive=nvme0,bootindex=0",
        "-display", "none", "-rtc", "base=localtime", "-net", "none",
        "-monitor", f"unix:{sock},server,nowait",
    ]
    if test is not None:
        snap = ",snapshot=on" if test_snapshot else ""
        args += ["-drive", f"file={test},if=none,id=test0,format=raw{snap}", *test_device]
    return args


def metal_args(sock, test=None, test_snapshot=False):
    return edition_args(sock, test, test_snapshot)


def machine_args(sock, test, out_dir):
    # With test as the test disk:
    if EDITION == "bios":
        return qemu_args(sock, test=test)
    return edition_args(sock, test=test)


def mfsdir(image, sectors, folder):
    # A Minix V3 image holding folder (tools/build/mfsdir.zig: zig
    # build mfsdir; built here when missing)
    path = os.path.join(BUILD, "host", "mfsdir")
    if not os.access(path, os.X_OK):
        subprocess.run(["zig", "build", "mfsdir"], cwd=ROOT, check=True)
    subprocess.run([path, image, str(sectors // 2), folder], check=True, stdout=subprocess.DEVNULL)


def cd_label(pattern, wait=3):
    # In ash: cd to the root of the drive whose DRIVES line has pattern.
    return command(f"cd /$(DRIVES | grep {pattern} | awk '{{print $1}}')/", wait)


def mkmfs3():
    # The host's Minix formatter (tools/disk/mkmfs3-host.zig): zig
    # build makes it; built here when missing.
    path = os.path.join(BUILD, "host", "mkmfs3")
    if not os.access(path, os.X_OK):
        subprocess.run(["zig", "build", "mkmfs3"], cwd=ROOT, check=True)
    return path


def require(*paths, hint="build the BIOS version first: zig build x86 test-disks"):
    for path in paths:
        if not os.path.exists(path):
            raise SystemExit(f"{path} is missing: {hint}")


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# QEMU

def qemu_args(sock, test=None, test_snapshot=False, system=SYSTEM_IMG, system_snapshot=True,
              floppy=FLOPPY_IMG, floppy_snapshot=True):
    # The data disk is always a snapshot. The system disk, floppy and test
    # disk are written only when the case reads them back afterwards.
    # UEFI and metal: their own machine (BIOS's system disk and floppy
    # don't apply).
    if EDITION != "bios":
        return edition_args(sock, test=test, test_snapshot=test_snapshot)
    def snap(on):
        return ",snapshot=on" if on else ""
    args = [
        "qemu-system-i386", "-machine", "pc", "-cpu", "pentium3", "-m", "256M",
        "-drive", f"file={DATA_IMG},format=raw,if=ide,index=1,snapshot=on",
        "-drive", f"file={floppy},format=raw,if=floppy,index=0{snap(floppy_snapshot)}",
        "-vga", "std", "-display", "none", "-rtc", "base=localtime", "-net", "none",
        "-monitor", f"unix:{sock},server,nowait",
        "-drive", f"file={system},format=raw,if=ide,index=0{snap(system_snapshot)}",
    ]
    if test is not None:
        args += ["-drive", f"file={test},format=raw,if=ide,index=2{snap(test_snapshot)}"]
    return args + ["-boot", "c"]


class Monitor:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        for _ in range(50):
            try:
                self.sock.connect(path)
                break
            except OSError:
                time.sleep(0.2)
        self.sock.settimeout(3)
        self.drain()

    def drain(self):
        try:
            self.sock.recv(65536)
        except socket.timeout:
            pass

    def cmd(self, text):
        self.sock.sendall((text + "\n").encode())
        time.sleep(0.15)
        self.drain()


# QEMU sendkey names, US layout (ZDOS's default):
KEYS = {
    " ": "spc", "/": "slash", "\\": "backslash", ".": "dot", "-": "minus", ",": "comma",
    ";": "semicolon", "'": "apostrophe", "=": "equal",
    ":": "shift-semicolon", ">": "shift-dot", "<": "shift-comma", "_": "shift-minus",
    "|": "shift-backslash", '"': "shift-apostrophe", "+": "shift-equal", "?": "shift-slash",
    "*": "shift-8", "!": "shift-1", "$": "shift-4", "(": "shift-9", ")": "shift-0",
    "[": "bracket_left", "]": "bracket_right", "{": "shift-bracket_left", "}": "shift-bracket_right",
    "&": "shift-7", "#": "shift-3", "%": "shift-5", "^": "shift-6", "@": "shift-2",
    "~": "shift-grave_accent", "`": "grave_accent",
}


def key_name(ch):
    if ch in KEYS:
        return KEYS[ch]
    if ch.isalpha() and ch.isupper():
        return "shift-" + ch.lower()
    if ch.isalnum():
        return ch.lower()
    raise ValueError(f"no key for {ch!r}")


def shot(mon, case_dir, name):
    ppm = os.path.join(case_dir, name + ".ppm")
    mon.cmd(f"screendump {ppm}")
    time.sleep(0.5)
    from PIL import Image
    Image.open(ppm).save(os.path.join(case_dir, name + ".png"))
    os.remove(ppm)


def run_qemu(args, steps, case_dir, sock, boot_wait=None):
    # Starts QEMU, waits for ZDOS, does the steps, quits. Steps:
    #   ("text", "FDISK 3")  types it      ("key", "ret")  one key
    #   ("wait", seconds)                  ("shot", name, note)
    #   ("until", done, seconds)  polls done() every 3 s until true
    # Waits and limits are for KVM: emulated, they take SLOW times longer.
    # Returns the screenshots taken, as (name, note).
    os.makedirs(case_dir, exist_ok=True)
    if os.path.exists(sock):
        os.remove(sock)
    proc = subprocess.Popen(args, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shots = []
    try:
        mon = Monitor(sock)
        time.sleep(BOOT_WAIT if boot_wait is None else boot_wait)
        for step in steps:
            kind = step[0]
            if kind == "text":
                for ch in step[1]:
                    mon.cmd("sendkey " + key_name(ch))
                    time.sleep(0.05)
            elif kind == "key":
                mon.cmd("sendkey " + step[1])
            elif kind == "wait":
                time.sleep(step[1] * SLOW)
            elif kind == "until":
                deadline = time.time() + step[2] * SLOW
                while not step[1]() and time.time() < deadline:
                    time.sleep(3)
            elif kind == "shot":
                shot(mon, case_dir, step[1])
                shots.append((step[1], step[2] if len(step) > 2 else ""))
        mon.cmd("quit")
    finally:
        time.sleep(2)
        if proc.poll() is None:
            proc.kill()
        proc.wait()
    return shots


def command(text, wait=3):
    # A command line typed and entered, then a wait.
    return [("text", text), ("key", "ret"), ("wait", wait)]


def answer(text, wait=2):
    # Y/N, a number, or "" for Enter alone.
    steps = [("text", text)] if text else []
    return steps + [("key", "ret"), ("wait", wait)]


def write_results(path, title, results):
    # results: (name, passed or None for screenshot-only, expect, detail,
    # shots)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"# {title}\n\nScreenshots are in `shots/<case>/`.\n\n")
        for name, passed, expect, detail, shots in results:
            verdict = "REVIEW" if passed is None else ("PASS" if passed else "FAIL")
            f.write(f"## {verdict} {name}\n\nExpect: {expect}\n\n")
            if detail:
                f.write(f"Found: {detail}\n\n")
            for shot_name, note in shots:
                f.write(f"- `{shot_name}.png`: {note}\n")
            f.write("\n")


def summary(results):
    failed = sum(1 for r in results if r[1] is False)
    passed = sum(1 for r in results if r[1] is True)
    review = sum(1 for r in results if r[1] is None)
    print(f"{passed} passed, {failed} failed, {review} to review by screenshot")
    return failed


# DISK IMAGES: tests/images.py, here too as h.make_disk ...

from images import *  # noqa: E402,F401,F403
