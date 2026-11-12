#!/usr/bin/env python3
# HTTPZ in QEMU as a service, tested from here over HTTP and HTTPS
# (host 18081 -> guest 80, 18444 -> 443).
#   httpz-tests.py [EDITION...]   as net-tests.py; default from
#   ZDOS_EDITION / ZDOS_ARCH, metal x86_64:
#   ZDOS_EDITION=uefi ZDOS_ARCH=x86_64 python3 tests/net/httpz-tests.py
# Needs also curl and openssl. Env: HTTPZ_TEST_OUT, HTTPZ_TEST_IMAGE,
# HTTPZ_TEST_PORTS=http,https,nettest, HTTPZ_TEST_SMP,
# HTTPZ_TEST_WORKERS.
import hashlib
import http.client
import importlib.util
import os
import re
import shutil
import socket
import ssl
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

ENV = os.environ.get
OUT = ENV("HTTPZ_TEST_OUT") or os.path.join(common.BUILD, "httpz-tests")
HTTP_PORT, HTTPS_PORT, NETTEST_PORT = (int(p) for p in (ENV("HTTPZ_TEST_PORTS") or "18081,18444,18080").split(","))
BIG = bytes((i * 131 + i // 997) & 0xFF for i in range(3_000_000))
MEDIUM = bytes((i * 7 + i // 251) & 0xFF for i in range(200_000))
TOO_BIG = 9 * 1024 * 1024  # over the test's MAX_FILE_SIZE=8MB
INDEX = b"<!DOCTYPE html><html><body><h1>HTTPZ test page</h1></body></html>\n"

CONFIG = """PORT=80
HTTPS_PORT=443
HTTPS_REDIRECT=false
MAX_FILE_SIZE=8MB
MAX_BODY=64KB
MAX_CLIENTS=64
DIRLIST=true
CGI_DIR=functions
CGI lua=C:/APPS/lua.app
CGI py=C:/APPS/micropython.app
CGI_TIMEOUT=3
LOG=C:/DATA/LOGS/httpz.log
"""
if ENV("HTTPZ_TEST_WORKERS"):
    CONFIG += f"WORKERS={ENV('HTTPZ_TEST_WORKERS')}\n"

LUA_HELLO = """print("Content-Type: text/plain")
print("")
print("lua-hello " .. (os.getenv("QUERY_STRING") or "") .. " path=" .. (os.getenv("PATH_INFO") or ""))
"""
LUA_ECHO = """local body = io.read("a") or ""
print("Content-Type: text/plain")
print("")
print("method=" .. os.getenv("REQUEST_METHOD") .. " length=" .. #body .. " body=" .. body)
"""
LUA_STATUS = """print("Status: 418 I'm a teapot")
print("Content-Type: text/plain")
print("")
print("teapot")
"""
LUA_MOVE = """print("Location: /index.html")
print("")
"""
LUA_LOOP = "while true do end\n"
PY_HELLO = """print("Content-Type: text/plain")
print("")
print("py-hello")
"""


def www_files():
    files = {
        "index.html": INDEX,
        "big-download.bin": BIG,
        "medium-file.bin": MEDIUM,
        "too-big-file.bin": b"\0" * TOO_BIG,
        "test-picture.png": b"\x89PNG\r\n\x1a\nnot really",
        "test-picture.jpg": b"\xff\xd8\xff not really",
        "plain-notes.txt": b"notes\n",
        "test-archive.zip": b"PK\x03\x04",
        "test-program.app": b"ZAP6 not really",
        "file-without-ext": b"???",
        "subfolder/index.html": b"<p>subfolder index</p>\n",
        "listed-folder/first-file.txt": b"1\n",
        "listed-folder/second-file.txt": b"2\n",
        "functions/hello-world.lua": LUA_HELLO.encode(),
        "functions/echo-body.lua": LUA_ECHO.encode(),
        "functions/teapot-status.lua": LUA_STATUS.encode(),
        "functions/moved-away.lua": LUA_MOVE.encode(),
        "functions/endless-loop.lua": LUA_LOOP.encode(),
        "functions/python-hello.py": PY_HELLO.encode(),
        "functions/static-style.css": b"body{}\n",
    }
    return files


def prepare(d, img):
    setup = os.path.join(d, "setup")
    conf = {
        "SERVICES.CFG": "# ZDOS services\r\nHTTPZ=true\r\n",
        "HTTPZ.CFG": CONFIG.replace("\n", "\r\n"),
    }
    for folder in ("SETUP", "SETUP/CONF", "SETUP/WWW"):
        subprocess.run(["mmd", "-i", img, "::/" + folder], check=True, capture_output=True)
    for name, text in conf.items():
        path = os.path.join(setup, "conf", name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", newline="") as f:
            f.write(text)
        subprocess.run(["mcopy", "-o", "-i", img, path, "::/SETUP/CONF/" + name], check=True, capture_output=True)
    made = set()
    for name, data in www_files().items():
        path = os.path.join(setup, "www", name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        folder = os.path.dirname(name)
        if folder and folder not in made:
            subprocess.run(["mmd", "-i", img, "::/SETUP/WWW/" + folder], check=True, capture_output=True)
            made.add(folder)
        subprocess.run(["mcopy", "-o", "-i", img, path, "::/SETUP/WWW/" + name], check=True, capture_output=True)


def answers():
    try:
        with socket.create_connection(("127.0.0.1", HTTP_PORT), timeout=3) as s:
            s.sendall(b"HEAD / HTTP/1.1\r\nHost: t\r\n\r\n")
            return s.recv(16).startswith(b"HTTP/1.1")
    except OSError:
        return False


class HostTests:
    def __init__(self, d, edition):
        self.d = d
        self.edition = edition
        self.results = []
        self.done = False

    def result(self, name, ok, detail=""):
        self.results.append((name, ok, detail))

    def conn(self, secure):
        if secure:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            return http.client.HTTPSConnection("127.0.0.1", HTTPS_PORT, timeout=180, context=ctx)
        return http.client.HTTPConnection("127.0.0.1", HTTP_PORT, timeout=180)

    def get(self, path, secure=False, method="GET", headers=None, body=None):
        c = self.conn(secure)
        try:
            c.request(method, path, body=body, headers=headers or {})
            r = c.getresponse()
            return r.status, dict((k.lower(), v) for k, v in r.getheaders()), r.read()
        except Exception as e:  # noqa: BLE001
            return -1, {}, str(e).encode()
        finally:
            c.close()

    def raw(self, data, secure=False, read_all=True):
        s = socket.create_connection(("127.0.0.1", HTTPS_PORT if secure else HTTP_PORT), timeout=20)
        try:
            s.sendall(data)
            out = b""
            while read_all:
                b = s.recv(65536)
                if not b:
                    break
                out += b
            return out
        except OSError as e:
            return str(e).encode()
        finally:
            s.close()

    def files(self, secure):
        p = "HTTPS " if secure else "HTTP "
        st, h, b = self.get("/", secure)
        self.result(p + "GET / gives index.html", st == 200 and b == INDEX and h.get("content-type", "").startswith("text/html"), f"{st}")
        st, h, b = self.get("/", secure, method="HEAD")
        self.result(p + "HEAD: headers, no body", st == 200 and b == b"" and h.get("content-length") == str(len(INDEX)), f"{st} {h.get('content-length')}")
        t0 = time.time()
        st, h, b = self.get("/big-download.bin", secure)
        secs = time.time() - t0
        self.result(p + f"a 3 MB file arrives intact ({len(BIG) / 1e6 / max(secs, 0.001):.1f} MB/s)", st == 200 and b == BIG, f"{st} {len(b)}")
        self.result(p + "an unknown type is a download", h.get("content-type") == "application/octet-stream", h.get("content-type", ""))
        st, h, b = self.get("/big-download.bin", secure, headers={"Range": "bytes=1000-1999"})
        self.result(p + "Range a-b: 206 and those bytes", st == 206 and b == BIG[1000:2000] and h.get("content-range") == f"bytes 1000-1999/{len(BIG)}", f"{st} {h.get('content-range')}")
        st, h, b = self.get("/big-download.bin", secure, headers={"Range": "bytes=-100"})
        self.result(p + "Range -n: the last n bytes", st == 206 and b == BIG[-100:], f"{st} {len(b)}")
        st, h, b = self.get("/big-download.bin", secure, headers={"Range": f"bytes={len(BIG) + 5}-"})
        self.result(p + "Range past the end: 416", st == 416, f"{st}")
        st, h, _ = self.get("/plain-notes.txt", secure)
        lm = h.get("last-modified", "")
        st2, _, b2 = self.get("/plain-notes.txt", secure, headers={"If-Modified-Since": lm})
        self.result(p + "If-Modified-Since its Last-Modified: 304", st == 200 and lm and st2 == 304 and b2 == b"", f"{st2} {lm!r}")

    def parallel(self, jobs, clients):
        # jobs: (path, secure, headers, wanted body); client threads take them:
        outs = ["not run"] * len(jobs)
        nexts = iter(range(len(jobs)))
        lock = threading.Lock()

        def client():
            while True:
                with lock:
                    i = next(nexts, None)
                if i is None:
                    return
                path, secure, headers, want = jobs[i]
                st, _, b = self.get(path, secure, headers=headers)
                outs[i] = None if st in (200, 206) and b == want else f"{'s' if secure else ''}{st}:{len(b)}:{b[:60]!r}"
        threads = [threading.Thread(target=client) for _ in range(clients)]
        t0 = time.time()
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.failed = [o for o in outs if o]
        return sum(1 for o in outs if not o), time.time() - t0

    def concurrency(self):
        # 32 at once, half HTTPS, each byte-exact (the network keeps 48
        # connections in all):
        jobs = []
        for i in range(32):
            secure = i % 2 == 1
            if i % 3 == 0:
                jobs.append(("/medium-file.bin", secure, {}, MEDIUM))
            elif i % 3 == 1:
                a = i * 1000
                jobs.append(("/big-download.bin", secure, {"Range": f"bytes={a}-{a + 65535}"}, BIG[a:a + 65536]))
            else:
                jobs.append(("/plain-notes.txt", secure, {}, b"notes\n"))
        good, secs = self.parallel(jobs, 32)
        self.result(f"32 requests at once (half HTTPS), all byte-exact ({secs:.1f} s)", good == 32, f"{good} of 32 {self.failed[:4]}")

        # Load, for comparing WORKERS=: new connections from 16 clients:
        good, secs = self.parallel([("/plain-notes.txt", True, {}, b"notes\n")] * 64, 16)
        self.result(f"load: 64 HTTPS connections, 16 clients ({secs:.2f} s, {64 / secs:.1f}/s)", good == 64, f"{good} of 64 {self.failed[:4]}")
        good, secs = self.parallel([("/medium-file.bin", False, {}, MEDIUM)] * 64, 16)
        self.result(f"load: 64 HTTP downloads of 200 KB, 16 clients ({secs:.2f} s, {64 * len(MEDIUM) / 1e6 / secs:.1f} MB/s)", good == 64, f"{good} of 64 {self.failed[:4]}")
        good, secs = self.parallel([("/medium-file.bin", True, {}, MEDIUM)] * 64, 16)
        self.result(f"load: 64 HTTPS downloads of 200 KB, 16 clients ({secs:.2f} s, {64 * len(MEDIUM) / 1e6 / secs:.1f} MB/s)", good == 64, f"{good} of 64 {self.failed[:4]}")

        # Idle and slow clients hold no worker (WORKERS= is 16 at most): 20
        # idle connections, one sending its request in pieces, one idle after
        # its TLS handshake. First the load's connections end:
        time.sleep(5)
        held = []
        try:
            for _ in range(20):
                held.append(socket.create_connection(("127.0.0.1", HTTP_PORT), timeout=30))
                time.sleep(0.05)  # ZDOS queues 16 not yet accepted
            slow = socket.create_connection(("127.0.0.1", HTTP_PORT), timeout=30)
            held.append(slow)
            slow.sendall(b"GET /plain-notes.txt HTTP/1.1\r\nHost: t\r\n")
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            quiet = ctx.wrap_socket(socket.create_connection(("127.0.0.1", HTTPS_PORT), timeout=30))
            held.append(quiet)
            time.sleep(1)
            t0 = time.time()
            got = [self.get("/plain-notes.txt", secure=i % 2 == 1) for i in range(10)]
            secs = time.time() - t0
            ok = all(st == 200 and b == b"notes\n" for st, _, b in got)
            self.result(f"20 idle, a slow and an idle TLS client: 10 requests served meanwhile ({secs:.1f} s)", ok and secs < 10, f"{[g[0] for g in got]}")
            slow.sendall(b"Connection: close\r\n\r\n")
            out = b""
            while True:
                b = slow.recv(65536)
                if not b:
                    break
                out += b
            self.result("the slow client's request, finished later, is answered", out.startswith(b"HTTP/1.1 200") and out.endswith(b"\r\n\r\nnotes\n"), out[:40].decode(errors="replace"))
            quiet.sendall(b"GET /plain-notes.txt HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
            out = b""
            while True:
                b = quiet.recv(65536)
                if not b:
                    break
                out += b
            self.result("the idle TLS connection's later request is answered", out.startswith(b"HTTP/1.1 200") and out.endswith(b"notes\n"), out[:40].decode(errors="replace"))
        except OSError as e:
            self.result("idle and slow clients", False, str(e))
        finally:
            for h in held:
                h.close()

    def run_all(self):
        # Content types, by extension only:
        for name, want in (("test-picture.png", "image/png"), ("test-picture.jpg", "image/jpeg"), ("plain-notes.txt", "text/plain"),
                           ("test-archive.zip", "application/zip"), ("test-program.app", "application/octet-stream"),
                           ("file-without-ext", "application/octet-stream")):
            st, h, _ = self.get("/" + name)
            self.result(f"type of {name}: {want}", st == 200 and h.get("content-type", "").startswith(want), f"{st} {h.get('content-type')}")

        self.files(False)
        self.files(True)

        # Folders:
        st, h, _ = self.get("/subfolder")
        self.result("a folder without its slash: 301 to it", st == 301 and h.get("location") == "/subfolder/", f"{st} {h.get('location')}")
        st, _, b = self.get("/subfolder/")
        self.result("a folder's index.html", st == 200 and b"subfolder index" in b, f"{st}")
        st, _, b = self.get("/listed-folder/")
        self.result("DIRLIST: a folder without an index is listed", st == 200 and b"first-file.txt" in b and b"second-file.txt" in b, f"{st}")
        st, _, b = self.get("/functions/")
        self.result("the CGI folder's listing hides scripts and programs", st == 200 and b"static-style.css" in b and b".lua" not in b and b"native.app" not in b, b[:200].decode(errors="replace"))

        # Limits and refusals:
        st, _, _ = self.get("/too-big-file.bin")
        self.result("a file over MAX_FILE_SIZE: 403", st == 403, f"{st}")
        st, _, _ = self.get("/no-such-file.txt")
        self.result("a missing file: 404", st == 404, f"{st}")
        for path in ("/../CONF/USERS.CFG", "/%2e%2e/CONF/USERS.CFG", "/.hidden", "/a%5cb", "/C:/CONF/USERS.CFG", "/x%00y"):
            out = self.raw(f"GET {path} HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n".encode())
            self.result(f"refused: {path}", out.startswith(b"HTTP/1.1 400"), out[:40].decode(errors="replace"))
        st, h, _ = self.get("/index.html", method="POST", body=b"x")
        self.result("POST to a file: 405", st == 405, f"{st}")
        st, _, _ = self.get("/index.html", method="DELETE")
        self.result("DELETE: 405", st == 405, f"{st}")
        out = self.raw(b"GET / HTTP/1.1\r\nHost: t\r\nX-Big: " + b"a" * 9000 + b"\r\n\r\n")
        self.result("headers over 8 KB: 431", out.startswith(b"HTTP/1.1 431"), out[:40].decode(errors="replace"))
        out = self.raw(b"NONSENSE\r\n\r\n")
        self.result("a malformed request: 400", out.startswith(b"HTTP/1.1 400"), out[:40].decode(errors="replace"))

        # Keep-alive: three requests on one connection:
        c = self.conn(False)
        try:
            bodies = []
            for _ in range(3):
                c.request("GET", "/plain-notes.txt")
                bodies.append(c.getresponse().read())
            self.result("keep-alive: three requests, one connection", bodies == [b"notes\n"] * 3, str(bodies))
        except Exception as e:  # noqa: BLE001
            self.result("keep-alive: three requests, one connection", False, str(e))
        finally:
            c.close()

        # Many at once (HTTP and HTTPS):
        outs = [None] * 20

        def one(i):
            outs[i] = self.get("/big-download.bin", secure=i % 2 == 1)
        threads = [threading.Thread(target=one, args=(i,)) for i in range(20)]
        t0 = time.time()
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        good = sum(1 for o in outs if o and o[0] == 200 and o[2] == BIG)
        self.result(f"20 clients at once (half HTTPS), all intact ({time.time() - t0:.1f} s)", good == 20, f"{good} of 20")
        self.concurrency()

        # CGI:
        st, h, b = self.get("/functions/native?a=1&b=two", headers={"User-Agent": "httpz-tests", "X-Test": "yes"})
        text = b.decode(errors="replace")
        self.result("CGI: a native program (.app)", st == 200 and h.get("x-native") == "yes" and "QUERY_STRING=a=1&b=two" in text, f"{st} {text[:120]!r}")
        self.result("CGI: REQUEST_METHOD, HTTP_ headers", "REQUEST_METHOD=GET" in text and "HTTP_USER_AGENT=httpz-tests" in text and "HTTP_X_TEST=yes" in text, text[:300])
        uid = next((l[4:] for l in text.splitlines() if l.startswith("UID=")), "")
        self.result("CGI: runs as the HTTPZ user, not root", uid not in ("", "0"), f"UID={uid}")
        st, h, b = self.get("/functions/native/extra/path", secure=True, method="POST", body=b"posted-body", headers={"Content-Type": "text/x-test"})
        text = b.decode(errors="replace")
        self.result("CGI: POST body on stdin, PATH_INFO, HTTPS=on", "BODY=posted-body" in text and "PATH_INFO=/extra/path" in text and "HTTPS=on" in text and "CONTENT_LENGTH=11" in text, text[:300])
        st, _, _ = self.get("/functions/native", method="POST", body=b"x" * (65 * 1024))
        self.result("CGI: a body over MAX_BODY: 413", st == 413, f"{st}")
        st, _, b = self.get("/functions/native.app")
        self.result("CGI: a program is never sent as a file", st == 404, f"{st}")
        st, _, b = self.get("/functions/static-style.css")
        self.result("CGI folder: other files are served", st == 200 and b == b"body{}\n", f"{st}")
        lua = os.path.exists(os.path.join(common.BUILD, nt.EDITIONS[self.edition][0], "APPS_3RD", "lua.app"))
        if lua:
            st, _, b = self.get("/functions/hello-world?x=1")
            self.result("CGI Lua: a script by its bare name", st == 200 and b"lua-hello x=1" in b, f"{st} {b[:80]!r}")
            st, _, b = self.get("/functions/hello-world/more/path")
            self.result("CGI Lua: PATH_INFO", st == 200 and b"path=/more/path" in b, f"{st} {b[:80]!r}")
            st, _, b = self.get("/functions/hello-world.lua")
            self.result("CGI Lua: the source is never sent", st == 404, f"{st}")
            st, _, b = self.get("/functions/echo-body", method="POST", body=b"lua-body-123")
            self.result("CGI Lua: reads the POST body", st == 200 and b"length=12 body=lua-body-123" in b, f"{st} {b[:80]!r}")
            st, _, b = self.get("/functions/teapot-status")
            self.result("CGI Lua: Status: sets the code", st == 418 and b"teapot" in b, f"{st}")
            st, h, _ = self.get("/functions/moved-away")
            self.result("CGI Lua: Location: is a 302", st == 302 and h.get("location") == "/index.html", f"{st} {h.get('location')}")
            if self.edition.startswith("metal"):  # cooperative editions can't stop a loop that never calls ZDOS
                t0 = time.time()
                st, _, _ = self.get("/functions/endless-loop")
                self.result("CGI: a script past CGI_TIMEOUT is stopped (504)", st == 504 and time.time() - t0 < 15, f"{st} {time.time() - t0:.1f} s")
                st, _, _ = self.get("/")
                self.result("and the server goes on", st == 200, f"{st}")
        else:
            self.result("CGI Lua (lua.app not in this edition's APPS_3RD: skipped)", True)
        if os.path.exists(os.path.join(common.BUILD, nt.EDITIONS[self.edition][0], "APPS_3RD", "micropython.app")):
            st, _, b = self.get("/functions/python-hello?q=7")
            self.result("CGI MicroPython: a .py script", st == 200 and b"py-hello" in b, f"{st} {b[:80]!r}")

        # TLS from outside:
        r = subprocess.run(["openssl", "s_client", "-connect", f"127.0.0.1:{HTTPS_PORT}", "-tls1_3", "-alpn", "http/1.1"],
                           input=b"", capture_output=True, timeout=30)
        out = r.stdout.decode(errors="replace")
        self.result("TLS 1.3, ALPN http/1.1, ECDSA, self-signed CN=zdos",
                    "TLSv1.3" in out and "ALPN protocol: http/1.1" in out and "ecdsa_secp256r1_sha256" in out and "CN=zdos" in out, out[-300:])
        r = subprocess.run(["openssl", "s_client", "-connect", f"127.0.0.1:{HTTPS_PORT}", "-tls1_2"], input=b"", capture_output=True, timeout=30)
        self.result("TLS 1.2 is refused", "Cipher is (NONE)" in r.stdout.decode(errors="replace") or r.returncode != 0, "")
        r = subprocess.run(["curl", "-sk", "--tls13-ciphers", "TLS_CHACHA20_POLY1305_SHA256", f"https://127.0.0.1:{HTTPS_PORT}/plain-notes.txt"],
                           capture_output=True, timeout=30)
        self.result("curl: ChaCha20-Poly1305", r.stdout == b"notes\n", r.stderr.decode(errors="replace")[:100])
        r = subprocess.run(["curl", "-sk", "--curves", "P-256", f"https://127.0.0.1:{HTTPS_PORT}/plain-notes.txt"], capture_output=True, timeout=30)
        self.result("curl: P-256 key exchange", r.stdout == b"notes\n", r.stderr.decode(errors="replace")[:100])

    def __call__(self):
        # Run once, from run_qemu's "until":
        if not self.done:
            self.done = True
            try:
                self.run_all()
            except Exception as e:  # noqa: BLE001
                self.result("the tests ran to the end", False, repr(e))
        return True


class Stop:
    # KILL (TERM) to HTTPZ's task, typed once the task is known, then until
    # it no longer answers. The task: SERVICES' line on the serial console
    # (metal), else PS's list on D: (PS.TXT).
    def __init__(self, d, img):
        self.d = d
        self.img = img
        self.began = None
        self.secs = None

    def __iter__(self):
        try:
            with open(os.path.join(self.d, "serial.txt"), errors="replace") as f:
                found = re.findall(r"Services: HTTPZ started \(task (\d+)\)", f.read())
        except OSError:
            found = []
        if not found:
            ps = (nt.mread(self.img, "PS.TXT") or b"").decode(errors="replace")
            found = [ln.split()[0] for ln in ps.splitlines() if "HTTPZ" in ln.upper() and ln.split()[0].isdigit()]
        self.began = time.time()
        return iter(f"KILL {found[-1] if found else 2}")

    def __call__(self):
        if self.began is None or answers():
            return False
        self.secs = time.time() - self.began
        return True


def qemu_args(edition, d, sock, forwards):
    args = nt.qemu(edition, d, sock, forwards=forwards)
    if ENV("HTTPZ_TEST_IMAGE"):
        shutil.copyfile(ENV("HTTPZ_TEST_IMAGE"), os.path.join(d, "system.img"))
    args = [a.replace("hostfwd=tcp:127.0.0.1:18080-", f"hostfwd=tcp:127.0.0.1:{NETTEST_PORT}-") for a in args]
    if ENV("HTTPZ_TEST_SMP"):
        args[args.index("-smp") + 1] = ENV("HTTPZ_TEST_SMP")
    return args


def run_edition(edition):
    d = os.path.join(OUT, edition)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    img = os.path.join(d, "netlog.img")
    subprocess.run(["mkfs.fat", "-F", "16", "-n", "NETLOG", "-C", img, str(48 * 1024)], check=True, capture_output=True)
    prepare(d, img)
    sock = os.path.join(d, "monitor.sock")
    host = HostTests(d, edition)
    stop = Stop(d, img)
    began = time.time()

    def has(name, marker):
        return lambda: marker in (nt.mread(img, name) or b"")

    boot = 60 if nt.EDITIONS[edition][2] else 20 if edition == "bios-x86" else 35
    steps = (common.command("HTTPTEST SETUP", 8)
             + [("until", has("SETUP.LOG", b"# SETUP done"), 180)]
             + common.command("REBOOT", 5)
             + [("wait", boot), ("until", answers, 180), ("shot", "boot", "HTTPZ started by SERVICES.CFG"),
                ("until", host, 1800), ("shot", "end", "the screen after the tests")]
             + common.command("PS > D:\\PS.TXT", 3)
             + [("until", has("PS.TXT", b"HTTPZ"), 30), ("text", stop), ("key", "ret"), ("until", stop, 30), ("wait", 2)]
             + common.command("COPY -y C:\\DATA\\LOGS\\httpz.log D:\\HTTPZLOG.TXT", 5)
             + common.command("SHUTDOWN", 15))
    forwards = f",hostfwd=tcp:127.0.0.1:{HTTP_PORT}-:80,hostfwd=tcp:127.0.0.1:{HTTPS_PORT}-:443"
    try:
        common.run_qemu(qemu_args(edition, d, sock, forwards), steps, d, sock, boot_wait=boot)
    except BrokenPipeError:
        pass  # SHUTDOWN ended QEMU before its monitor was told to quit
    return check(edition, d, img, host, stop, time.time() - began)


def check(edition, d, img, host, stop, seconds):
    results = list(host.results)
    if not host.done:
        results.append(("HTTPZ answered after the reboot (the tests ran)", False, ""))
    else:
        results.append((f"KILL (TERM) stops it: no longer answering ({stop.secs or 0:.0f} s)", stop.secs is not None, ""))
        text = (nt.mread(img, "HTTPZLOG.TXT") or b"").decode(errors="replace")
        tail = text[text.rfind("listening on port"):]
        results.append(("its log: workers, then stopping and stopped", re.search(r"\d+ workers", tail) is not None
                        and "stopping" in tail and tail.rstrip().endswith("stopped"), tail[-200:]))
    setup = (nt.mread(img, "SETUP.LOG") or b"").decode(errors="replace")
    with open(os.path.join(d, "SETUP.LOG"), "w") as f:
        f.write(setup)
    passed = sum(1 for r in results if r[1])
    with open(os.path.join(d, "results.md"), "w") as f:
        f.write(f"# HTTPZ tests: {edition}\n\n{passed} of {len(results)} passed, {seconds:.0f} s\n\n")
        for name, ok, detail in results:
            f.write(f"- {'PASS' if ok else 'FAIL'} {name}{' (' + detail + ')' if detail and not ok else ''}\n")
        f.write("\nScreenshots: boot.png, end.png\n")
    print(f"{edition}: {passed} of {len(results)} passed ({seconds:.0f} s)")
    for name, ok, detail in results:
        if not ok:
            print(f"  FAIL {name}{': ' + detail if detail else ''}")
    return passed == len(results)


def main():
    editions = sys.argv[1:] or [common.NAME]
    for e in editions:
        if e not in nt.EDITIONS:
            raise SystemExit(f"unknown edition {e} ({', '.join(nt.EDITIONS)})")
    ok = all([run_edition(e) for e in editions])
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
