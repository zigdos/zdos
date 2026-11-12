#!/usr/bin/env python3
# A key's release while ZDOS is busy drawing: KILO and MORE get
# key-down events at 40 a second for 3 s, as a desktop's key repeat
# (QEMU's USB keyboard keeps 16 events and drops the rest, the release
# too, if the guest falls behind), then the release. Screenshots 1, 4
# and 8 s after it must be the same.
#   key-release-tests.py [EDITION...]   default from ZDOS_EDITION /
#   ZDOS_ARCH (tests/common.py), metal x86_64:
#   ZDOS_EDITION=metal ZDOS_ARCH=arm64 python3 tests/input/key-release-tests.py
import json
import os
import shutil
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import common  # noqa: E402

OUT = os.path.join(common.BUILD, "key-release-tests")


class Qmp:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        for _ in range(50):
            try:
                self.s.connect(path)
                break
            except OSError:
                time.sleep(0.2)
        self.f = self.s.makefile("rw")
        self.f.readline()
        self.cmd("qmp_capabilities")

    def cmd(self, name, **a):
        self.f.write(json.dumps({"execute": name, "arguments": a}) + "\n")
        self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if "return" in r or "error" in r:
                return r

    def key(self, qcode, down):
        return self.cmd("input-send-event", events=[{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": qcode}}}])


aavmf = common.aavmf


def diff(a, b):
    from PIL import Image, ImageChops
    d = ImageChops.difference(Image.open(a).convert("RGB"), Image.open(b).convert("RGB"))
    return sum(1 for p in d.getdata() if p != (0, 0, 0))


def run_edition(ed):
    d = os.path.join(OUT, ed)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    img = os.path.join(d, "system.img")
    shutil.copyfile(os.path.join(common.BUILD, ed, "system.img"), img)
    arm = ed.endswith("arm64")
    code, vars_ = aavmf() if arm else common.ovmf()
    own = os.path.join(d, "VARS.fd")
    shutil.copyfile(vars_, own)
    hmp, qmp = os.path.join(d, "hmp.sock"), os.path.join(d, "qmp.sock")
    base = ["-drive", f"if=pflash,format=raw,readonly=on,file={code}", "-drive", f"if=pflash,format=raw,file={own}",
            "-drive", f"file={img},if=none,id=nvme0,format=raw", "-device", "nvme,serial=ZDOS0001,drive=nvme0,bootindex=0",
            "-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-mouse", "-nic", "none", "-display", "none",
            "-monitor", f"unix:{hmp},server,nowait", "-qmp", f"unix:{qmp},server,nowait"]
    if arm:
        args = ["qemu-system-aarch64", *common.arm_machine(), "-smp", "2", "-m", "512M", "-device", "ramfb"] + base
    else:
        args = ["qemu-system-x86_64", *common.x86_accel(), "-machine", "q35", "-smp", "4", "-m", "256M", "-vga", "std"] + base
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    results = []
    try:
        mon = common.Monitor(hmp)
        q = Qmp(qmp)
        time.sleep(60 if arm else 35)

        def typed(text):
            for ch in text:
                mon.cmd("sendkey " + common.key_name(ch))
            mon.cmd("sendkey ret")
            time.sleep(4)

        def burst_then_check(name, qcode):
            until = time.time() + 3
            while time.time() < until:
                q.key(qcode, True)
                time.sleep(0.025)
            q.key(qcode, False)
            shots = []
            for wait, tag in ((1, "1s"), (3, "4s"), (4, "8s")):
                time.sleep(wait)
                common.shot(mon, d, f"{name}-{tag}")
                shots.append(os.path.join(d, f"{name}-{tag}.png"))
            moved = diff(shots[1], shots[2])
            results.append((f"{name}: stops once the key is released", moved == 0, f"{moved} pixels changed 4s->8s"))

        typed("KILO C:\\DOCS\\COMMAND.md")
        for _ in range(45):
            mon.cmd("sendkey pgdn")
        time.sleep(3)
        burst_then_check("kilo-up", "up")
        mon.cmd("sendkey ctrl-q")
        time.sleep(3)
        typed("MORE C:\\DOCS\\COMMAND.md")
        burst_then_check("more-space", "spc")
    finally:
        proc.kill()
        proc.wait()
        os.remove(img)
    passed = sum(1 for r in results if r[1])
    with open(os.path.join(d, "results.md"), "w") as f:
        f.write(f"# Key release: {ed}\n\n{passed} of {len(results)} passed\n\n")
        for name, ok, detail in results:
            f.write(f"- {'PASS' if ok else 'FAIL'} {name} ({detail})\n")
    print(f"{ed}: {passed} of {len(results)} passed")
    for name, ok, detail in results:
        if not ok:
            print(f"  FAIL {name}: {detail}")
    return passed == len(results) and len(results) > 0


def main():
    eds = sys.argv[1:] or [common.NAME]
    sys.exit(0 if all([run_edition(e) for e in eds]) else 1)


if __name__ == "__main__":
    main()
