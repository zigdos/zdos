#!/usr/bin/env python3
# The network in QEMU: runs NETTEST, POSIXTEST net and ZDLTEST against
# servers here (the guest reaches them at 10.0.2.2), checks the results.
#   net-tests.py [EDITION...]   metal-x86_64, metal-e1000, uefi-x86_64,
#                               metal-arm64, uefi-arm64, bios-x86
# Default: ZDOS_EDITION / ZDOS_ARCH (tests/common.py), metal x86_64:
#   ZDOS_EDITION=uefi ZDOS_ARCH=x86_64 python3 tests/net/net-tests.py
# Host 18080 -> guest 8080. FETCH
# https://example.org needs this computer's internet.
import hashlib
import http.server
import os
import shutil
import socket
import socketserver
import ssl
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import common  # noqa: E402

OUT = os.path.join(common.BUILD, "net-tests")
HELLO = b"Hello from the host\n"
BIG = bytes((i * 31 + i // 1000) & 0xFF for i in range(300_000))

# THE SERVERS


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            data = self.request.recv(65536)
            if not data:
                return
            self.request.sendall(data)


class Http(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/hello.txt")
            self.end_headers()
            return
        body = {"/hello.txt": HELLO, "/big.bin": BIG}.get(self.path)
        if body is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def udp_echo(stop):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 5556))
    s.settimeout(0.5)
    while not stop.is_set():
        try:
            data, addr = s.recvfrom(65536)
            s.sendto(data, addr)
        except socket.timeout:
            pass
    s.close()


def incoming(stop, result):
    # Through hostfwd, until it answers.
    while not stop.is_set() and not result:
        try:
            with socket.create_connection(("127.0.0.1", 18080), timeout=2) as c:
                c.sendall(b"ping-in")
                data = b""
                while len(data) < 7:
                    part = c.recv(7 - len(data))
                    if not part:
                        break
                    data += part
                if data == b"pong-in":
                    result.append(True)
                    return
        except OSError:
            pass
        time.sleep(0.5)


class TlsServer(Server):
    # Each connection wrapped in TLS of the context's version.
    def __init__(self, addr, handler, context):
        self.context = context
        super().__init__(addr, handler)

    def get_request(self):
        conn, addr = super().get_request()
        return self.context.wrap_socket(conn, server_side=True), addr


def tls_context(cert, key, version):
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    c.load_cert_chain(cert, key)
    c.minimum_version = version
    c.maximum_version = version
    return c


def certificate(d, kind):
    # For 10.0.2.2: kind "ec" (P-256) or "rsa".
    cert, key = os.path.join(d, f"cert-{kind}.pem"), os.path.join(d, f"key-{kind}.pem")
    algo = ["-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1"] if kind == "ec" else ["-newkey", "rsa:2048"]
    subprocess.run(["openssl", "req", "-x509"] + algo + ["-nodes", "-keyout", key, "-out", cert, "-days", "30",
                    "-subj", "/CN=10.0.2.2", "-addext", "subjectAltName=IP:10.0.2.2"], check=True, capture_output=True)
    return cert, key


def start_servers(d):
    stop = threading.Event()
    cert, key = certificate(d, "ec")
    rsa_cert, rsa_key = certificate(d, "rsa")
    servers = [Server(("127.0.0.1", 5555), Echo), Server(("127.0.0.1", 8000), Http),
               TlsServer(("127.0.0.1", 8443), Http, tls_context(cert, key, ssl.TLSVersion.TLSv1_3)),
               TlsServer(("127.0.0.1", 8444), Http, tls_context(cert, key, ssl.TLSVersion.TLSv1_2)),
               TlsServer(("127.0.0.1", 8445), Http, tls_context(rsa_cert, rsa_key, ssl.TLSVersion.TLSv1_2))]
    for s in servers:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    threading.Thread(target=udp_echo, args=(stop,), daemon=True).start()
    came_in = []
    threading.Thread(target=incoming, args=(stop, came_in), daemon=True).start()

    def shut():
        stop.set()
        for s in servers:
            s.shutdown()
            s.server_close()
    return shut, came_in

# THE EDITIONS


aavmf = common.aavmf  # also for the suites that load this one


EDITIONS = {
    # name: (build folder, card, arm64)
    "metal-x86_64": ("metal-x86_64", "e1000e", False),
    "metal-e1000": ("metal-x86_64", "e1000", False),
    "uefi-x86_64": ("uefi-x86_64", "virtio-net-pci", False),
    "metal-arm64": ("metal-arm64", "e1000e", True),
    "uefi-arm64": ("uefi-arm64", "virtio-net-pci", True),
    "bios-x86": ("bios-x86", "e1000", False),
}


def qemu(edition, d, sock, forwards=""):
    # forwards: more of QEMU's hostfwd= for ssh-tests.py.
    folder, card, arm = EDITIONS[edition]
    system = os.path.join(d, "system.img")
    shutil.copyfile(os.path.join(common.BUILD, folder, "system.img"), system)
    if edition == "bios-x86":
        code = settings = None
    else:
        code, settings = aavmf() if arm else common.ovmf()
    own = os.path.join(d, "VARS.fd")
    if settings:
        shutil.copyfile(settings, own)
    # romfile=: no iPXE ROM, which keeps the firmware 4 s:
    net = ["-netdev", "user,id=n0,hostfwd=tcp:127.0.0.1:18080-:8080" + forwards, "-device", f"{card},netdev=n0,romfile="]
    log = ["-drive", f"file={os.path.join(d, 'netlog.img')},if=none,id=log,format=raw"]
    if edition == "bios-x86":
        # SeaBIOS PC, two Pentium III cores; the log disk is IDE 1:
        return ["qemu-system-i386", "-machine", "pc", "-cpu", "pentium3", "-smp", "2", "-m", "256M",
                "-drive", f"file={system},format=raw,if=ide,index=0",
                "-drive", f"file={os.path.join(d, 'netlog.img')},format=raw,if=ide,index=1",
                "-boot", "c", "-display", "none", "-rtc", "base=localtime",
                "-serial", f"file:{os.path.join(d, 'serial.txt')}",
                "-monitor", f"unix:{sock},server,nowait"] + net
    common_args = [
        "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
        "-drive", f"if=pflash,format=raw,file={own}",
        "-drive", f"file={system},if=none,id=nvme0,format=raw",
        "-device", "nvme,serial=ZDOS0001,drive=nvme0,bootindex=0",
        "-device", "qemu-xhci", "-device", "usb-kbd",
        "-display", "none", "-rtc", "base=localtime",
        "-serial", f"file:{os.path.join(d, 'serial.txt')}",
        "-monitor", f"unix:{sock},server,nowait",
    ] + net + log
    if arm:
        gfx = ["-device", "ramfb"] if edition.startswith("metal") else ["-device", "virtio-gpu-pci"]
        return (["qemu-system-aarch64", *common.arm_machine(), "-smp", "2", "-m", "512M"]
                + gfx + common_args + ["-device", "usb-storage,drive=log"])  # after the USB controller
    return ["qemu-system-x86_64", *common.x86_accel(), "-machine", "q35", "-smp", "2", "-m", "512M", "-vga", "std",
            "-device", "ide-hd,drive=log,bus=ide.1"] + common_args


def mread(img, name):
    r = subprocess.run(["mtype", "-i", img, "::/" + name], capture_output=True)
    return r.stdout if r.returncode == 0 else None


def mcopy(img, name, to):
    return subprocess.run(["mcopy", "-n", "-o", "-i", img, "::/" + name, to], capture_output=True).returncode == 0

# ONE EDITION


def run_edition(edition):
    d = os.path.join(OUT, edition)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    img = os.path.join(d, "netlog.img")
    subprocess.run(["mkfs.fat", "-F", "16", "-n", "NETLOG", "-C", img, str(16 * 1024)], check=True, capture_output=True)
    sock = os.path.join(d, "monitor.sock")
    shut, came_in = start_servers(d)
    began = time.time()

    def has(name, marker):
        def done():
            data = mread(img, name)
            return data is not None and marker in data
        return done

    boot = 60 if EDITIONS[edition][2] else 20 if edition == "bios-x86" else 35
    steps = (common.command("NETTEST", 5)
             + [("until", has("NETTEST.LOG", b"# NETTEST:"), 300), ("wait", 3)]
             + common.command("POSIXTEST net > %NETLOG%\\CNET.TXT", 5)
             + [("until", has("CNET.TXT", b"# POSIXTEST net:"), 120), ("wait", 2)]
             # ZCRYPT.ZDL (Argon2 takes a while on the slower editions):
             + common.command("ZDLTEST > %NETLOG%\\ZDL.TXT", 5)
             + [("until", has("ZDL.TXT", b"# ZDLTEST:"), 180), ("wait", 2),
                ("shot", "end", "the screen after the tests")]
             + common.command("SHUTDOWN", 15))
    try:
        common.run_qemu(qemu(edition, d, sock), steps, d, sock, boot_wait=boot)
    except BrokenPipeError:
        pass  # SHUTDOWN ended QEMU before its monitor was told to quit
    finally:
        shut()
    seconds = time.time() - began
    return check(edition, d, img, came_in, seconds)


def check(edition, d, img, came_in, seconds):
    results = []

    def result(name, ok, detail=""):
        results.append((name, ok, detail))

    log = (mread(img, "NETTEST.LOG") or b"").decode(errors="replace")
    with open(os.path.join(d, "NETTEST.LOG"), "w") as f:
        f.write(log)
    result("NETTEST finished", "# NETTEST:" in log)
    for line in log.splitlines():
        if line.startswith("ok - ") or line.startswith("not ok - "):
            result("NETTEST " + line.split(" - ", 1)[1], line.startswith("ok"))
    result("incoming connection answered (host side)", bool(came_in))

    cnet = (mread(img, "CNET.TXT") or b"").decode(errors="replace")
    with open(os.path.join(d, "CNET.TXT"), "w") as f:
        f.write(cnet)
    result("POSIXTEST net finished", "# POSIXTEST net:" in cnet)
    for line in cnet.splitlines():
        if line.startswith("ok ") or line.startswith("not ok "):
            result("POSIXTEST net " + line.split(" - ", 1)[-1], line.startswith("ok"))

    zdl = (mread(img, "ZDL.TXT") or b"").decode(errors="replace")
    with open(os.path.join(d, "ZDL.TXT"), "w") as f:
        f.write(zdl)
    result("ZDLTEST finished", "# ZDLTEST:" in zdl)
    for line in zdl.splitlines():
        if line.startswith("ok - ") or line.startswith("not ok - "):
            result("ZDLTEST " + line.split(" - ", 1)[1], line.startswith("ok"))

    def tool(name, *needles):
        text = (mread(img, name) or b"").decode(errors="replace")
        with open(os.path.join(d, name), "w") as f:
            f.write(text)
        missing = [n for n in needles if n not in text]
        result(f"{name} has {', '.join(needles)}", not missing and bool(text), "missing: " + ", ".join(missing) if missing else "")

    # Metal: the network's own core (QEMU has 2), which e1000e's
    # MSI-X reaches; BIOS: its e1000's interrupt (net_polled off):
    folder, card, arm = EDITIONS[edition]
    metal = edition.startswith("metal") or edition == "bios-x86"
    interrupts = "yes" if card == "e1000e" or edition == "bios-x86" else "no (polled)"
    tool("TOOL-IPC.TXT", "IPv4 address . . . . : 10.0.2.15", "Default gateway  . . : 10.0.2.2", "DNS servers  . . . . : 10.0.2.3",
         "Interrupts . . . . . : " + interrupts, "Own CPU core . . . . : " + ("yes" if metal else "no"))
    tool("TOOL-PNG.TXT", "Reply from 10.0.2.2", "Received = 2")
    tool("TOOL-NSL.TXT", "Address:  127.0.0.1")
    tool("TOOL-NST.TXT", "Proto", "UDP")
    tool("TOOL-ARP.TXT", "10.0.2.2", "dynamic")
    tool("TOOL-F1.TXT", HELLO.decode().strip())
    tool("TOOL-F2.TXT", HELLO.decode().strip())
    for name, what in (("TOOL-BIG.BIN", "FETCH -o big.bin (300 KB) matches"),
                       ("TOOL-TBG.BIN", "FETCH -k -o big.bin over TLS 1.3 matches")):
        path = os.path.join(d, name)
        got = mcopy(img, name, path) and open(path, "rb").read()
        result(what, got == BIG, f"{len(got) if got else 0} bytes" if got != BIG else "")
    tool("TOOL-T13.TXT", HELLO.decode().strip())
    tool("TOOL-T12.TXT", HELLO.decode().strip())
    tool("TOOL-TR2.TXT", HELLO.decode().strip())
    # COMMAND's "Program exited with code 1" goes into the file:
    result("FETCH refuses a self-signed certificate",
           "TOOL-TSS.TXT: exit code 1" in log and HELLO.strip() not in (mread(img, "TOOL-TSS.TXT") or b""))
    tool("TOOL-TEX.TXT", "Example Domain")

    # Speed, for the report:
    for line in log.splitlines():
        if line.startswith("# 1 MiB"):
            result("timing: " + line[2:], True)
    ping = (mread(img, "TOOL-PNG.TXT") or b"").decode(errors="replace")
    for line in ping.splitlines():
        if "Average" in line:
            result("timing: ping " + line.strip(), True)

    passed = sum(1 for r in results if r[1])
    with open(os.path.join(d, "results.md"), "w") as f:
        f.write(f"# Network tests: {edition}\n\n{passed} of {len(results)} passed, {seconds:.0f} s\n\n")
        for name, ok, detail in results:
            f.write(f"- {'PASS' if ok else 'FAIL'} {name}{' (' + detail + ')' if detail else ''}\n")
        f.write("\nScreenshot: end.png\n")
    print(f"{edition}: {passed} of {len(results)} passed ({seconds:.0f} s)")
    for name, ok, detail in results:
        if not ok:
            print(f"  FAIL {name}{' (' + detail + ')' if detail else ''}")
    return passed == len(results)


def main():
    editions = sys.argv[1:] or [common.NAME]
    for e in editions:
        if e not in EDITIONS:
            raise SystemExit(f"unknown edition {e}: {', '.join(EDITIONS)}")
        common.require(os.path.join(common.BUILD, EDITIONS[e][0], "system.img"), hint="build it first: zig build")
    ok = True
    for e in editions:
        ok = run_edition(e) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
