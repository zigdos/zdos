#!/usr/bin/env python3
# Routing and bridging in QEMU: three ZDOS machines, each cable a
# socket network of its own (no host network, no DHCP).
#   route-tests.py [--rtl8139] [EDITION] [CASE...]
# EDITION default: ZDOS_EDITION / ZDOS_ARCH (tests/common.py), metal x86_64:
#   ZDOS_EDITION=bios ZDOS_ARCH=x86 python3 tests/net/route-tests.py
# CASE: router (A - R - B, ROUTING=true), norouting, bridge (A - BR -
# B, BRIDGE=0,1); default all. --rtl8139: R's / BR's second card is an
# RTL8139 (a driver's card, promiscuous through net_promiscuous).
import os
import shutil
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import common  # noqa: E402

OUT = os.path.join(common.BUILD, "route-tests")
LOG = os.environ.get("ROUTE_LOG_LETTER", "D")  # the log disk's letter in ZDOS
BASE_PORT = int(os.environ.get("ROUTE_PORT", "17300"))
# ROUTE_KERNEL=file: that kernel in the image copies; ROUTE_PCAP=1:
# each card's frames into cardN.pcap.
KERNEL = os.environ.get("ROUTE_KERNEL")
PCAP = os.environ.get("ROUTE_PCAP") == "1"

EDITIONS = {
    # name: (build folder, card, boot seconds)
    "bios-x86": ("bios-x86", "e1000", 20),
    "metal-x86_64": ("metal-x86_64", "e1000e", 35),
    "metal-e1000": ("metal-x86_64", "e1000", 35),
}


def put_kernel(img, kernel):
    # Into the ESP as \EFI\BOOT\<its name>: metal and UEFI.
    import json
    table = json.loads(subprocess.run(["sfdisk", "-J", img], check=True, capture_output=True).stdout)
    at = table["partitiontable"]["partitions"][0]["start"] * 512
    name = "::/EFI/BOOT/" + os.path.basename(kernel).upper()
    subprocess.run(["mcopy", "-o", "-i", f"{img}@@{at}", kernel, name], check=True, capture_output=True)


def mac(machine, card):
    return f"52:54:00:00:{machine:02x}:{card:02x}"


def mac_text(machine, card):
    return mac(machine, card).replace(":", "-").upper()


# ONE MACHINE

class Machine:
    def __init__(self, edition, d, name, number, cables, settings):
        # cables: ("listen" | "connect", port, model) per card, in PCI order.
        self.edition, self.name, self.number = edition, name, number
        self.settings = settings
        self.dir = os.path.join(d, name)
        os.makedirs(self.dir)
        self.sock = os.path.join(self.dir, "monitor.sock")
        self.log = os.path.join(self.dir, "log.img")
        subprocess.run(["mkfs.fat", "-F", "16", "-n", "NETLOG", "-C", self.log, str(16 * 1024)], check=True, capture_output=True)
        folder, card, self.boot = EDITIONS[edition]
        self.system = os.path.join(self.dir, "system.img")
        shutil.copyfile(os.path.join(common.BUILD, folder, "system.img"), self.system)
        if KERNEL:
            put_kernel(self.system, KERNEL)
        self.nets = []
        for i, (how, port, model) in enumerate(cables):
            self.nets += ["-netdev", f"socket,id=n{i},{how}=127.0.0.1:{port}",
                          "-device", f"{model or card},netdev=n{i},mac={mac(number, i + 1)},romfile="]
            if PCAP:
                self.nets += ["-object", f"filter-dump,id=d{i},netdev=n{i},file={os.path.join(self.dir, f'card{i + 1}.pcap')}"]
        self.proc = None
        self.mon = None

    def args(self):
        serial = ["-serial", f"file:{os.path.join(self.dir, 'serial.txt')}", "-monitor", f"unix:{self.sock},server,nowait"]
        if self.edition == "bios-x86":
            return (["qemu-system-i386", "-machine", "pc", "-cpu", "pentium3", "-smp", "2", "-m", "256M",
                     "-drive", f"file={self.system},format=raw,if=ide,index=0",
                     "-drive", f"file={self.log},format=raw,if=ide,index=1",
                     "-boot", "c", "-display", "none", "-rtc", "base=localtime"] + serial + self.nets)
        code, settings = common.ovmf()
        own = os.path.join(self.dir, "VARS.fd")
        shutil.copyfile(settings, own)
        return (["qemu-system-x86_64", *common.x86_accel(), "-machine", "q35", "-smp", "2", "-m", "512M", "-vga", "std",
                 "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
                 "-drive", f"if=pflash,format=raw,file={own}",
                 "-drive", f"file={self.system},if=none,id=nvme0,format=raw",
                 "-device", "nvme,serial=ZDOS0001,drive=nvme0,bootindex=0",
                 "-drive", f"file={self.log},if=none,id=log,format=raw",
                 "-device", "ide-hd,drive=log,bus=ide.1",
                 "-device", "qemu-xhci", "-device", "usb-kbd",
                 "-display", "none", "-rtc", "base=localtime"] + serial + self.nets)

    def start(self):
        if os.path.exists(self.sock):
            os.remove(self.sock)
        self.proc = subprocess.Popen(self.args(), cwd=common.ROOT, stdout=subprocess.DEVNULL,
                                     stderr=open(os.path.join(self.dir, "qemu.txt"), "w"))
        self.mon = common.Monitor(self.sock)

    def type(self, text, wait=2):
        for ch in text:
            self.mon.cmd("sendkey " + common.key_name(ch))
            time.sleep(0.05)
        self.mon.cmd("sendkey ret")
        time.sleep(wait)

    def configure(self):
        # At the end of SYSTEM.CFG (later lines win), then a restart. A
        # section line first, in case the last line has no end:
        for line in ["[Network]"] + self.settings:
            self.type(f"ECHO {line} >> C:\\CONF\\SYSTEM.CFG", 1)
        self.type("REBOOT", 1)

    def run(self, commands):
        for c in commands:
            self.type(c, 2)
        self.type(f"ECHO done > {LOG}:\\DONE.TXT", 2)

    def read(self, name):
        r = subprocess.run(["mtype", "-i", self.log, "::/" + name], capture_output=True)
        return r.stdout.decode(errors="replace") if r.returncode == 0 else ""

    def done(self):
        return "done" in self.read("DONE.TXT")

    def stop(self):
        try:
            self.type("SHUTDOWN", 1)
        except OSError:
            pass  # SHUTDOWN ended QEMU before its monitor was told to quit
        deadline = time.time() + 15
        while self.proc.poll() is None and time.time() < deadline:
            time.sleep(0.5)
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait()

    def keep(self, *names):
        # The log disk's files, beside the results:
        for n in names:
            with open(os.path.join(self.dir, n), "w") as f:
                f.write(self.read(n))


def parallel(fns):
    threads = [threading.Thread(target=f) for f in fns]
    for t in threads:
        t.start()
    for t in threads:
        t.join()


# THE CASES

def out(name):
    return f"{LOG}:\\{name}"


def router_case(edition, d, port, rtl, routing):
    second = "rtl8139" if rtl else None
    r = Machine(edition, d, "router", 1, [("listen", port, None), ("listen", port + 1, second)],
                [f"NET0=192.168.10.1/24 {mac_text(1, 1)}", f"NET1={mac_text(1, 2)} 192.168.20.1/24"]
                + (["ROUTING=true"] if routing else []))
    a = Machine(edition, d, "a", 2, [("connect", port, None)],
                ["NET0=192.168.10.10/24", "ROUTE=192.168.20.0/24 192.168.10.1"])
    b = Machine(edition, d, "b", 3, [("connect", port + 1, None)],
                ["NET0=192.168.20.10/24 192.168.20.1"])
    machines = [r, a, b]
    pings = 4 if routing else 2

    def steps():
        parallel([
            lambda: r.run([f"IPCONFIG > {out('IPC.TXT')}", f"NETSTAT -i > {out('IFACES.TXT')}",
                           f"NETSTAT -r > {out('ROUTES.TXT')}"]),
            lambda: a.run([f"PING -n {pings} 192.168.20.10 > {out('PING-B.TXT')}",
                           f"PING -n 2 192.168.20.1 > {out('PING-R.TXT')}",
                           f"NETSTAT -r > {out('ROUTES.TXT')}"]),
            lambda: b.run([f"PING -n {pings} 192.168.10.10 > {out('PING-A.TXT')}"]),
        ])

    def check(result):
        ipc = r.read("IPC.TXT")
        r.keep("IPC.TXT", "IFACES.TXT", "ROUTES.TXT")
        a.keep("PING-B.TXT", "PING-R.TXT", "ROUTES.TXT")
        b.keep("PING-A.TXT")
        result("R: two interfaces, NET0 and NET1", "NET0" in ipc and "NET1" in ipc and "NET2" not in ipc and "192.168.20.1" in ipc, ipc[:200])
        result("R: card 1 picked by its MAC", f"Physical address . . : {mac_text(1, 2)}" in ipc.split("NET1")[-1])
        if routing:
            result("R: IPCONFIG says routing is on", "Routing  . . . . . . : on" in ipc)
            result("R: NETSTAT -r lists both networks", "192.168.10.0/24" in r.read("ROUTES.TXT") and "192.168.20.0/24" in r.read("ROUTES.TXT"))
            result("A: NETSTAT -r has ROUTE='s route", "192.168.20.0/24" in a.read("ROUTES.TXT") and "ROUTE=" in a.read("ROUTES.TXT"))
            pb, pa = a.read("PING-B.TXT"), b.read("PING-A.TXT")
            # lwIP answers with TTL 255: one router on the way takes one off:
            result("A pings B through R (ROUTE=)", "Reply from 192.168.20.10" in pb and "TTL=254" in pb, pb[-160:])
            result("B pings A through R (ROUTER=)", "Reply from 192.168.10.10" in pa and "TTL=254" in pa, pa[-160:])
            pr = a.read("PING-R.TXT")
            result("A pings R's far side (R's own, no hop)", "Reply from 192.168.20.1" in pr and "TTL=255" in pr, pr[-160:])
        else:
            pb, pa = a.read("PING-B.TXT"), b.read("PING-A.TXT")
            result("R: IPCONFIG says routing is off", "Routing  . . . . . . : off" in ipc)
            result("without ROUTING=: A gets no answer from B", "Reply from" not in pb and "Request timed out" in pb, pb[-160:])
            result("without ROUTING=: B gets no answer from A", "Reply from" not in pa and "Request timed out" in pa, pa[-160:])
            pr = a.read("PING-R.TXT")
            result("without ROUTING=: R still answers on its far side", "Reply from 192.168.20.1" in pr, pr[-160:])

    return machines, steps, check


def bridge_case(edition, d, port, rtl):
    second = "rtl8139" if rtl else None
    br = Machine(edition, d, "bridge", 4, [("listen", port, None), ("listen", port + 1, second)],
                 [f"NET0=192.168.30.1/24 {mac_text(4, 1)}", "BRIDGE=0,1"])
    a = Machine(edition, d, "a", 5, [("connect", port, None)], ["NET0=192.168.30.10/24"])
    b = Machine(edition, d, "b", 6, [("connect", port + 1, None)], ["NET0=192.168.30.20/24"])
    machines = [br, a, b]

    def steps():
        parallel([
            lambda: br.run([f"IPCONFIG > {out('IPC.TXT')}", f"NETSTAT -i > {out('IFACES.TXT')}"]),
            lambda: a.run([f"PING -n 4 192.168.30.20 > {out('PING-B.TXT')}",
                           f"PING -n 2 192.168.30.1 > {out('PING-BR.TXT')}",
                           f"ARP -a > {out('ARP.TXT')}"]),
            lambda: b.run([f"PING -n 4 192.168.30.10 > {out('PING-A.TXT')}",
                           f"PING -n 2 192.168.30.1 > {out('PING-BR.TXT')}"]),
        ])

    def check(result):
        ipc = br.read("IPC.TXT")
        br.keep("IPC.TXT", "IFACES.TXT")
        a.keep("PING-B.TXT", "PING-BR.TXT", "ARP.TXT")
        b.keep("PING-A.TXT", "PING-BR.TXT")
        result("BR: one interface, a bridge of 0, 1", "Bridge . . . . . . . : Bridge of 0, 1" in ipc, ipc[:200])
        result("BR: the bridge has card 0's MAC", f"Physical address . . : {mac_text(4, 1)}" in ipc)
        pb, pa = a.read("PING-B.TXT"), b.read("PING-A.TXT")
        # Same segment: no router, the TTL stays 255:
        result("A pings B across the bridge", "Reply from 192.168.30.20" in pb and "TTL=255" in pb, pb[-160:])
        result("B pings A across the bridge", "Reply from 192.168.30.10" in pa and "TTL=255" in pa, pa[-160:])
        result("A's ARP has B's own MAC (the bridge is transparent)", mac_text(6, 1) in a.read("ARP.TXT"), a.read("ARP.TXT")[-200:])
        for name, m in (("A", a), ("B", b)):
            p = m.read("PING-BR.TXT")
            result(f"{name} pings the bridge's own address", "Reply from 192.168.30.1" in p, p[-160:])

    return machines, steps, check


# RUNNING

def run_case(edition, case, rtl, port):
    d = os.path.join(OUT, edition + ("-rtl8139" if rtl else ""), case)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    if case == "bridge":
        machines, steps, check = bridge_case(edition, d, port, rtl)
    else:
        machines, steps, check = router_case(edition, d, port, rtl, case == "router")
    results = []

    def result(name, ok, detail=""):
        results.append((name, ok, "" if ok else detail.replace("\n", " | ")))

    began = time.time()
    boot = EDITIONS[edition][2]
    try:
        machines[0].start()  # it listens: the others connect to it
        time.sleep(1)
        for m in machines[1:]:
            m.start()
        time.sleep(boot)
        parallel([m.configure for m in machines])
        time.sleep(boot)
        steps()
        deadline = time.time() + 120
        while not all(m.done() for m in machines) and time.time() < deadline:
            time.sleep(3)
        for m in machines:
            result(f"{m.name}: its commands finished", m.done())
        for m in machines:
            try:
                common.shot(m.mon, m.dir, "end")
            except Exception:
                pass
    finally:
        parallel([m.stop for m in machines])
    check(result)
    seconds = time.time() - began
    passed = sum(1 for r in results if r[1])
    with open(os.path.join(d, "results.md"), "w") as f:
        f.write(f"# Route tests: {edition}{' with an RTL8139' if rtl else ''}, {case}\n\n{passed} of {len(results)} passed, {seconds:.0f} s\n\n")
        for name, ok, detail in results:
            f.write(f"- {'PASS' if ok else 'FAIL'} {name}{' (' + detail + ')' if detail else ''}\n")
        f.write("\nEach machine's folder: its log disk's files, serial.txt, end.png\n")
    print(f"{edition}{' rtl8139' if rtl else ''} {case}: {passed} of {len(results)} passed ({seconds:.0f} s)")
    for name, ok, detail in results:
        if not ok:
            print(f"  FAIL {name}{' (' + detail + ')' if detail else ''}")
    return passed == len(results)


def main():
    args = sys.argv[1:]
    rtl = "--rtl8139" in args
    args = [a for a in args if a != "--rtl8139"]
    edition = args.pop(0) if args and args[0] in EDITIONS else common.NAME
    cases = args or ["router", "norouting", "bridge"]
    for c in cases:
        if c not in ("router", "norouting", "bridge"):
            raise SystemExit(f"unknown case {c}: router, norouting, bridge (editions: {', '.join(EDITIONS)})")
    common.require(os.path.join(common.BUILD, EDITIONS[edition][0], "system.img"), hint="build it first: zig build")
    ok = True
    for i, c in enumerate(cases):
        ok = run_case(edition, c, rtl, BASE_PORT + 10 * i) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
