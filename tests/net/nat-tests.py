#!/usr/bin/env python3
# NAT, the DHCP server and the DNS server in QEMU:
#   A, A2, A3 (DHCP) --hub-- R (NAT=1; DHCPD, DNSD) --- B 192.168.20.10
# B has no route back to 192.168.10.0/24: only NAT brings answers home.
# B, R's upstream DNS, logs each query: the counts show R's cache.
#   nat-tests.py [EDITION]   bios-x86, metal-x86_64, metal-e1000
# Default: ZDOS_EDITION / ZDOS_ARCH (tests/common.py), metal x86_64:
#   ZDOS_EDITION=bios ZDOS_ARCH=x86 python3 tests/net/nat-tests.py
# Env: NAT_OUT, NAT_APPS, NAT_IMAGES, NAT_PORT; ZDOS_ACCEL=tcg: no KVM.
import importlib.util
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("route_tests", os.path.join(HERE, "route-tests.py"))
rt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rt)
common = rt.common

if os.environ.get("NAT_IMAGES"):
    common.BUILD = os.environ["NAT_IMAGES"]
OUT = os.environ.get("NAT_OUT", os.path.join(common.BUILD, "nat-tests"))
BASE_PORT = int(os.environ.get("NAT_PORT", "17500"))
LOG = rt.LOG
CPU = {"bios-x86": "x86", "metal-x86_64": "x86_64", "metal-e1000": "x86_64"}


def service_app(edition, name):
    folder = os.environ.get("NAT_APPS")
    if folder:
        return os.path.join(folder, f"{name}-{CPU[edition]}.APP")
    return os.path.join(common.BUILD, rt.EDITIONS[edition][0], "APPS", f"{name}.APP")


def app(edition):
    cpu = CPU[edition]
    folder = os.environ.get("NAT_APPS")
    if folder:
        return os.path.join(folder, f"NATTEST-{cpu}.APP")
    path = os.path.join(OUT, f"NATTEST-{cpu}.APP")
    subprocess.run([os.path.join(common.ROOT, "sdk", "bin", "zdos-cc"), f"--arch={cpu}", "-O2",
                    os.path.join(HERE, "nattest.c"), "-o", path], check=True)
    return path


class Machine(rt.Machine):
    # cables as route-tests', and ("hub", port, model): a multicast network.
    def __init__(self, edition, d, name, number, cables, settings, hosts, commands, nattest, files=(), setup=()):
        super().__init__(edition, d, name, number, [(h if h != "hub" else "listen", p, m) for h, p, m in cables], settings)
        for i, (how, port, _) in enumerate(cables):
            if how == "hub":
                k = self.nets.index(f"socket,id=n{i},listen=127.0.0.1:{port}")
                self.nets[k] = f"socket,id=n{i},mcast=230.0.0.1:{port},localaddr=127.0.0.1"
        # The settings and HOSTS.CFG lines by a batch file on the log disk
        # (then a restart), the test's commands by another:
        cfg = ["ECHO [Network] >> C:\\CONF\\SYSTEM.CFG"] + [f"ECHO {s} >> C:\\CONF\\SYSTEM.CFG" for s in settings]
        cfg += [f"ECHO {h} >> C:\\CONF\\HOSTS.CFG" for h in hosts] + list(setup) + ["REBOOT"]
        run = commands + [f"ECHO done > {LOG}:\\DONE.TXT"]
        for name, lines in (("CFG.BAT", cfg), ("RUN.BAT", run)):
            path = os.path.join(self.dir, name)
            with open(path, "w", newline="") as f:
                f.write("\r\n".join(lines) + "\r\n")
            subprocess.run(["mcopy", "-i", self.log, path, "::/" + name], check=True, capture_output=True)
        subprocess.run(["mcopy", "-i", self.log, nattest, "::/NATTEST.APP"], check=True, capture_output=True)
        for path, name in files:
            subprocess.run(["mcopy", "-i", self.log, path, "::/" + name], check=True, capture_output=True)

    def configure(self):
        self.type(f"{LOG}:\\CFG.BAT", 1)


def out(name):
    return f"{LOG}:\\{name}"


def nat_case(edition, d, port, nattest):
    hub, wire = port, port + 1
    m = rt.mac_text
    t = f"{LOG}:\\NATTEST.APP"
    # 255 fixed hosts off the network, A's the 256th, one past the limit;
    # the second DHCPD.CFG has A2's in the last place instead:
    rd = os.path.join(d, "router-files")
    os.makedirs(rd)
    fillers = [f"52-54-00-AA-{i // 256:02X}-{i % 256:02X} 172.16.{i // 250}.{i % 250 + 1}" for i in range(254)]

    def dhcpd_cfg(last):
        return ["# nat-tests.py", "RANGE=0 192.168.10.100-192.168.10.200 5", "LOG=C:\\DATA\\LOGS\\dhcpd.log"] + fillers + \
            [last, f"{m(2, 1)} 192.168.10.7", "52:54:00:BB:00:01 172.17.0.1"]
    texts = {
        "DHCPD.CFG": dhcpd_cfg("52-54-00-AA-FF-FE 172.16.99.1"),
        "DHCPD2.CFG": dhcpd_cfg(f"{rt.mac(4, 1)} 192.168.10.50"),
        "DNSD.CFG": ["CARDS=true", "CACHE=128", "LOG=C:\\DATA\\LOGS\\dnsd.log"],
        "SERVICES.CFG": ["DHCPD=true", "DNSD=true"],
    }
    files = []
    for name, lines in texts.items():
        path = os.path.join(rd, name)
        with open(path, "w", newline="") as f:
            f.write("\r\n".join(lines) + "\r\n")
        files.append((path, name))
    files += [(service_app(edition, "DHCPD"), "DHCPD.APP"), (service_app(edition, "DNSD"), "DNSD.APP")]
    setup = [f"COPY -y {LOG}:\\{n}.APP C:\\APPS\\{n}.APP" for n in ("DHCPD", "DNSD")]
    setup += [f"COPY -y {LOG}:\\{n}.CFG C:\\CONF\\{n}.CFG" for n in ("DHCPD", "DNSD", "SERVICES")]
    setup += [f"{t} chmod C:\\APPS\\DHCPD.APP C:\\APPS\\DNSD.APP"]
    r = Machine(edition, d, "router", 1, [("hub", hub, None), ("listen", wire, None)],
                [f"NET0=192.168.10.1/24 {m(1, 1)}", f"NET1={m(1, 2)} 192.168.20.1/24", "NAT=1",
                 "DNS=192.168.20.10", "FORWARD=tcp 8080 192.168.10.7:7000, udp 8081 192.168.10.7:7001"],
                ["192.168.10.1 router.lan", "192.168.10.7 a.lan"],
                [f"IPCONFIG > {out('IPC.TXT')}", f"{t} serve 25 {out('PEERS.TXT')}",
                 # While they run: A2's own address, a new name (DNSD -reload):
                 f"COPY -y {LOG}:\\DHCPD2.CFG C:\\CONF\\DHCPD.CFG",
                 "ECHO 192.168.10.99 new.lan >> C:\\CONF\\HOSTS.CFG", f"DNSD -reload > {out('RELOAD.TXT')}",
                 f"{t} serve 125 {out('PEERS.TXT')}",
                 f"NETSTAT > {out('NETSTAT.TXT')}", f"PS > {out('PS.TXT')}",
                 f"DNSD -stop > {out('STOP.TXT')}", f"DHCPD -stop >> {out('STOP.TXT')}", "CHOICE -c Y -t:Y,3 wait",
                 f"NETSTAT > {out('NETSTAT2.TXT')}", f"PS > {out('PS2.TXT')}",
                 f"COPY -y C:\\DATA\\LOGS\\dhcpd.log {out('DHCPD.LOG')}", f"COPY -y C:\\DATA\\LOGS\\dnsd.log {out('DNSD.LOG')}"],
                nattest, files, setup)
    b = Machine(edition, d, "b", 3, [("connect", wire, None)],
                ["NET0=192.168.20.10/24"], [],
                [f"{t} serve 60 {out('PEERS.TXT')} dns",
                 f"{t} client 192.168.20.1 4 8080 > {out('FWD.TXT')}",
                 f"{t} client 192.168.20.1 2 > {out('ROUTER.TXT')}"], nattest)
    a = Machine(edition, d, "a", 2, [("hub", hub, None)], ["NET0=DHCP"], [],
                ["CHOICE -c Y -t:Y,5 wait", f"IPCONFIG > {out('IPC.TXT')}",
                 f"PING -n 3 192.168.20.10 > {out('PING.TXT')}",
                 f"PING -n 2 192.168.10.1 > {out('PING-R.TXT')}",
                 f"NSLOOKUP router.lan > {out('NS-HOSTS.TXT')}",
                 f"NSLOOKUP far.test > {out('NS-FAR.TXT')}",
                 f"NSLOOKUP nowhere.test > {out('NS-NONE.TXT')}",
                 f"{t} dns 192.168.10.1 > {out('DNS.TXT')}",
                 f"{t} client 192.168.20.10 40 > {out('CLIENT.TXT')}",
                 f"IPCONFIG -RENEW > {out('RENEW.TXT')}", f"IPCONFIG > {out('IPC2.TXT')}",
                 f"{t} serve 110 {out('PEERS.TXT')}"], nattest)
    pools = []
    for name, number in (("a2", 4), ("a3", 5)):
        # A2 after R's changes: its new own address, the new name:
        later = ["CHOICE -c Y -t:Y,40 wait", f"IPCONFIG -RELEASE > {out('RENEW.TXT')}", f"IPCONFIG -RENEW >> {out('RENEW.TXT')}",
                 f"IPCONFIG > {out('IPC2.TXT')}", f"NSLOOKUP new.lan > {out('NS-NEW.TXT')}"] if name == "a2" else []
        pools.append(Machine(edition, d, name, number, [("hub", hub, None)], ["NET0=DHCP"], [],
                             ["CHOICE -c Y -t:Y,5 wait", f"IPCONFIG > {out('IPC.TXT')}",
                              f"PING -n 2 192.168.20.10 > {out('PING.TXT')}",
                              f"{t} client 192.168.20.10 10 > {out('CLIENT.TXT')}"] + later, nattest))
    machines = [r, b, a] + pools

    def field(text, name):
        for line in text.splitlines():
            if line.startswith(name):
                return line.split(":", 1)[1].strip()
        return ""

    def check(result):
        r.keep("IPC.TXT", "PEERS.TXT", "NETSTAT.TXT", "RELOAD.TXT", "PS.TXT", "STOP.TXT", "NETSTAT2.TXT", "PS2.TXT", "DHCPD.LOG", "DNSD.LOG")
        b.keep("PEERS.TXT", "FWD.TXT", "ROUTER.TXT")
        a.keep("IPC.TXT", "PING.TXT", "PING-R.TXT", "NS-HOSTS.TXT", "NS-FAR.TXT", "NS-NONE.TXT", "DNS.TXT", "CLIENT.TXT", "RENEW.TXT", "IPC2.TXT", "PEERS.TXT")
        for p in pools:
            p.keep("IPC.TXT", "PING.TXT", "CLIENT.TXT", "RENEW.TXT", "IPC2.TXT", "NS-NEW.TXT")
        rip = r.read("IPC.TXT")
        result("R: cards numbered from 0 (NET0, NET1)", "NET0\n" in rip.replace("\r", "") and "NET1\n" in rip.replace("\r", "") and "NET2" not in rip, rip[:200])
        ipc = a.read("IPC.TXT")
        result("DHCPD: A gets its own address 192.168.10.7 (the 256th fixed host)", field(ipc, "IPv4 address") == "192.168.10.7", ipc[-400:])
        result("DHCPD: A's mask, router, DNS server, lease", field(ipc, "Subnet mask") == "255.255.255.0" and
               field(ipc, "Default gateway") == "192.168.10.1" and field(ipc, "DNS servers") == "192.168.10.1" and
               "from 192.168.10.1, lease 300 s" in ipc, ipc[-400:])
        ipc2 = a.read("IPC2.TXT")
        result("DHCPD: A renews (IPCONFIG -RENEW): the same address", field(ipc2, "IPv4 address") == "192.168.10.7" and
               "lease 300 s" in ipc2, a.read("RENEW.TXT")[-200:] + ipc2[-300:])
        got = []
        for p in pools:
            ip = field(p.read("IPC.TXT"), "IPv4 address")
            got.append(ip)
            parts = ip.split(".")
            result(f"DHCPD: {p.name} gets an address of the range", len(parts) == 4 and ip.startswith("192.168.10.") and
                   100 <= int(parts[3]) <= 200, p.read("IPC.TXT")[-300:])
        result("DHCPD: A2 and A3 get different addresses", got[0] != got[1] and all(got), str(got))
        ping = a.read("PING.TXT")
        result("NAT: A pings B (TTL 254: through R)", "Reply from 192.168.20.10" in ping and "TTL=254" in ping, ping[-200:])
        pr = a.read("PING-R.TXT")
        result("A pings R itself", "Reply from 192.168.10.1" in pr, pr[-160:])
        ns = a.read("NS-HOSTS.TXT")
        result("DNSD: A resolves R's HOSTS.CFG name", "Address:  192.168.10.1" in ns, ns[-200:])
        ns = a.read("NS-FAR.TXT")
        result("DNSD: A resolves far.test (R asks B upstream)", "Address:  192.168.20.10" in ns, ns[-200:])
        ns = a.read("NS-NONE.TXT")
        result("DNSD: an unknown name fails (B's SERVFAIL relayed)", "Address:" not in ns, ns[-200:])
        # The cache: NATTEST dns's lines on A, and what B was asked:
        dns = [line for line in a.read("DNS.TXT").replace("\r", "").splitlines() if ": " in line]
        asked = {}
        for line in b.read("PEERS.TXT").replace("\r", "").splitlines():
            if line.startswith("DNS "):
                asked[line[4:]] = asked.get(line[4:], 0) + 1

        def q(i):
            return dns[i] if i < len(dns) else ""

        def ttl(i):
            f = q(i).split(" ttl ")
            return int(f[1].split(",")[0]) if len(f) == 2 else -1

        result("DNSD cache: 13 answers, each with the client's id and question",
               len(dns) == 13 and all("id ok, question ok" in x for x in dns), " / ".join(dns))
        result("DNSD cache: far.test asked upstream once (NSLOOKUP, then FAR.Test and far.test from the cache)",
               asked.get("far.test 1") == 1 and "192.168.20.10 ttl" in q(1) and 290 <= ttl(1) <= 300, str(asked) + " " + q(1))
        result("DNSD cache: TTLs counted down (far.test after 4 s: 300 less the seconds)",
               "192.168.20.10" in q(12) and ttl(12) <= 296 and ttl(12) >= 250, q(12))
        result("DNSD cache: no data (AAAA) kept apart, asked once", asked.get("far.test 28") == 1 and
               "rcode 0, 0 answers" in q(3), str(asked) + " " + q(3))
        result("DNSD cache: short.test (TTL 2) kept, then asked again when it ran out",
               asked.get("short.test 1") == 2 and "192.168.20.11" in q(5) and "192.168.20.11" in q(10), str(asked))
        result("DNSD cache: NXDOMAIN kept for its SOA minimum (3 s), then asked again",
               asked.get("nx.test 1") == 2 and "rcode 3" in q(7) and "rcode 3" in q(11), str(asked) + " " + q(7))
        result("DNSD cache: SERVFAIL not kept", asked.get("fail.test 1") == 2 and "rcode 2" in q(9), str(asked) + " " + q(9))
        ms = [float(x.rsplit(", ", 1)[1].split()[0]) for x in dns if x.endswith(" ms")]
        result(f"DNSD cache: answer times (ms) {', '.join('%.0f' % m for m in ms)}", len(ms) == 13, "")
        cl = a.read("CLIENT.TXT")
        result("NAT: A's 40 TCP connections to B (32 KiB each), B sees R's address", "TCP 40 of 40, seen as 192.168.20.1\n" in cl.replace("\r", ""), cl[-200:])
        result("NAT: A's UDP to B and back, B sees R's address", "UDP 10 of 10, seen as 192.168.20.1\n" in cl.replace("\r", ""), cl[-200:])
        for p in pools:
            cl = p.read("CLIENT.TXT").replace("\r", "")
            result(f"NAT: {p.name}'s TCP and UDP to B", "TCP 10 of 10, seen as 192.168.20.1\n" in cl and "UDP 10 of 10, seen as 192.168.20.1\n" in cl, cl[-200:])
            pp = p.read("PING.TXT")
            result(f"NAT: {p.name} pings B", "Reply from 192.168.20.10" in pp, pp[-160:])
        peers = b.read("PEERS.TXT")
        result("NAT: B saw only R's address (no 192.168.10.x)", "192.168.20.1:" in peers and "192.168.10." not in peers, peers[:300])
        fwd = b.read("FWD.TXT").replace("\r", "")
        result("FORWARD=: B reaches A's server through R:8080 (TCP) and R:8081 (UDP), A sees B",
               "TCP 4 of 4, seen as 192.168.20.10\n" in fwd and "UDP 10 of 10, seen as 192.168.20.10\n" in fwd, fwd[-200:])
        result("FORWARD=: A's server saw B's own address", "TCP 192.168.20.10:" in a.read("PEERS.TXT"), a.read("PEERS.TXT")[:200])
        own = b.read("ROUTER.TXT").replace("\r", "")
        result("R's own server (TCP, UDP 7000/7001) on its outside address still answers", "TCP 2 of 2, seen as 192.168.20.10\n" in own and "UDP 10 of 10" in own, own[-200:])
        # The services: their files, rereading, stopping:
        dlog = r.read("DHCPD.LOG").replace("\r", "")
        result("DHCPD.CFG: 256 fixed hosts read, the 257th refused", "1 range(s), 256 fixed host(s)" in dlog and
               "more than 256 fixed hosts" in dlog, dlog[:300])
        result("DHCPD: DHCPD.CFG reread when it changed (twice read)", dlog.count("DHCPD.CFG: 1 range(s), 256 fixed host(s)") >= 2, dlog[-300:])
        ipc2 = pools[0].read("IPC2.TXT")
        result("DHCPD: A2 gets its new own address 192.168.10.50 (RELEASE, RENEW)", field(ipc2, "IPv4 address") == "192.168.10.50" and
               field(ipc2, "DNS servers") == "192.168.10.1", pools[0].read("RENEW.TXT")[-200:] + ipc2[-300:])
        ns = pools[0].read("NS-NEW.TXT")
        result("DNSD: HOSTS.CFG reread (DNSD -reload): A2 resolves new.lan", "Address:  192.168.10.99" in ns,
               r.read("RELOAD.TXT")[-100:] + ns[-200:])
        nst = r.read("NETSTAT.TXT")
        result("R: DHCPD and DNSD listen (UDP 67, 53)", ":67 " in nst and ":53 " in nst, nst[-400:])
        nst2, ps2 = r.read("NETSTAT2.TXT"), r.read("PS2.TXT")
        result("DHCPD -stop, DNSD -stop: both ended, their ports closed", "DHCPD" in r.read("PS.TXT") and "DNSD" in r.read("PS.TXT") and
               "DHCPD" not in ps2 and "DNSD" not in ps2 and ":67 " not in nst2 and ":53 " not in nst2 and
               "stopped" in dlog and "stopped" in r.read("DNSD.LOG"), r.read("STOP.TXT")[-100:] + ps2[-300:] + nst2[-300:])

    return machines, check


def run(edition, port):
    d = os.path.join(OUT, edition, "nat")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    nattest = app(edition)
    machines, check = nat_case(edition, d, port, nattest)
    results = []

    def result(name, ok, detail=""):
        results.append((name, ok, "" if ok else detail.replace("\n", " | ")))

    began = time.time()
    boot = rt.EDITIONS[edition][2]
    try:
        for m in machines:
            m.start()
            time.sleep(1)
        time.sleep(boot)
        rt.parallel([m.configure for m in machines])
        time.sleep(boot + 5)
        rt.parallel([lambda m=m: m.type(f"{LOG}:\\RUN.BAT", 1) for m in machines])
        deadline = time.time() + 300
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
        rt.parallel([m.stop for m in machines])
    check(result)
    seconds = time.time() - began
    passed = sum(1 for r in results if r[1])
    with open(os.path.join(d, "results.md"), "w") as f:
        f.write(f"# NAT tests: {edition}\n\n{passed} of {len(results)} passed, {seconds:.0f} s\n\n")
        for name, ok, detail in results:
            f.write(f"- {'PASS' if ok else 'FAIL'} {name}{' (' + detail + ')' if detail else ''}\n")
    print(f"{edition} nat: {passed} of {len(results)} passed ({seconds:.0f} s)")
    for name, ok, detail in results:
        if not ok:
            print(f"  FAIL {name}{' (' + detail + ')' if detail else ''}")
    return passed == len(results)


def main():
    args = sys.argv[1:]
    edition = args[0] if args else common.NAME
    if edition not in CPU:
        raise SystemExit(f"unknown edition {edition}: {', '.join(CPU)}")
    common.require(os.path.join(common.BUILD, rt.EDITIONS[edition][0], "system.img"), hint="build it first: zig build")
    os.makedirs(OUT, exist_ok=True)
    sys.exit(0 if run(edition, BASE_PORT) else 1)


if __name__ == "__main__":
    main()
