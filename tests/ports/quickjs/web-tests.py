#!/usr/bin/env python3
# QuickJS's web modules on ZDOS: qjs runs webtest.js as an HTTP and
# HTTPS server, the host is its client; then the server's SQLite
# database is checked. The port's qjs.app and SQLITE.ZDL go onto a
# test disk, so zig build is not needed.
#   web-tests.py [EDITION...]   default from ZDOS_EDITION / ZDOS_ARCH
#   (tests/common.py), metal x86_64
#   web-tests.py --host         the same checks against qjs built for
#   the host (no HTTPS)
import concurrent.futures
import hashlib
import http.client
import importlib.util
import json
import os
import shutil
import socket
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", ".."))
import common  # noqa: E402

spec = importlib.util.spec_from_file_location("nt", os.path.join(HERE, "..", "..", "net", "net-tests.py"))
nt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nt)

OUT = os.environ.get("QUICKJS_WEB_TESTS_OUT", os.path.join(common.BUILD, "quickjs-web-tests"))
WEB = HERE
HTTP_PORT, HTTPS_PORT = 18181, 18443
TIMEOUT = 60 * common.SLOW
BIG_FILE = 2 * 1024 * 1024


def big_file_bytes():
    return bytes((i * 31 + (i >> 8)) & 255 for i in range(BIG_FILE))


def make_cert(d):
    # A self-signed P-256 certificate for 127.0.0.1 and localhost:
    crt, key = os.path.join(d, "WEB.CRT"), os.path.join(d, "WEB.KEY")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                    "-nodes", "-keyout", key, "-out", crt, "-days", "30", "-subj", "/CN=localhost",
                    "-addext", "subjectAltName=IP:127.0.0.1,DNS:localhost"], check=True, capture_output=True)
    return crt, key


def make_www(d):
    www = os.path.join(d, "WWW")
    os.makedirs(os.path.join(www, "SUB"), exist_ok=True)
    with open(os.path.join(www, "index.html"), "w") as f:
        f.write("<h1>zdos:web static</h1>\n")
    with open(os.path.join(www, "SUB", "index.html"), "w") as f:
        f.write("<p>sub</p>\n")
    with open(os.path.join(www, "style.css"), "w") as f:
        f.write("body { color: #123; }\n")
    with open(os.path.join(www, "big.bin"), "wb") as f:
        f.write(big_file_bytes())
    return www


# THE CLIENT
# Each check: (name, passed, detail)

class Client:
    def __init__(self, port, tls_ca=None):
        self.port = port
        self.ctx = None
        if tls_ca:
            self.ctx = ssl.create_default_context(cafile=tls_ca)

    def conn(self):
        if self.ctx:
            return http.client.HTTPSConnection("127.0.0.1", self.port, timeout=TIMEOUT, context=self.ctx)
        return http.client.HTTPConnection("127.0.0.1", self.port, timeout=TIMEOUT)

    def req(self, method, path, body=None, headers=None, conn=None):
        c = conn or self.conn()
        h = dict(headers or {})
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
            h.setdefault("Content-Type", "application/json")
        c.request(method, path, body=body, headers=h)
        r = c.getresponse()
        data = r.read()
        if conn is None:
            c.close()
        return r, data

    def json(self, method, path, body=None, headers=None, conn=None):
        r, data = self.req(method, path, body, headers, conn)
        try:
            return r, json.loads(data) if data else None
        except ValueError:
            return r, data

    def raw(self, payload, until=None, read_all=False):
        # bytes on a socket of its own; the answer as bytes
        s = socket.create_connection(("127.0.0.1", self.port), timeout=TIMEOUT)
        if self.ctx:
            s = self.ctx.wrap_socket(s, server_hostname="127.0.0.1")
        try:
            s.sendall(payload)
            out = b""
            while True:
                try:
                    b = s.recv(65536)
                except socket.timeout:
                    break
                if not b:
                    break
                out += b
                if until and until(out):
                    break
            return out
        finally:
            s.close()


def check_all(c, results, tls=False):
    def result(name, ok, detail=""):
        results.append((("HTTPS: " if tls else "") + name, bool(ok), detail))

    def attempt(name, fn):
        try:
            fn()
        except Exception as e:  # noqa: BLE001
            result(name, False, f"{type(e).__name__}: {e}")

    # MIDDLEWARE AND QUERIES
    def basic():
        r, j = c.json("GET", "/echo?x=1&x=2&y[]=3&e=%C3%A9+z")
        ok = (r.status == 200 and j["query"] == {"x": ["1", "2"], "y": ["3"], "e": "é z"}
              and r.getheader("X-Powered-By") == "zdos:web" and r.getheader("X-Request-Method") == "GET"
              and (r.getheader("X-Response-Time") or "").endswith("ms") and j["secure"] == tls
              and j["protocol"] == ("https" if tls else "http"))
        result("middleware headers (set before and as the head goes out), query strings", ok, f"{r.status} {j} {r.getheaders()}")
    attempt("middleware headers, query strings", basic)

    # EVERY METHOD
    def methods():
        bad = []
        for m in ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "PURGE", "SEARCH"]:
            r, j = c.json(m, "/echo?m=" + m, {"m": m})
            if r.status != 200 or j["method"] != m or j["body"] != {"m": m}:
                bad.append(f"{m}: {r.status} {j}")
        r, data = c.req("HEAD", "/big?n=1234")
        r2, data2 = c.req("GET", "/big?n=1234")
        if r.status != 200 or data != b"" or r.getheader("Content-Length") != r2.getheader("Content-Length"):
            bad.append(f"HEAD: {r.status} {data[:50]} {r.getheader('Content-Length')} vs {r2.getheader('Content-Length')}")
        r, j = c.json("TRACE", "/any/a/b%20c")
        if r.status != 200 or j["params"].get("rest") != "a/b c":
            bad.append(f"TRACE app.all: {r.status} {j}")
        r, data = c.req("OPTIONS", "/api/v1/items/1")
        allow = set((r.getheader("Allow") or "").split(","))
        if r.status != 200 or not {"GET", "HEAD", "PUT", "PATCH", "DELETE"} <= allow:
            bad.append(f"OPTIONS automatic Allow: {r.status} {r.getheader('Allow')}")
        r, data = c.req("BREW", "/echo")
        if r.status != 404:
            bad.append(f"an unknown method: {r.status}")
        result("GET POST PUT PATCH DELETE OPTIONS PURGE SEARCH, HEAD from GET, TRACE by app.all, automatic OPTIONS, unknown 404",
               not bad, "; ".join(bad))
    attempt("every method", methods)

    # ROUTE PATHS
    def paths():
        bad = []
        for path, want in [("/files/docs/a/b.txt", {"dir": "docs", "path": "a/b.txt"}),
                           ("/files/x%20y/z", {"dir": "x y", "path": "z"}),
                           ("/opt/1", {"a": "1"}), ("/opt/1/2", {"a": "1", "b": "2"}), ("/re/42", {"0": "42"}),
                           ("/ECHO", {})]:
            r, j = c.json("GET", path)
            if r.status != 200 or j["params"] != want:
                bad.append(f"{path}: {r.status} {j}")
        r, _ = c.req("GET", "/re/x")
        if r.status != 404:
            bad.append(f"/re/x: {r.status}")
        result("route paths: :params, :optional?, *wildcards, RegExps, case-insensitive", not bad, "; ".join(bad))
    attempt("route paths", paths)

    # BODIES
    def bodies():
        bad = []
        r, j = c.json("POST", "/echo", b"a=1&b=x+y&b=z", {"Content-Type": "application/x-www-form-urlencoded"})
        if j["body"] != {"a": "1", "b": ["x y", "z"]}:
            bad.append(f"urlencoded: {j}")
        r, j = c.json("PUT", "/echo", "plain text é".encode(), {"Content-Type": "text/plain; charset=utf-8"})
        if j["body"] != "plain text é":
            bad.append(f"text: {j}")
        r, j = c.json("POST", "/echo", b"{bad json", {"Content-Type": "application/json"})
        if r.status != 400 or "error" not in (j or {}):
            bad.append(f"bad JSON: {r.status} {j}")
        data = bytes((i * 13) & 255 for i in range(1000000))
        r, j = c.json("POST", "/sum", data, {"Content-Type": "application/octet-stream"})
        if j != {"length": len(data), "sum": sum(data) % 65536}:
            bad.append(f"raw 1 MB: {j}")
        big = {"rows": [{"i": i, "s": "x" * 20} for i in range(30000)]}
        r, j = c.json("POST", "/echo", big)
        if r.status != 200 or len(j["body"]["rows"]) != 30000:
            bad.append(f"1 MB JSON: {r.status}")
        r, j = c.json("POST", "/echo", {"s": "x" * 3000000})
        if r.status != 413:
            bad.append(f"3 MB JSON over the 2 MB limit: {r.status}")
        result("body parsers: urlencoded, text, raw (1 MB), JSON (1 MB), bad JSON 400, over the limit 413", not bad, "; ".join(bad))
    attempt("body parsers", bodies)

    # COOKIES, REDIRECTS, STATUSES, ERRORS
    def cookies():
        r, data = c.req("GET", "/cookie/set")
        sc = r.headers.get_all("Set-Cookie") or []
        ok1 = (len(sc) == 2 and sc[0].startswith("plain=a%20b%3Bc;") and "HttpOnly" in sc[0] and "SameSite=Lax" in sc[0]
               and sc[1].startswith("obj=j%3A") and "Max-Age=60" in sc[1])
        r, j = c.json("GET", "/cookie/read", headers={"Cookie": "plain=a%20b%3Bc; obj=j%3A%7B%22n%22%3A5%7D"})
        ok2 = j == {"plain": "a b;c", "obj": {"n": 5}}
        r, data = c.req("GET", "/cookie/clear")
        ok3 = "Expires=Thu, 01 Jan 1970" in (r.getheader("Set-Cookie") or "")
        result("cookies: set (HttpOnly, SameSite, Max-Age, JSON values), read, cleared", ok1 and ok2 and ok3, f"{sc} {j}")
    attempt("cookies", cookies)

    def statuses():
        bad = []
        r, _ = c.req("GET", "/old")
        if r.status != 301 or r.getheader("Location") != "/echo?from=old":
            bad.append(f"301: {r.status} {r.getheader('Location')}")
        r, _ = c.req("GET", "/temp")
        if r.status != 302:
            bad.append(f"302: {r.status}")
        r, data = c.req("GET", "/teapot")
        if r.status != 418 or data != b"I'm a Teapot":
            bad.append(f"418: {r.status} {data}")
        r, data = c.req("GET", "/nothing")
        if r.status != 204 or data != b"" or r.getheader("Content-Length"):
            bad.append(f"204: {r.status} {data}")
        r, data = c.req("GET", "/no/such/page")
        if r.status != 404 or data != b"Cannot GET /no/such/page":
            bad.append(f"404: {r.status} {data}")
        r, data = c.req("GET", "/throw")
        if r.status != 500 or data != b"Internal Server Error":
            bad.append(f"a throw: {r.status} {data}")
        r, j = c.json("GET", "/reject")
        if r.status != 409 or j != {"error": "async conflict"}:
            bad.append(f"an async rejection: {r.status} {j}")
        r, j = c.json("GET", "/next-error")
        if r.status != 422 or j != {"error": "bad thing"}:
            bad.append(f"next(err): {r.status} {j}")
        result("redirects 301 302, 418, 204, 404, a throw 500, async rejection and next(err) to the error handler",
               not bad, "; ".join(bad))
    attempt("statuses and errors", statuses)

    def etags():
        conn = c.conn()
        r, data = c.req("GET", "/echo?etag=1", conn=conn)
        tag = r.getheader("ETag")
        r2, data2 = c.req("GET", "/echo?etag=1", headers={"If-None-Match": tag}, conn=conn)
        conn.close()
        result("ETag, If-None-Match: 304 without a body", tag and r2.status == 304 and data2 == b"", f"{tag} {r2.status}")
    attempt("ETag", etags)

    # STATIC FILES
    def static():
        bad = []
        r, data = c.req("GET", "/static/")
        if r.status != 200 or b"zdos:web static" not in data or "text/html" not in r.getheader("Content-Type", ""):
            bad.append(f"index.html: {r.status} {data[:40]}")
        r, data = c.req("GET", "/static/SUB")
        if r.status != 301 or r.getheader("Location") != "/static/SUB/":
            bad.append(f"a folder without /: {r.status} {r.getheader('Location')}")
        r, data = c.req("GET", "/static/style.css")
        if "text/css" not in r.getheader("Content-Type", "") or r.getheader("Cache-Control") != "public, max-age=60":
            bad.append(f"style.css: {r.getheader('Content-Type')} {r.getheader('Cache-Control')}")
        lm = r.getheader("Last-Modified")
        r2, d2 = c.req("GET", "/static/style.css", headers={"If-Modified-Since": lm})
        if r2.status != 304:
            bad.append(f"If-Modified-Since: {r2.status}")
        r, data = c.req("GET", "/static/big.bin")
        if r.status != 200 or hashlib.sha256(data).digest() != hashlib.sha256(big_file_bytes()).digest():
            bad.append(f"big.bin (2 MB): {r.status} {len(data)} bytes")
        r, data = c.req("HEAD", "/static/big.bin")
        if r.getheader("Content-Length") != str(BIG_FILE) or data:
            bad.append(f"HEAD big.bin: {r.getheader('Content-Length')}")
        for path in ["/static/../WEBTEST.JS", "/static/%2e%2e/WEBTEST.JS", "/static/..%5cWEBTEST.JS"]:
            r, data = c.req("GET", path)
            if r.status != 403 or b"WEBTEST" in data and b"import" in data:
                bad.append(f"{path}: {r.status}")
        r, data = c.req("GET", "/static/missing.txt")
        if r.status != 404:
            bad.append(f"missing: {r.status}")
        result("static files: index.html, folder redirect, types, Cache-Control, 304, 2 MB streamed, HEAD, .. refused 403, 404",
               not bad, "; ".join(bad))
    attempt("static files", static)

    # STREAMING, CHUNKED, 100-CONTINUE, KEEP-ALIVE
    def streaming():
        r, data = c.req("GET", "/stream")
        ok1 = r.getheader("Transfer-Encoding") == "chunked" and data == b"".join(b"piece %d\n" % i for i in range(5)) + b"end\n"
        r, data = c.req("GET", "/big?n=3000000")
        ok2 = len(data) == 3000000 and data == bytes((i * 7) & 255 for i in range(3000000))
        pieces = [bytes([i]) * 50000 for i in range(20)]
        conn = c.conn()
        conn.request("POST", "/sum", body=iter(pieces), headers={"Content-Type": "application/octet-stream"}, encode_chunked=True)
        j = json.loads(conn.getresponse().read())
        conn.close()
        allb = b"".join(pieces)
        ok3 = j == {"length": len(allb), "sum": sum(allb) % 65536}
        result("res.write (chunked, 5 pieces), a 3 MB body, a chunked upload of 1 MB", ok1 and ok2 and ok3, f"{ok1} {ok2} {j}")
    attempt("streaming", streaming)

    def wire():
        bad = []
        # Expect: 100-continue: the interim answer before the body
        s = socket.create_connection(("127.0.0.1", c.port), timeout=TIMEOUT)
        if c.ctx:
            s = c.ctx.wrap_socket(s, server_hostname="127.0.0.1")
        body = b'{"k":"v"}'
        s.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nExpect: 100-continue\r\n"
                  b"Content-Length: %d\r\n\r\n" % len(body))
        first = s.recv(100)
        s.sendall(body)
        rest = b""
        while b'"k":"v"' not in rest:
            b = s.recv(65536)
            if not b:
                break
            rest += b
        s.close()
        if not first.startswith(b"HTTP/1.1 100 Continue") or b"200 OK" not in rest:
            bad.append(f"100-continue: {first[:30]} {rest[:30]}")
        # three requests in one write, three answers in order
        reqs = b"".join(b"GET /echo?n=%d HTTP/1.1\r\nHost: x\r\n\r\n" % i for i in range(3))
        out = c.raw(reqs, until=lambda o: o.count(b'"n":"2"') == 1)
        if out.count(b"HTTP/1.1 200 OK") != 3 or not (out.find(b'"n":"0"') < out.find(b'"n":"1"') < out.find(b'"n":"2"')):
            bad.append(f"pipelining: {out.count(b'HTTP/1.1 200 OK')} answers")
        # HTTP/1.0: closed after the answer
        out = c.raw(b"GET /echo HTTP/1.0\r\n\r\n")
        if b"Connection: close" not in out or not out.rstrip().endswith(b"}"):
            bad.append(f"HTTP/1.0: {out[:200]}")
        # keep-alive: many on one connection
        conn = c.conn()
        for i in range(20):
            r, j = c.json("GET", f"/echo?i={i}", conn=conn)
            if j["query"] != {"i": str(i)}:
                bad.append(f"keep-alive request {i}")
                break
        conn.close()
        # garbage: 400, a huge head: 431
        out = c.raw(b"NOT HTTP AT ALL\r\n\r\n")
        if not out.startswith(b"HTTP/1.1 400"):
            bad.append(f"garbage: {out[:30]}")
        out = c.raw(b"GET /echo HTTP/1.1\r\nX-Big: " + b"a" * 40000 + b"\r\n\r\n")
        if not out.startswith(b"HTTP/1.1 431"):
            bad.append(f"a 40 KB head: {out[:30]}")
        result("100-continue, pipelining, HTTP/1.0 closing, 20 on one keep-alive connection, garbage 400, huge head 431",
               not bad, "; ".join(bad))
    attempt("the wire", wire)

    def many():
        def one(n):
            conn = c.conn()
            try:
                for i in range(5):
                    r, j = c.json("GET", f"/echo?c={n}&i={i}", conn=conn)
                    if r.status != 200 or j["query"] != {"c": str(n), "i": str(i)}:
                        return False
                return True
            finally:
                conn.close()
        with concurrent.futures.ThreadPoolExecutor(16) as ex:
            oks = list(ex.map(one, range(16)))
        result("16 clients at once, 5 requests each", all(oks), f"{oks.count(False)} failed")
    attempt("many clients", many)


def check_rest(c, results, tls=False):
    def result(name, ok, detail=""):
        results.append((("HTTPS: " if tls else "") + name, bool(ok), detail))
    try:
        bad = []
        base = "/api/v1"
        r, j = c.json("POST", base + "/items", {"name": "apple", "qty": 3})
        if r.status != 201 or r.getheader("Location") != f"{base}/items/{j['id']}" or r.getheader("X-Api-Version") != "v1":
            bad.append(f"POST: {r.status} {r.getheader('Location')} {r.getheader('X-Api-Version')} {j}")
        apple = j["id"]
        r, j = c.json("POST", base + "/items", {"name": "pear", "qty": 1})
        pear = j["id"]
        r, j = c.json("POST", base + "/items", {"name": "apple"})
        if r.status != 409 or "UNIQUE" not in j.get("error", ""):
            bad.append(f"a duplicate: {r.status} {j}")
        r, j = c.json("POST", base + "/items", {"qty": 1})
        if r.status != 400:
            bad.append(f"no name: {r.status}")
        r, j = c.json("GET", base + "/items")
        if [x["name"] for x in j] != ["apple", "pear"]:
            bad.append(f"GET list: {j}")
        r, j = c.json("GET", base + "/items?min=2")
        if [x["name"] for x in j] != ["apple"]:
            bad.append(f"GET ?min=2: {j}")
        r, j = c.json("PUT", f"{base}/items/{pear}", {"name": "pear2", "qty": 7})
        if j != {"id": pear, "name": "pear2", "qty": 7}:
            bad.append(f"PUT: {j}")
        r, j = c.json("PATCH", f"{base}/items/{apple}", {"add": 10})
        if j.get("qty") != 13:
            bad.append(f"PATCH: {j}")
        blob = bytes(range(256)) * 4
        r, _ = c.req("PUT", f"{base}/items/{apple}/data", blob, {"Content-Type": "application/octet-stream"})
        r2, data = c.req("GET", f"{base}/items/{apple}/data")
        if r.status != 204 or data != blob:
            bad.append(f"a blob: {r.status} {len(data)}")
        r, j = c.json("GET", f"{base}/items/abc")
        if r.status != 400 or j != {"error": "id: digits"}:
            bad.append(f"router.param: {r.status} {j}")
        r, _ = c.req("DELETE", f"{base}/items/{pear}")
        r2, j = c.json("GET", f"{base}/items/{pear}")
        if r.status != 204 or r2.status != 404:
            bad.append(f"DELETE: {r.status} then {r2.status}")
        r, j = c.json("POST", base + "/batch", [{"name": f"b{i}", "qty": i} for i in range(50)])
        if r.status != 201 or j != {"inserted": 50}:
            bad.append(f"a transaction: {r.status} {j}")
        r, j = c.json("POST", base + "/batch", [{"name": "c1", "qty": 1}, {"name": "b3", "qty": 1}])
        if r.status != 409 or j.get("count") != 51:
            bad.append(f"a transaction rolled back: {r.status} {j}")
        r, j = c.json("GET", base + "/types")
        if j != {"big": "bigint:9007199254740993", "f": 1.5, "t": "π", "n": None, "b": [0, 255]}:
            bad.append(f"types: {j}")
        result("REST on SQLite: POST 201+Location, 409, 400, GET list and query, PUT, PATCH, blob, param check, DELETE, "
               "transaction and rollback, BigInt", not bad, "; ".join(bad))
    except Exception as e:  # noqa: BLE001
        result("REST on SQLite", False, f"{type(e).__name__}: {e}")


def check_https_extra(c, results):
    def result(name, ok, detail=""):
        results.append(("HTTPS: " + name, bool(ok), detail))
    try:
        r, j = c.json("GET", "/api/v1/items")
        ok1 = r.status == 200 and isinstance(j, list) and len(j) == 51
        r, data = c.req("GET", "/static/big.bin")
        ok2 = hashlib.sha256(data).digest() == hashlib.sha256(big_file_bytes()).digest()
        result("the REST API's data and a 2 MB file over TLS", ok1 and ok2, f"{ok1} {len(data)}")
    except Exception as e:  # noqa: BLE001
        result("REST and files over TLS", False, f"{type(e).__name__}: {e}")


def shutdown(c, results):
    try:
        r, data = c.req("GET", "/shutdown")
        results.append(("GET /shutdown answered", data == b"bye", repr(data)))
    except Exception as e:  # noqa: BLE001
        results.append(("GET /shutdown answered", False, str(e)))


def check_db(path, results):
    try:
        db = sqlite3.connect(path)
        rows = db.execute("SELECT name, qty, length(data) FROM items ORDER BY id").fetchall()
        db.close()
        ok = rows[0] == ("apple", 13, 1024) and len(rows) == 51 and rows[-1] == ("b49", 49, None)
        results.append(("the database file afterwards, read here (sqlite3)", ok, str(rows[:2])))
    except Exception as e:  # noqa: BLE001
        results.append(("the database file afterwards, read here (sqlite3)", False, str(e)))


def answers(port):
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        conn.request("GET", "/echo")
        ok = conn.getresponse().status == 200
        conn.close()
        return ok
    except OSError:
        return False


def report(name, d, results, seconds):
    passed = sum(1 for r in results if r[1])
    with open(os.path.join(d, "results.md"), "w") as f:
        f.write(f"# QuickJS web on {name}\n\n{passed} of {len(results)} passed ({seconds:.0f} s)\n\n")
        for title, ok, detail in results:
            f.write(f"- {'PASS' if ok else 'FAIL'} {title}{': ' + detail if detail and not ok else ''}\n")
    print(f"{name}: {passed} of {len(results)} passed ({seconds:.0f} s)", flush=True)
    for title, ok, detail in results:
        if not ok:
            print(f"  FAIL {title}{': ' + detail[:400] if detail else ''}", flush=True)
    return passed == len(results)


# ON THIS COMPUTER

def host_qjs():
    # qjs with zdos:net (no TLS), zdos:sqlite and zdos:web, made again
    # when a file of the port is newer
    port = os.path.join(common.ROOT, "ports", "coding", "quickjs")
    srcs = os.environ.get("ZDOS_PORTS_SRC", os.path.dirname(common.ROOT))
    quickjs = os.environ.get("QUICKJS_SRC", os.path.join(srcs, "quickjs"))
    amalgamation = os.environ.get("SQLITE_AMALGAMATION", os.path.join(srcs, "sqlite-amalgamation"))
    out = os.path.join(common.BUILD, "quickjs", "hostweb", "qjs")
    mine = [os.path.join(port, f) for f in os.listdir(port)]
    if os.path.exists(out) and all(os.path.getmtime(f) < os.path.getmtime(out) for f in mine):
        return out
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with tempfile.TemporaryDirectory() as t:
        for f in ("quickjs-libc.c", "qjs.c"):
            shutil.copyfile(os.path.join(quickjs, f), os.path.join(t, f))
        with open(os.path.join(port, "quickjs-zdos.patch")) as f:
            subprocess.run(["patch", "-s", "-d", t, "-p1"], stdin=f, check=True)
        subprocess.run(["cc", "-O1", "-std=gnu11", "-D_GNU_SOURCE", "-DQUICKJS_NG_BUILD", "-DQJS_BUILD_LIBC",
                        "-D__zdos__=1", "-DZDOS_NET_NO_TLS", "-Wno-c23-extensions", "-I" + quickjs, "-I" + port,
                        "-I" + amalgamation]
                       + [os.path.join(quickjs, f) for f in ("dtoa.c", "libregexp.c", "libunicode.c", "quickjs.c",
                                                             "gen/repl.c", "gen/standalone.c")]
                       + [os.path.join(t, "quickjs-libc.c"), os.path.join(t, "qjs.c")]
                       + [os.path.join(port, f) for f in ("zdos_net.c", "zdos_sqlite.c", "zdos_web.c")]
                       + [os.path.join(amalgamation, "sqlite3.c"), "-lm", "-lpthread", "-ldl", "-o", out], check=True)
    return out


def run_host(qjs):
    d = os.path.join(OUT, "host")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    www = make_www(d)
    db = os.path.join(d, "WEB.DB")
    shutil.copyfile(os.path.join(WEB, "webtest.js"), os.path.join(d, "WEBTEST.JS"))
    log = open(os.path.join(d, "SERVER.LOG"), "w")
    began = time.time()
    proc = subprocess.Popen([qjs, "WEBTEST.JS", www, db], cwd=d, stdout=log, stderr=subprocess.STDOUT,
                            env=dict(os.environ, WEBTEST_PORT=str(HTTP_PORT)))
    results = []
    try:
        for _ in range(50):
            if answers(HTTP_PORT):
                break
            time.sleep(0.2)
        c = Client(HTTP_PORT)
        check_all(c, results)
        check_rest(c, results)
        shutdown(c, results)
        proc.wait(timeout=30)
        results.append(("the server ended after /shutdown (servers and database closed)", proc.returncode == 0, str(proc.returncode)))
    finally:
        if proc.poll() is None:
            proc.kill()
        log.close()
    check_db(db, results)
    return report("host", d, results, time.time() - began)


# ON ZDOS

class Session:
    # QEMU's "until" step: the checks, once the server answers
    def __init__(self, d, crt):
        self.d, self.crt = d, crt
        self.results = []
        self.done = False
        self.began = None

    def __call__(self):
        if not answers(HTTP_PORT):
            return False
        c = Client(HTTP_PORT)
        check_all(c, self.results)
        check_rest(c, self.results)
        t = Client(HTTPS_PORT, tls_ca=self.crt)
        check_all(t, self.results, tls=True)
        check_https_extra(t, self.results)
        shutdown(c, self.results)
        self.done = True
        return True


def run_edition(edition):
    d = os.path.join(OUT, edition)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    folder = nt.EDITIONS[edition][0]
    app = os.path.join(common.BUILD, folder, "APPS_3RD", "qjs.app")
    lib = os.path.join(common.BUILD, folder, "LIBS_3RD", "SQLITE.ZDL")
    for p in (app, lib):
        if not os.path.exists(p):
            raise SystemExit(f"{p} missing: run ports/coding/quickjs/build.sh")
    img = os.path.join(d, "netlog.img")
    subprocess.run(["mkfs.fat", "-F", "32", "-n", "WEBDISK", "-C", img, str(64 * 1024)], check=True, capture_output=True)
    crt, key = make_cert(d)
    www = make_www(d)
    run = os.path.join(d, "RUN.CMD")
    with open(run, "w", newline="") as f:
        f.write("@ECHO OFF\r\nD:\r\nCD \\\r\n"
                "qjs WEBTEST.JS D:/WWW D:/WEB.DB D:/WEB.CRT D:/WEB.KEY > SERVER.LOG 2> SERVER.ERR\r\n"
                "ECHO done > DONE.TXT\r\n")
    for src, name in ((app, "qjs.app"), (lib, "SQLITE.ZDL"), (crt, "WEB.CRT"), (key, "WEB.KEY"), (run, "RUN.CMD"),
                      (os.path.join(WEB, "webtest.js"), "WEBTEST.JS")):
        subprocess.run(["mcopy", "-i", img, src, "::/" + name], check=True)
    subprocess.run(["mcopy", "-s", "-i", img, www, "::/"], check=True)
    sock = os.path.join(d, "monitor.sock")
    session = Session(d, crt)
    boot = 60 if nt.EDITIONS[edition][2] else 20 if edition == "bios-x86" else 35
    began = time.time()
    steps = (common.command("D:\\RUN", 5)
             + [("until", session, 600),
                ("until", lambda: nt.mread(img, "DONE.TXT") is not None, 120), ("wait", 3)]
             + common.command("SHUTDOWN", 15))
    args = nt.qemu(edition, d, sock, forwards=f",hostfwd=tcp:127.0.0.1:{HTTPS_PORT}-:8443")
    args = [a.replace("hostfwd=tcp:127.0.0.1:18080-", f"hostfwd=tcp:127.0.0.1:{HTTP_PORT}-") for a in args]
    try:
        common.run_qemu(args, steps, d, sock, boot_wait=boot)
    except BrokenPipeError:
        pass  # SHUTDOWN ended QEMU before its monitor was told to quit
    results = list(session.results)
    if not session.done:
        results.append(("the server answered on port 8080", False, (nt.mread(img, "SERVER.ERR") or b"").decode(errors="replace")[:400]))
    log = (nt.mread(img, "SERVER.LOG") or b"").decode(errors="replace")
    err = (nt.mread(img, "SERVER.ERR") or b"").decode(errors="replace")
    for name, text in (("SERVER.LOG", log), ("SERVER.ERR", err)):
        with open(os.path.join(d, name), "w") as f:
            f.write(text)
    results.append(("the server ended after /shutdown (servers and database closed)",
                    "closed" in log and nt.mread(img, "DONE.TXT") is not None, log[-200:]))
    with tempfile.TemporaryDirectory() as t:
        db = os.path.join(t, "WEB.DB")
        subprocess.run(["mcopy", "-i", img, "::/WEB.DB", db], capture_output=True)
        check_db(db, results)
    r = subprocess.run(["fsck.fat", "-n", img], capture_output=True, text=True)
    results.append(("the test disk's FAT afterwards (fsck.fat -n)", r.returncode == 0, r.stdout[-200:]))
    return report(edition, d, results, time.time() - began)


def main():
    if sys.argv[1:2] == ["--host"]:
        sys.exit(0 if run_host(host_qjs()) else 1)
    editions = sys.argv[1:] or [common.NAME]
    for e in editions:
        if e not in nt.EDITIONS:
            raise SystemExit(f"unknown edition {e} ({', '.join(nt.EDITIONS)})")
    ok = all([run_edition(e) for e in editions])
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
