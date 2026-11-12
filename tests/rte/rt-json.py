#!/usr/bin/env python3
# rt-json.py STAGE: build/rt-tests/STAGE/ -> docs/Real-Time-STAGE.json
import importlib.util, json, os, re, sys
D = os.path.dirname(os.path.abspath(__file__))
R = os.path.normpath(os.path.join(D, "..", ".."))
if len(sys.argv) != 2:
    sys.exit("usage: rt-json.py STAGE")
STAGE = sys.argv[1]
OUT = os.path.join(R, "docs", f"Real-Time-{STAGE}.json")
SRC = os.path.join(R, "build", "rt-tests", STAGE)
sys.argv = sys.argv[:1]
spec = importlib.util.spec_from_file_location("rtbase", os.path.join(D, "rt-tests.py"))
rtbase = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rtbase)

PHASES = {
    "idle": "RTLAT alone",
    "disk": "an ash loop copying an 8 MB file NETLOG -> C: and C: -> C:",
    "gfx": "DEMO rgb 1 (metal: full-screen true color) / DEMO gfx (BIOS: 320x200, 256 colors)",
    "http": "HTTPZ serving 4 host clients downloading 3 MB and 2 fetching a small page",
    "all": "disk, gfx and http at once",
}


def parse(text):
    part = text.split("Summary:", 1)[1]
    threads = [dict(zip(("count", "min_us", "last_us", "avg_us", "max_us", "overruns"), map(int, m)))
               for m in re.findall(r"T\d+: C:?\s*(\d+) Min:?\s*(\d+) Act:?\s*(\d+) Avg:?\s*(\d+) Max:?\s*(\d+) Overruns:?\s*(\d+)", part)]
    hist = {}
    for m in re.finditer(r"^\s*(>=)?\s*(\d+)-?:((?:\s+\d+)+)\s*$", part, re.M):
        hist[(">=" if m.group(1) else "") + m.group(2)] = [int(x) for x in m.group(3).split()]
    return threads, hist


def edition(name):
    ed, cores, kvm, threads, gfx, _, loops = rtbase.RUNS[name]
    d = os.path.join(SRC, name)
    r = {"edition": ed, "qemu_cores": cores, "accel": "KVM" if kvm else "TCG", "rtlat_threads": threads, "wakeups_per_thread": loops,
         "demo": gfx, "phases": {}}
    for p in PHASES:
        f = os.path.join(d, f"RT-{p.upper()}.TXT")
        if not os.path.exists(f) or "Summary:" not in open(f, errors="replace").read():
            continue
        th, hist = parse(open(f, errors="replace").read())
        r["phases"][p] = {
            "max_us": max(t["max_us"] for t in th), "avg_us": sum(t["avg_us"] for t in th) // len(th),
            "overruns": sum(t["overruns"] for t in th), "wakeups": sum(t["count"] for t in th),
            "threads": th, "histogram_100us": hist,
        }
    for n in (1, 2):
        f = os.path.join(d, f"COPIES{n}.TXT")
        if os.path.exists(f):
            r[f"copy_rounds_{'disk' if n == 1 else 'all'}"] = open(f).read().count("x")
    res = os.path.join(d, "results.md")
    if os.path.exists(res):
        m = re.search(r"H1 (\d+) s (\d+) MB, H2 (\d+) s (\d+) MB", open(res).read())
        if m:
            r["http_load"] = {"http": {"seconds": int(m[1]), "mb": int(m[2])}, "all": {"seconds": int(m[3]), "mb": int(m[4])}}
    return r


doc = {
    "what": f"RTLAT {STAGE}, docs/REALTIME.md: how late periodic wake-ups run, alone and under load",
    "date": __import__("time").strftime("%Y-%m-%d"),
    "rtlat": "RTLAT -t THREADS -a 0 -i 1000 -l LOOPS -h 100 -q (FIFO, priority 28, one thread per core from core 0)",
    "host": "QEMU on Linux 6.19 (Fedora 42) x86-64; ARM64 and bios-x86 emulated (TCG), so their times show the emulation too",
    "notes": [
        "max_us / overruns: the worst / the sum over threads; avg_us: the mean of the threads' averages",
        "HTTPZ is started after the gfx phase and runs to the end; it was idle outside the http and all phases",
    ],
    "phases": PHASES,
    "runs": {n: r for n in rtbase.RUNS if os.path.isdir(os.path.join(SRC, n)) for r in [edition(n)] if r["phases"]},
}
with open(OUT, "w") as f:
    json.dump(doc, f, indent=1)
    f.write("\n")
print(OUT, {n: list(r["phases"]) for n, r in doc["runs"].items()})