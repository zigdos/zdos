#!/usr/bin/env python3
# RTLAT measurements in QEMU: RTLAT alone, under disk copies, DEMO
# graphics, HTTPZ traffic and all at once. Results in
# build/rt-tests/<stage>/<edition>/ (RT_STAGE=..., default "current").
#   rt-tests.py [EDITION...]   metal-x86_64, bios-kvm, bios-x86,
#                              metal-arm64, metal-x86_64-virtio (if named)
# Default from ZDOS_EDITION / ZDOS_ARCH (tests/common.py), metal x86_64:
#   ZDOS_EDITION=bios ZDOS_ARCH=x86 python3 tests/rte/rt-tests.py
import http.client, importlib.util, os, re, shutil, subprocess, sys, threading, time
R = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
D = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(R, "tests"))
import common  # noqa: E402
spec = importlib.util.spec_from_file_location("nt", os.path.join(R, "tests/net/net-tests.py"))
nt = importlib.util.module_from_spec(spec); spec.loader.exec_module(nt)

HTTP_PORT = 18181
LOOPS = 20000  # 20 s per phase at 1 ms
BIG = bytes((i * 131 + i // 997) & 0xFF for i in range(8_000_000))  # the disk load
WWW = bytes((i * 7 + i // 251) & 0xFF for i in range(3_000_000))  # the HTTP load
CFG = "PORT=80\r\nHTTPS_PORT=0\r\nCGI_DIR=\r\nMAX_CLIENTS=64\r\nMAX_FILE_SIZE=8MB\r\nLOG=C:/DATA/LOGS/httpz.log\r\n"
# name: (net-tests edition, cores, KVM, RTLAT threads, DEMO mode, boot
# wait, wake-ups per phase). BIOS: 2000, as the baseline's 10 ms tick.
RUNS = {
    "metal-x86_64": ("metal-x86_64", 4, True, 4, "rgb", 35, 20000),
    "bios-kvm": ("bios-x86", 2, True, 1, "gfx", 20, 2000),
    "bios-x86": ("bios-x86", 2, False, 1, "gfx", 20, 2000),
    "metal-arm64": ("metal-arm64", 2, False, 2, "rgb", 60, 20000),
    "metal-x86_64-virtio": ("metal-x86_64", 4, True, 4, "rgb", 35, 20000),
}
# On virtio devices, as KVM clouds have them:
VIRTIO = {
    "metal-x86_64-virtio": {
        "nvme,serial=ZDOS0001,drive=nvme0,bootindex=0": "virtio-blk-pci,drive=nvme0,bootindex=0",
        "e1000e,netdev=n0,romfile=": "virtio-net-pci,netdev=n0,romfile=",
    },
}


def put(img, path, data):
    tmp = os.path.join(os.path.dirname(img), "put.tmp")
    with open(tmp, "wb") as f:
        f.write(data)
    subprocess.run(["mcopy", "-o", "-i", img, tmp, "::/" + path], check=True, capture_output=True)
    os.remove(tmp)


def prepare(img):
    subprocess.run(["mkfs.fat", "-F", "16", "-n", "NETLOG", "-C", img, str(48 * 1024)], check=True, capture_output=True)
    for folder in ("SETUP", "SETUP/CONF", "SETUP/WWW"):
        subprocess.run(["mmd", "-i", img, "::/" + folder], check=True, capture_output=True)
    put(img, "SETUP/CONF/HTTPZ.CFG", CFG.encode())
    put(img, "SETUP/WWW/index.html", b"<p>rtbase</p>\n")
    put(img, "SETUP/WWW/big.bin", WWW)
    put(img, "BIG.BIN", BIG)
    text = open(os.path.join(D, "RTBASE.CMD"), "rb").read().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
    put(img, "RTBASE.CMD", text)


class Load:
    # HTTP clients while H<n>.GO is there and H<n>.END not yet.
    def __init__(self, img):
        self.img, self.stop, self.bytes, self.requests, self.errors = img, threading.Event(), 0, 0, 0
        self.active = threading.Event()
        self.windows = []
        self.lock = threading.Lock()

    def has(self, name):
        return nt.mread(self.img, name) is not None

    def keys(self, sock):
        # A key to DEMO (the front tab) on GFX<n>.STOP:
        for n in (1, 2):
            while not self.stop.is_set() and not self.has(f"GFX{n}.STOP"):
                time.sleep(1)
            if self.stop.is_set():
                return
            try:
                common.Monitor(sock).cmd("sendkey spc")
            except OSError:
                pass

    def control(self):
        n = 1
        while not self.stop.is_set() and n <= 2:
            if not self.active.is_set():
                if self.has(f"H{n}.GO"):
                    began = time.time()
                    while not self.stop.is_set() and not nt_answers() and time.time() - began < 120:
                        time.sleep(0.5)
                    b0 = self.bytes
                    self.active.set()
                    t0 = time.time()
                    time.sleep(1)
                    get("/loadstart")
                    self.windows.append([n, t0, None, b0])
            elif self.has(f"H{n}.END"):
                self.active.clear()
                w = self.windows[-1]
                w[2] = time.time()
                w[3] = self.bytes - w[3]
                n += 1
            time.sleep(1)

    def client(self, path):
        while not self.stop.is_set():
            if not self.active.wait(0.5):
                continue
            try:
                c = http.client.HTTPConnection("127.0.0.1", HTTP_PORT, timeout=20)
                while self.active.is_set():
                    c.request("GET", path)
                    body = c.getresponse().read()
                    with self.lock:
                        self.bytes += len(body)
                        self.requests += 1
                c.close()
            except Exception:
                with self.lock:
                    self.errors += 1
                time.sleep(0.2)

    def start(self, sock):
        threading.Thread(target=self.control, daemon=True).start()
        threading.Thread(target=self.keys, args=(sock,), daemon=True).start()
        for path in ["/big.bin"] * 4 + ["/index.html"] * 2:
            threading.Thread(target=self.client, args=(path,), daemon=True).start()


def nt_answers():
    try:
        c = http.client.HTTPConnection("127.0.0.1", HTTP_PORT, timeout=3)
        c.request("HEAD", "/")
        ok = c.getresponse().status == 200
        c.close()
        return ok
    except Exception:
        return False


def get(path):
    try:
        c = http.client.HTTPConnection("127.0.0.1", HTTP_PORT, timeout=5)
        c.request("GET", path)
        c.getresponse().read()
        c.close()
    except Exception:
        pass


def summary(text):
    # T<n> lines after "Summary:" -> (threads, min, avg, max, overruns).
    part = text.split("Summary:", 1)[-1] if "Summary:" in text else ""
    rows = [tuple(int(x) for x in m) for m in
            re.findall(r"T\d+: C:?\s*(\d+) Min:?\s*(\d+) Act:?\s*\d+ Avg:?\s*(\d+) Max:?\s*(\d+) Overruns:?\s*(\d+)", part)]
    if not rows:
        return None
    return dict(threads=len(rows), count=sum(r[0] for r in rows), min=min(r[1] for r in rows),
                avg=sum(r[2] for r in rows) // len(rows), max=max(r[3] for r in rows), over=sum(r[4] for r in rows))


STAGE = os.environ.get("RT_STAGE", "current")
OUT = os.path.join(R, "build", "rt-tests", STAGE)


def run(name):
    edition, cores, kvm, threads, gfx, boot, loops = RUNS[name]
    d = os.path.join(OUT, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    img = os.path.join(d, "netlog.img")
    prepare(img)
    sock = os.path.join(d, "m.sock")
    args = nt.qemu(edition, d, sock, forwards=f",hostfwd=tcp:127.0.0.1:{HTTP_PORT}-:80")
    args = [a.replace("hostfwd=tcp:127.0.0.1:18080-", "hostfwd=tcp:127.0.0.1:18180-") for a in args]
    swap = VIRTIO.get(name, {})
    missing = [k for k in swap if k not in args]
    if missing:
        sys.exit(f"{name}: no {missing} in the QEMU command to replace")
    args = [swap.get(a, a) for a in args]
    args[args.index("-smp") + 1] = str(cores)
    # The run's own choice, not the host's (tests/common.py): KVM or TCG
    out = []
    i = 0
    while i < len(args):
        if args[i] == "-accel" or (args[i] == "-cpu" and args[i + 1] == "host"):
            i += 2
            continue
        out.append(args[i])
        i += 1
    args = out
    args[1:1] = ["-accel", "kvm"] + ([] if "-cpu" in args else ["-cpu", "host"]) if kvm else ["-accel", "tcg"]
    load = Load(img)
    keysock = os.path.join(d, "k.sock")
    args += ["-monitor", f"unix:{keysock},server,nowait"]
    load.start(keysock)
    began = time.time()
    # The NETLOG disk is D: beside NVMe; elsewhere found by its batch file:
    start = f"D:\\RTBASE.CMD D {threads} {gfx} {loops}"
    if name in VIRTIO:
        start = f"FOR %d IN (D E F G) DO IF EXIST %d:\\RTBASE.CMD %d:\\RTBASE.CMD %d {threads} {gfx} {loops}"
    steps = (common.command("HTTPTEST SETUP", 8)
             + [("until", lambda: b"# SETUP done" in (nt.mread(img, "SETUP.LOG") or b""), 180)]
             + common.command(start, 3)
             + [("until", lambda: load.has("RTBASE.END"), 5400), ("wait", 3), ("shot", "end")]
             + common.command("SHUTDOWN", 15))
    try:
        common.run_qemu(args, steps, d, sock, boot_wait=boot)
    except BrokenPipeError:
        pass
    finally:
        load.stop.set()
    seconds = time.time() - began
    files = subprocess.run(["mdir", "-b", "-i", img, "::/"], capture_output=True, text=True).stdout.split()
    for f in files:
        base = f.split("/")[-1]
        if base.upper().endswith(".TXT") or base.upper().endswith(".LOG"):
            nt.mcopy(img, base, os.path.join(d, base))
    out = [f"# RTLAT {STAGE}: {name}", "",
           f"QEMU {edition}, {cores} cores, {'KVM' if kvm else 'TCG'}; RTLAT -t {threads} -a 0 -i 1000 -l {loops} -h 100; "
           f"DEMO {gfx}; {seconds:.0f} s", "",
           "| phase | threads | wake-ups | min us | avg us | max us | overruns |", "|---|---|---|---|---|---|---|"]
    for phase in ("IDLE", "DISK", "GFX", "HTTP", "ALL"):
        p = os.path.join(d, f"RT-{phase}.TXT")
        s = summary(open(p, errors="replace").read()) if os.path.exists(p) else None
        out.append(f"| {phase.lower()} | " + (" | ".join(str(s[k]) for k in ("threads", "count", "min", "avg", "max", "over"))
                                             if s else "missing | | | | | ") + " |")
    out += ["", "HTTP load windows (phase, seconds, MB fetched): " +
            ", ".join(f"H{w[0]} {((w[2] or time.time()) - w[1]):.0f} s {w[3] / 1e6:.0f} MB" for w in load.windows if w[2]),
            f"HTTP requests {load.requests}, client errors {load.errors}", ""]
    if os.path.exists(os.path.join(d, "RTBASE.LOG")):
        for c in ("COPIES1.TXT", "COPIES2.TXT"):
            p = os.path.join(d, c)
            out.append(f"{c}: {open(p).read().count('x') if os.path.exists(p) else 0} copy rounds (8 MB in, 8 MB C: to C:)")
        out += ["RTBASE.LOG:", "```", open(os.path.join(d, "RTBASE.LOG"), errors="replace").read().strip(), "```"]
    text = "\n".join(out) + "\n"
    open(os.path.join(d, "results.md"), "w").write(text)
    print(text, flush=True)


if __name__ == "__main__":
    for n in sys.argv[1:] or [common.NAME]:
        run(n)