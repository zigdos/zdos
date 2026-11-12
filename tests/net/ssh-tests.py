#!/usr/bin/env python3
# SSH in QEMU: OpenSSH against SSHD, and ZDOS's SSH and SCP
# against an sshd here (10.0.2.2:2222). Host 12222 -> guest 22.
#   ssh-tests.py [EDITION...]   as net-tests.py; default from
#   ZDOS_EDITION / ZDOS_ARCH, metal x86_64:
#   ZDOS_EDITION=uefi ZDOS_ARCH=x86_64 python3 tests/net/ssh-tests.py
# Needs also OpenSSH (ssh, scp, ssh-keygen, /usr/sbin/sshd).
import importlib.util
import os
import shutil
import socket
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

OUT = os.path.join(common.BUILD, "ssh-tests")
BIG = nt.BIG
PASSWORD = "zdos-pass"
GUEST_PORT = 12222
HOST_SSHD_PORT = 2222


def keygen(path):
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", os.path.basename(path), "-f", path], check=True)
    return path


def mput(img, src, name):
    subprocess.run(["mcopy", "-o", "-i", img, src, "::/" + name], check=True, capture_output=True)


# FILES: THE LOG DISK'S SETUP, THE HOST'S SSHD

def prepare(d, img):
    keys = os.path.join(d, "keys")
    os.makedirs(keys)
    host_client = keygen(os.path.join(keys, "host-client"))  # logs in to ZDOS
    stranger = keygen(os.path.join(keys, "stranger"))  # a key ZDOS doesn't know
    zdos_client = keygen(os.path.join(keys, "zdos-client"))  # ZDOS's SSH to the host
    sshd_key = keygen(os.path.join(keys, "sshd-host"))

    remote = os.path.join(d, "remote")
    os.makedirs(os.path.join(remote, "tree", "subdir"))
    with open(os.path.join(remote, "down.bin"), "wb") as f:
        f.write(BIG)
    with open(os.path.join(remote, "tree", "a.txt"), "w") as f:
        f.write("tree-a\n")
    with open(os.path.join(remote, "tree", "subdir", "b.txt"), "w") as f:
        f.write("tree-b\n")
    upload = os.path.join(d, "upload", "subdir")
    os.makedirs(upload)
    with open(os.path.join(d, "upload", "one.txt"), "w") as f:
        f.write("upload-one\n")
    with open(os.path.join(upload, "two.txt"), "w") as f:
        f.write("upload-two\n")

    setup = os.path.join(d, "setup")
    os.makedirs(setup)
    files = {
        "SERVICES.CFG": "# ZDOS services: NAME=true starts it at boot\r\nSSHD=true\r\n",
        "SSHD.CFG": "PORT=22\r\nPASSWORDS=true\r\nLOG=C:\\DATA\\LOGS\\sshd.log\r\n",
        "AUTHKEYS.TXT": open(host_client + ".pub").read(),
        "CLIENT.KEY": open(zdos_client).read(),
        "KNOWN.TXT": f"[10.0.2.2]:{HOST_SSHD_PORT} " + " ".join(open(sshd_key + ".pub").read().split()[:2]) + "\n",
        "PASSWORD.TXT": PASSWORD + "\n",
        "HOST.TXT": f"user={os.environ.get('USER') or os.getlogin()}\ndir={remote}\n",
    }
    subprocess.run(["mmd", "-i", img, "::/SETUP"], check=True, capture_output=True)
    for name, text in files.items():
        path = os.path.join(setup, name)
        with open(path, "w", newline="") as f:
            f.write(text)
        mput(img, path, "SETUP/" + name)

    with open(os.path.join(d, "authorized_keys"), "w") as f:
        f.write(open(zdos_client + ".pub").read())
    config = os.path.join(d, "sshd_config")
    with open(config, "w") as f:
        f.write(f"""Port {HOST_SSHD_PORT}
ListenAddress 127.0.0.1
HostKey {sshd_key}
AuthorizedKeysFile {os.path.join(d, 'authorized_keys')}
PidFile {os.path.join(d, 'sshd.pid')}
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PubkeyAuthentication yes
""")
    askpass = os.path.join(keys, "askpass.sh")
    with open(askpass, "w") as f:
        f.write(f"#!/bin/sh\necho {PASSWORD}\n")
    os.chmod(askpass, 0o755)
    return {"host_client": host_client, "stranger": stranger, "config": config, "askpass": askpass,
            "known": os.path.join(keys, "known_hosts"), "remote": remote, "upload": os.path.join(d, "upload")}


def start_sshd(d, files):
    log = open(os.path.join(d, "host-sshd.log"), "w")
    proc = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", files["config"]], stdout=log, stderr=log)
    time.sleep(1)
    if proc.poll() is not None:
        raise SystemExit("the host's sshd didn't start: see " + log.name)
    return proc


def sshd_answers():
    # ZDOS's SSHD is up: its version line comes:
    try:
        with socket.create_connection(("127.0.0.1", GUEST_PORT), timeout=3) as s:
            return s.recv(64).startswith(b"SSH-2.0-ZDOS")
    except OSError:
        return False


# OPENSSH AGAINST ZDOS'S SSHD

class HostTests:
    def __init__(self, d, files):
        self.d = d
        self.f = files
        self.results = []
        self.done = False

    def result(self, name, ok, detail=""):
        self.results.append((name, ok, detail))

    def opts(self, key):
        return ["-o", f"UserKnownHostsFile={self.f['known']}", "-o", "StrictHostKeyChecking=accept-new",
                "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=20", "-i", key]

    def ssh(self, command, key=None, extra=(), stdin=None, env=None, timeout=120):
        args = (["ssh", "-p", str(GUEST_PORT)] + self.opts(key or self.f["host_client"]) + list(extra)
                + ["root@127.0.0.1"] + ([command] if command is not None else []))
        try:
            r = subprocess.run(args, input=stdin, capture_output=True, timeout=timeout, env=env)
            return r.returncode, r.stdout.decode(errors="replace"), r.stderr.decode(errors="replace")
        except subprocess.TimeoutExpired:
            return -1, "", "timeout"

    def scp(self, *paths, recursive=False, legacy=True):
        # legacy: the SCP protocol (-O); else OpenSSH's default, SFTP:
        args = (["scp"] + (["-O"] if legacy else []) + ["-P", str(GUEST_PORT)] + self.opts(self.f["host_client"])
                + (["-r"] if recursive else []) + list(paths))
        try:
            r = subprocess.run(args, capture_output=True, timeout=300)
            return r.returncode, r.stderr.decode(errors="replace")
        except subprocess.TimeoutExpired:
            return -1, "timeout"

    def __call__(self):
        # Run once, from run_qemu's "until":
        if self.done:
            return True
        self.done = True
        batch = ["-o", "BatchMode=yes"]
        rc, out, err = self.ssh("ECHO server-ok", extra=batch)
        self.result("ssh: a command", rc == 0 and "server-ok" in out, f"rc {rc} {err.strip()[:120]}")
        rc, out, err = self.ssh("ECHO second-ok", extra=["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes"])
        self.result("ssh: the host key is the same the second time", rc == 0 and "second-ok" in out, f"rc {rc} {err.strip()[:120]}")
        # A program's exit code (SCP without arguments: code 1); COMMAND's
        # TYPE sets none, as on DOS:
        rc, out, err = self.ssh("SCP", extra=batch)
        self.result("ssh: a program's exit code comes back", rc == 1, f"rc {rc}")
        rc, out, err = self.ssh("ECHO stranger", key=self.f["stranger"], extra=batch)
        self.result("ssh: an unknown key is refused", rc == 255 and "stranger" not in out, f"rc {rc}")
        env = dict(os.environ, SSH_ASKPASS=self.f["askpass"], SSH_ASKPASS_REQUIRE="force", DISPLAY=":0")
        rc, out, err = self.ssh("ECHO pw-ok", extra=["-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
                                                     "-o", "NumberOfPasswordPrompts=1"], env=env)
        self.result("ssh: password login", rc == 0 and "pw-ok" in out, f"rc {rc} {err.strip()[:120]}")
        rc, out, err = self.ssh("MORE", extra=batch, stdin=b"line-one\nline-two\n")
        self.result("ssh: input to a command", rc == 0 and "line-two" in out, f"rc {rc} {out[:80]!r}")
        rc, out, err = self.ssh("PS", extra=batch)
        self.result("ssh: PS shows SSHD running beside the shell", rc == 0 and "SSHD" in out.upper(), out[:200])

        # A pseudo-terminal: the remote console:
        rc, out, err = self.ssh(None, extra=["-tt", "-o", "BatchMode=yes"], stdin=b"ECHO pty-ok\rEXIT\r", timeout=60)
        self.result("ssh -tt: the shell on a remote console", "pty-ok" in out, f"rc {rc} {out[-200:]!r}")

        # Two at once:
        outs = [None, None]

        def one(i):
            outs[i] = self.ssh("PING -n 3 10.0.2.2", extra=batch)
        threads = [threading.Thread(target=one, args=(i,)) for i in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.result("ssh: two sessions at once", all(o and o[0] == 0 for o in outs), str([o[0] if o else None for o in outs]))

        # scp -O (the SCP protocol) both ways:
        big = os.path.join(self.d, "big.bin")
        with open(big, "wb") as f:
            f.write(BIG)
        rc, err = self.scp(big, "root@127.0.0.1:big.bin")
        self.result("scp -O upload (300 KB)", rc == 0, err.strip()[:120])
        back = os.path.join(self.d, "big-back.bin")
        rc, err = self.scp("root@127.0.0.1:big.bin", back)
        got = open(back, "rb").read() if os.path.exists(back) else b""
        self.result("scp -O download matches", rc == 0 and got == BIG, f"rc {rc}, {len(got)} bytes {err.strip()[:80]}")
        rc, err = self.scp(self.f["upload"], "root@127.0.0.1:up-tree", recursive=True)
        self.result("scp -O -r upload", rc == 0, err.strip()[:120])
        tree_back = os.path.join(self.d, "tree-back")
        rc, err = self.scp("root@127.0.0.1:up-tree", tree_back, recursive=True)
        two = os.path.join(tree_back, "subdir", "two.txt")
        self.result("scp -O -r download", rc == 0 and os.path.exists(two) and "upload-two" in open(two).read(), err.strip()[:120])

        # SFTP: plain scp (SFTP since OpenSSH 9), and sftp's own commands:
        rc, err = self.scp(big, "root@127.0.0.1:sftp-big.bin", legacy=False)
        self.result("scp over SFTP: upload", rc == 0, err.strip()[:120])
        back2 = os.path.join(self.d, "sftp-back.bin")
        rc, err = self.scp("root@127.0.0.1:sftp-big.bin", back2, legacy=False)
        got = open(back2, "rb").read() if os.path.exists(back2) else b""
        self.result("scp over SFTP: download matches", rc == 0 and got == BIG, f"rc {rc}, {len(got)} bytes {err.strip()[:80]}")
        got_back = os.path.join(self.d, "sftp-got.bin")
        script = os.path.join(self.d, "sftp-batch.txt")
        with open(script, "w") as f:
            f.write(f"mkdir sftpdir\nput {big} sftpdir/f.bin\nls -l sftpdir\nrename sftpdir/f.bin sftpdir/g.bin\n"
                    f"get sftpdir/g.bin {got_back}\nrm sftpdir/g.bin\nrmdir sftpdir\nls /\n")
        args = ["sftp", "-P", str(GUEST_PORT)] + self.opts(self.f["host_client"]) + ["-b", script, "root@127.0.0.1"]
        try:
            r = subprocess.run(args, capture_output=True, timeout=300)
            out = r.stdout.decode(errors="replace")
            rc = r.returncode
        except subprocess.TimeoutExpired:
            rc, out = -1, "timeout"
        got = open(got_back, "rb").read() if os.path.exists(got_back) else b""
        self.result("sftp: mkdir, put, ls, rename, get, rm, rmdir", rc == 0 and got == BIG and "f.bin" in out, f"rc {rc} {out[-200:]!r}")
        self.result("sftp: / lists the drives", "C:" in out, out[-120:])

        rc, out, err = self.ssh("TYPE C:\\DATA\\LOGS\\sshd.log", extra=batch)
        with open(os.path.join(self.d, "SSHD.LOG"), "w") as f:
            f.write(out)
        self.result("SSHD.LOG records logins", "logged in" in out, out[-200:])
        return True


# ONE EDITION

def run_edition(edition):
    d = os.path.join(OUT, edition)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    img = os.path.join(d, "netlog.img")
    subprocess.run(["mkfs.fat", "-F", "16", "-n", "NETLOG", "-C", img, str(16 * 1024)], check=True, capture_output=True)
    files = prepare(d, img)
    sshd = start_sshd(d, files)
    sock = os.path.join(d, "monitor.sock")
    host = HostTests(d, files)
    began = time.time()

    def has(name, marker):
        def done():
            data = nt.mread(img, name)
            return data is not None and marker in data
        return done

    boot = 60 if nt.EDITIONS[edition][2] else 35
    user = os.environ.get("USER") or os.getlogin()
    steps = (common.command("SSHTEST SETUP", 8)
             + [("until", has("SETUP.LOG", b"# SETUP done"), 120)]
             + common.command("REBOOT", 5)
             + [("wait", boot), ("until", sshd_answers, 120), ("shot", "boot", "SSHD started by SERVICES.CFG"),
                ("until", host, 900)]
             + common.command("SSHTEST CLIENT", 5)
             + [("until", has("SSHTEST.LOG", b"# SSHTEST:"), 900), ("wait", 2)]
             + common.command(f"SSH -p {HOST_SSHD_PORT} {user}@10.0.2.2", 10)
             + common.command(f"echo vt-ok > {files['remote']}/vt.txt", 3)
             + [("shot", "ssh-session", "ZDOS's SSH: a shell on the host")]
             + common.command("exit", 5)
             + [("shot", "end", "the screen after the tests")]
             + common.command("SHUTDOWN", 15))
    try:
        common.run_qemu(nt.qemu(edition, d, sock, forwards=f",hostfwd=tcp:127.0.0.1:{GUEST_PORT}-:22"), steps, d, sock, boot_wait=boot)
    except BrokenPipeError:
        pass  # SHUTDOWN ended QEMU before its monitor was told to quit
    finally:
        sshd.terminate()
        sshd.wait()
    return check(edition, d, img, files, host, time.time() - began)


def check(edition, d, img, files, host, seconds):
    results = list(host.results)
    if not host.done:
        results.append(("SSHD answered after the reboot (host tests ran)", False, ""))

    def result(name, ok, detail=""):
        results.append((name, ok, detail))

    log = (nt.mread(img, "SSHTEST.LOG") or b"").decode(errors="replace")
    with open(os.path.join(d, "SSHTEST.LOG"), "w") as f:
        f.write(log)
    result("SSHTEST CLIENT finished", "# SSHTEST:" in log)
    for line in log.splitlines():
        if line.startswith("ok - ") or line.startswith("not ok - "):
            result("ZDOS " + line.split(" - ", 1)[1], line.startswith("ok"))
    remote = files["remote"]
    up = os.path.join(remote, "up.bin")
    got = open(up, "rb").read() if os.path.exists(up) else b""
    result("ZDOS SCP upload arrived intact", got == BIG, f"{len(got)} bytes")
    b2 = os.path.join(remote, "tree2", "subdir", "b.txt")
    result("ZDOS SCP -r upload arrived", os.path.exists(b2) and "tree-b" in open(b2).read())
    vt = os.path.join(remote, "vt.txt")
    result("ZDOS SSH: a command typed in the interactive session ran", os.path.exists(vt) and "vt-ok" in open(vt).read())

    passed = sum(1 for r in results if r[1])
    with open(os.path.join(d, "results.md"), "w") as f:
        f.write(f"# SSH tests: {edition}\n\n{passed} of {len(results)} passed, {seconds:.0f} s\n\n")
        for name, ok, detail in results:
            f.write(f"- {'PASS' if ok else 'FAIL'} {name}{' (' + detail + ')' if detail and not ok else ''}\n")
        f.write("\nScreenshots: boot.png, ssh-session.png, end.png; the host's sshd: host-sshd.log\n")
    print(f"{edition}: {passed} of {len(results)} passed ({seconds:.0f} s)")
    for name, ok, detail in results:
        if not ok:
            print(f"  FAIL {name}{' (' + detail + ')' if detail else ''}")
    return passed == len(results)


def main():
    editions = sys.argv[1:] or [common.NAME]
    for e in editions:
        if e not in nt.EDITIONS:
            raise SystemExit(f"unknown edition {e}: {', '.join(nt.EDITIONS)}")
        common.require(os.path.join(common.BUILD, nt.EDITIONS[e][0], "system.img"), hint="build it first: zig build")
    for tool in ("ssh", "scp", "ssh-keygen", "/usr/sbin/sshd"):
        if not shutil.which(tool):
            raise SystemExit(f"{tool} not found (OpenSSH)")
    ok = True
    for e in editions:
        ok = run_edition(e) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
