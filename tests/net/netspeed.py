#!/usr/bin/env python3
# NETSPEED's other end: TCP 5700 (send, recv, rr), UDP 5701.
#   netspeed.py [EDITION...]    in QEMU: metal-x86_64, metal-arm64,
#                               or net-tests.py's others; default
#                               from ZDOS_EDITION / ZDOS_ARCH:
#   ZDOS_EDITION=metal ZDOS_ARCH=arm64 python3 tests/net/netspeed.py
#   netspeed.py serve [ADDRESS] for ZDOS on real hardware: run
#                               NETSPEED <this machine> there
# Env: NETSPEED_OUT (build/netspeed), NETSPEED_SECONDS (10),
# NETSPEED_CARD (QEMU's card, e.g. virtio-net-pci), ZDOS_ACCEL=tcg (no KVM),
# NETSPEED_TESTS (some of: send recv rr udp), NETSPEED_MACHINE (ARM64:
# e.g. virt,gic-version=3 for a GICv3 with an ITS), NETSPEED_PCAP=1
# (the card's frames into card.pcap).
# QEMU's user network sits between: its numbers compare ZDOS with
# itself (before / after a change), not with the host's.
import importlib.util
import json
import os
import re
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import common  # noqa: E402

spec = importlib.util.spec_from_file_location("net_tests", os.path.join(HERE, "net-tests.py"))
nt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nt)

OUT = os.environ.get("NETSPEED_OUT", os.path.join(common.BUILD, "netspeed"))
SECONDS = int(os.environ.get("NETSPEED_SECONDS", "10"))
TCP_PORT = 5700
UDP_PORT = 5701
CHUNK = bytes(i & 0xFF for i in range(64 * 1024))

# THE SERVERS

host_results = []  # what this side measured
results_lock = threading.Lock()


def note(text):
    with results_lock:
        host_results.append(text)
    print("  host: " + text, flush=True)


def recv_exactly(sock, n):
    data = b""
    while len(data) < n:
        part = sock.recv(n - len(data))
        if not part:
            return None
        data += part
    return data


class Tcp(socketserver.BaseRequestHandler):
    def handle(self):
        s = self.request
        head = recv_exactly(s, 9)
        if head is None:
            return
        kind, a, _b = head[0:1], *struct.unpack("<II", head[1:9])
        if kind == b"S":
            self.sink(s)
        elif kind == b"R":
            self.source(s, a)
        elif kind == b"P":
            self.echo(s, a)

    def sink(self, s):
        total, began = 0, None
        while True:
            data = s.recv(1 << 20)
            if not data:
                break
            if began is None:
                began = time.perf_counter()
            total += len(data)
        took = time.perf_counter() - (began or time.perf_counter())
        note(f"send: {total * 8 / max(took, 1e-9) / 1e6:.1f} Mbit/s received ({total} bytes in {took * 1000:.0f} ms)")

    def source(self, s, seconds):
        s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 << 20)
        total, until = 0, time.perf_counter() + seconds
        began = time.perf_counter()
        try:
            while time.perf_counter() < until:
                s.sendall(CHUNK)
                total += len(CHUNK)
        except OSError as e:
            note(f"recv: sending failed ({e})")
            return
        s.shutdown(socket.SHUT_WR)
        took = time.perf_counter() - began
        note(f"recv: {total * 8 / took / 1e6:.1f} Mbit/s handed to the socket ({total} bytes)")

    def echo(self, s, count):
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        for _ in range(count):
            b = s.recv(1)
            if not b:
                return
            s.sendall(b)


class TcpServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def blast(sock, to, seconds, rate, size):
    # rate datagrams a second, numbered, then "END <sent>":
    pad = bytes(max(size - 4, 0))
    sent, began = 0, time.perf_counter()
    until = began + seconds
    while True:
        now = time.perf_counter()
        if now >= until:
            break
        due = int((now - began) * rate)
        while sent < due:
            try:
                sock.sendto(struct.pack("<I", sent) + pad, to)
            except OSError:
                pass  # full: counts as lost
            sent += 1
        time.sleep(0.0005)
    time.sleep(0.2)
    for _ in range(5):
        sock.sendto(f"END {sent}".encode(), to)
        time.sleep(0.05)
    note(f"udp: {sent} datagrams sent at {rate}/s of {size} bytes")


def udp_server(sock, stop):
    busy = set()
    while not stop.is_set():
        try:
            data, peer = sock.recvfrom(2048)
        except socket.timeout:
            continue
        if len(data) != 13 or data[0:1] != b"U" or peer in busy:
            continue  # a repeated request: already sending
        seconds, rate, size = struct.unpack("<III", data[1:13])
        busy.add(peer)

        def run(peer=peer, seconds=seconds, rate=rate, size=size):
            blast(sock, peer, seconds, rate, min(size, 1472))
            busy.discard(peer)
        threading.Thread(target=run, daemon=True).start()
    sock.close()


def start_servers(address):
    stop = threading.Event()
    tcp = TcpServer((address, TCP_PORT), Tcp)
    threading.Thread(target=tcp.serve_forever, daemon=True).start()
    # Bound here, so that a failed bind stops the run:
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    udp.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 << 20)
    udp.bind((address, UDP_PORT))
    udp.settimeout(0.5)
    waiter = threading.Thread(target=udp_server, args=(udp, stop), daemon=True)
    waiter.start()

    def shut():
        stop.set()
        waiter.join()
        tcp.shutdown()
        tcp.server_close()
    return shut

# ONE EDITION IN QEMU


def qemu_args(edition, d, sock):
    args = nt.qemu(edition, d, sock)
    card = os.environ.get("NETSPEED_CARD")
    if card:
        old = f"{nt.EDITIONS[edition][1]},netdev=n0,romfile="
        args = [f"{card},netdev=n0,romfile=" if a == old else a for a in args]
    machine = os.environ.get("NETSPEED_MACHINE")
    if machine:
        args = [machine if a in ("virt", "virt,gic-version=max", "q35", "pc") else a for a in args]
    # The card's frames both ways, as QEMU passes them:
    if os.environ.get("NETSPEED_PCAP", "0") != "0":
        args += ["-object", f"filter-dump,id=dump,netdev=n0,file={os.path.join(d, 'card.pcap')}"]
    return args


def run_edition(edition):
    d = os.path.join(OUT, edition)
    os.makedirs(d, exist_ok=True)
    for name in os.listdir(d):
        os.remove(os.path.join(d, name))
    img = os.path.join(d, "netlog.img")
    subprocess.run(["mkfs.fat", "-F", "16", "-n", "NETLOG", "-C", img, str(16 * 1024)], check=True, capture_output=True)
    sock = os.path.join(d, "monitor.sock")
    with results_lock:
        host_results.clear()
    shut = start_servers("127.0.0.1")

    def done():
        data = nt.mread(img, "NETSPEED.LOG")
        return data is not None and b"# NETSPEED: done" in data

    arm = nt.EDITIONS[edition][2]
    boot = 60 if arm else 35
    limit = SECONDS * (12 if arm else 4) + 300
    tests = os.environ.get("NETSPEED_TESTS", "")
    steps = (common.command(f"NETSPEED 10.0.2.2 {SECONDS} {tests}".rstrip(), 5)
             + [("until", done, limit), ("wait", 2), ("shot", "end", "the screen after the tests")]
             + common.command("SHUTDOWN", 15))
    began = time.time()
    try:
        common.run_qemu(qemu_args(edition, d, sock), steps, d, sock, boot_wait=boot)
    except BrokenPipeError:
        pass  # SHUTDOWN ended QEMU before its monitor was told to quit
    finally:
        shut()
    return report(edition, d, img, time.time() - began)


def parse(log):
    # NETSPEED's lines as numbers:
    out = {}
    for line in log.splitlines():
        m = re.match(r"(send|recv): ([\d.]+) Mbit/s \((\d+) bytes in (\d+) ms\)", line)
        if m:
            out[m[1]] = {"mbit": float(m[2]), "bytes": int(m[3]), "ms": int(m[4])}
        m = re.match(r"rr: (\d+) round trips, (\d+)/s; min (\d+) us, median (\d+) us, 99% (\d+) us, max (\d+) us", line)
        if m:
            out["rr"] = dict(zip(("count", "per_s", "min_us", "median_us", "p99_us", "max_us"), map(int, m.groups())))
        m = re.match(r"udp: (\d+) sent at (\d+)/s of (\d+) bytes, (\d+) received, ([\d.]+)% lost, (\d+) out of order", line)
        if m:
            g = m.groups()
            out["udp"] = {"sent": int(g[0]), "rate": int(g[1]), "size": int(g[2]), "received": int(g[3]),
                          "lost_pct": float(g[4]), "out_of_order": int(g[5])}
        m = re.match(r"card: (.*); interrupts: (.*); own core: (.*)", line)
        if m:
            out["card"] = {"name": m[1], "interrupts": m[2], "own_core": m[3]}
    return out


def report(edition, d, img, seconds):
    log = (nt.mread(img, "NETSPEED.LOG") or b"").decode(errors="replace")
    with open(os.path.join(d, "NETSPEED.LOG"), "w") as f:
        f.write(log)
    m = re.search(r"# NETSPEED: done, (\d+) failed", log)
    finished = m is not None and m[1] == "0"
    numbers = parse(log)
    numbers["edition"] = edition
    numbers["seconds_each"] = SECONDS
    numbers["host"] = list(host_results)
    with open(os.path.join(d, "results.json"), "w") as f:
        json.dump(numbers, f, indent=2)
    lines = [l for l in log.splitlines() if not l.startswith("#")]
    with open(os.path.join(d, "results.md"), "w") as f:
        f.write(f"# NETSPEED: {edition}\n\n{'passed' if finished else 'FAILED'}, {seconds:.0f} s\n\n")
        f.write("ZDOS:\n\n" + "".join(f"- {l}\n" for l in lines))
        f.write("\nHost:\n\n" + "".join(f"- {l}\n" for l in host_results))
        f.write("\nScreenshot: end.png\n")
    print(f"{edition}: {'passed' if finished else 'FAILED'} ({seconds:.0f} s)")
    for l in lines:
        print("  " + l)
    return finished

# REAL HARDWARE


def serve(address):
    shut = start_servers(address)
    print(f"Waiting on {address}: TCP {TCP_PORT}, UDP {UDP_PORT}; Ctrl+C ends", flush=True)
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    shut()


def main():
    if sys.argv[1:2] == ["serve"]:
        return serve(sys.argv[2] if len(sys.argv) > 2 else "0.0.0.0")
    editions = sys.argv[1:] or [common.NAME]
    for e in editions:
        if e not in nt.EDITIONS:
            raise SystemExit(f"unknown edition {e}: {', '.join(nt.EDITIONS)}")
        common.require(os.path.join(common.BUILD, nt.EDITIONS[e][0], "system.img"), hint="build it first: zig build")
    ok = True
    for e in editions:
        ok = run_edition(e) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
