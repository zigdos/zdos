#!/usr/bin/env python3
# NetSurf on ZDOS against a web server on the host: forms, copying,
# downloads and uploads, cookies across a restart; screenshots are
# saved for review. Not in run-all.py.
#   netsurf-tests.py [EDITION...]   default from ZDOS_EDITION /
#   ZDOS_ARCH (tests/common.py), metal x86_64
import http.server
import os
import random
import subprocess
import sys
import threading
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import common  # noqa: E402

OUT = os.environ.get("NETSURF_TESTS_OUT", os.path.join(common.BUILD, "netsurf-tests"))
EDITIONS = {
    # name: (ZDOS_EDITION, ZDOS_ARCH, network card)
    "bios-x86": ("bios", "x86", "e1000"),
    "metal-x86_64": ("metal", "x86_64", "e1000e"),
    "uefi-x86_64": ("uefi", "x86_64", "virtio-net-pci"),
    "metal-arm64": ("metal", "arm64", "e1000e"),
    "uefi-arm64": ("uefi", "arm64", "virtio-net-pci"),
}
PORT = 18090
BASE = f"http://10.0.2.2:{PORT}"
POINTERS = os.path.join(common.BUILD, "netsurf", "src", "netsurf", "frontends", "framebuffer", "res", "pointers")
# Emulated (arm64 on x86, BIOS's slow paths): every wait longer
SLOW = common.SLOW * (2 if common.EDITION == "bios" else 1)

# THE PAGES

DL_DATA = random.Random(42).randbytes(300 * 1024)
SLOW_SIZE = 50 * 1024 * 1024
TOOLBAR = 30  # fb_toolbar_size: the page starts under it

PAGE = f"""<html><head><style>
body {{ margin: 0; font-family: sans-serif }}
#w {{ position: absolute; left: 40px; top: 60px; font-size: 40px }}
#f1 {{ position: absolute; left: 40px; top: 140px }}
#in {{ width: 500px; height: 40px; font-size: 24px }}
#f2 {{ position: absolute; left: 40px; top: 220px }}
#url {{ width: 700px; height: 40px; font-size: 20px }}
#f3 {{ position: absolute; left: 40px; top: 300px }}
#file {{ width: 400px; height: 40px }}
#send {{ width: 150px; height: 40px; font-size: 20px }}
#dl {{ position: absolute; left: 40px; top: 380px; font-size: 32px }}
#slow {{ position: absolute; left: 300px; top: 380px; font-size: 32px }}
#pic {{ position: absolute; left: 420px; top: 60px }}
</style></head><body>
<div id="w">zebra42 and more</div>
<form id="f1" action="/form" method="get"><input id="in" name="t" type="text"></form>
<form id="f2"><input id="url" type="text" value="{BASE}/pasted"></form>
<form id="f3" action="/upload" method="post" enctype="multipart/form-data"><input id="file" type="file" name="f"> <input id="send" type="submit" value="Send"></form>
<a id="dl" href="/dl.bin">dl.bin</a> <a id="slow" href="/slow.bin">slow.bin</a>
<img id="pic" src="/pic.svg" width="200" height="200">
</body></html>"""

# Where to click (screen pixels, the page under the toolbar):
WORD = (110, TOOLBAR + 85)
IN = (290, TOOLBAR + 160)
URL_FIELD = (390, TOOLBAR + 240)
FILE = (240, TOOLBAR + 320)
SEND = (40 + 400 + 90, TOOLBAR + 320)
DL = (90, TOOLBAR + 400)
SLOWLINK = (380, TOOLBAR + 400)
ADDRESS = (500, 14)  # inside the bar on BIOS's 640 too
ADDRESS_HTTP = (150, 14)  # "http" at the address's start

SVG = """<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200" viewBox="0 0 200 200">
<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
<stop offset="0" stop-color="#2060c0"/><stop offset="1" stop-color="#40c080"/></linearGradient></defs>
<rect x="10" y="10" width="180" height="180" rx="20" fill="url(#g)"/>
<circle cx="100" cy="100" r="50" fill="#ffffff" stroke="#000000" stroke-width="4"/>
</svg>"""


class Server:
    """What NetSurf asked for, in order: (path, query, headers, body)"""

    def __init__(self):
        self.log = []
        self.lock = threading.Lock()
        self.slow = {"started": False, "sent": 0, "aborted": False, "done": False}
        server = self

        class H(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def record(self, body=b""):
                u = urllib.parse.urlsplit(self.path)
                with server.lock:
                    server.log.append((u.path, urllib.parse.parse_qs(u.query), dict(self.headers), body))

            def send(self, data, ctype="text/html", extra=()):
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(data)))
                for k, v in extra:
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                self.record()
                path = urllib.parse.urlsplit(self.path).path
                if path == "/pic.svg":
                    return self.send(SVG.encode(), "image/svg+xml")
                if path == "/dl.bin":
                    return self.send(DL_DATA, "application/octet-stream",
                                     [("Content-Disposition", 'attachment; filename="dl.bin"')])
                if path == "/slow.bin":
                    return self.slow_bin()
                if path == "/setcookie":
                    return self.send(PAGE.encode(), extra=[("Set-Cookie", "zdos=works; Max-Age=86400; Path=/")])
                if path == "/favicon.ico":
                    self.send_response(404)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                self.send(PAGE.encode())

            def do_POST(self):
                n = int(self.headers.get("Content-Length", 0))
                self.record(self.rfile.read(n))
                self.send(PAGE.encode())

            def slow_bin(self):
                st = server.slow
                st["started"] = True
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(SLOW_SIZE))
                self.end_headers()
                chunk = bytes(64 * 1024)
                try:
                    while st["sent"] < SLOW_SIZE:
                        self.wfile.write(chunk)
                        st["sent"] += len(chunk)
                        time.sleep(0.25)
                    st["done"] = True
                except (BrokenPipeError, ConnectionResetError):
                    st["aborted"] = True

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H)
        self.httpd.daemon_threads = True
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def requests(self, path):
        with self.lock:
            return [r for r in self.log if r[0] == path]

    def count(self, path):
        return len(self.requests(path))

    def wait(self, path, after, secs):
        # A request for path beyond the first `after` ones:
        deadline = time.time() + secs * SLOW
        while time.time() < deadline:
            if self.count(path) > after:
                return self.requests(path)[after]
            time.sleep(0.5)
        return None

    def close(self):
        self.httpd.shutdown()


# THE POINTER

def load_pointers():
    # NetSurf's pointer images (tools/convert_image.c): row 0 and
    # column 0 mark the hotspot, the picture is the rest
    from PIL import Image
    import numpy as np
    out = []
    for name in ("default", "point", "caret", "menu"):
        path = os.path.join(POINTERS, name + ".png")
        if not os.path.exists(path):
            continue
        im = np.array(Image.open(path).convert("RGBA"))
        hx = next((x for x in range(1, im.shape[1]) if im[0, x, 3] > 128), 1) - 1
        hy = next((y for y in range(1, im.shape[0]) if im[y, 0, 3] > 128), 1) - 1
        body = im[1:, 1:]
        opaque = body[:, :, 3] > 128
        grey = body[:, :, :3].mean(axis=2)
        dark = list(zip(*np.nonzero(opaque & (grey < 90))))
        light = list(zip(*np.nonzero(opaque & (grey > 170))))
        out.append((name, body.shape[1], body.shape[0], hx, hy, dark, light))
    return out


class Screen:
    def __init__(self, mon, d):
        self.mon = mon
        self.d = d
        self.pointers = load_pointers()
        self.gain = [1.0, 1.0]

    def grab(self):
        from PIL import Image
        import numpy as np
        ppm = os.path.join(self.d, "grab.ppm")
        if os.path.exists(ppm):
            os.remove(ppm)
        self.mon.cmd(f"screendump {ppm}")
        for _ in range(40):
            if os.path.exists(ppm) and os.path.getsize(ppm) > 0:
                break
            time.sleep(0.1)
        time.sleep(0.3)
        return np.array(Image.open(ppm).convert("RGB")).astype(int)

    def size(self):
        img = self.grab()
        return img.shape[1], img.shape[0]

    def pointer(self):
        # The hotspot of whichever pointer is shown, or None:
        import numpy as np
        img = self.grab()
        # dark: not near white (dithered black has colours in it)
        grey = img.mean(axis=2)
        dark, light = grey < 200, grey >= 200
        h, w = grey.shape
        # 80% of its pixels: the BIOS edition's 16 colours dither it
        for name, tw, th, hx, hy, dk, lt in self.pointers:
            score = np.zeros((h - th, w - tw), np.int16)
            for y, x in dk:
                score += dark[y:y + h - th, x:x + w - tw]
            for y, x in lt:
                score += light[y:y + h - th, x:x + w - tw]
            best = np.unravel_index(int(score.argmax()), score.shape)
            if score[best] >= 0.8 * (len(dk) + len(lt)):
                y, x = best
                return int(x + hx), int(y + hy)
        return None

    def move(self, dx, dy):
        while dx or dy:
            sx, sy = max(-20, min(20, dx)), max(-20, min(20, dy))
            self.mon.cmd(f"mouse_move {sx} {sy}")
            dx, dy = dx - sx, dy - sy

    def goto(self, x, y):
        # Steered: QEMU's moves come out scaled and accelerated
        for _ in range(20):
            p = self.pointer()
            if p is None:
                # Off an edge, partly hidden: into the top left
                # corner, where it is all shown
                self.move(-2000, -2000)
                continue
            ex, ey = x - p[0], y - p[1]
            if abs(ex) <= 2 and abs(ey) <= 2:
                return True
            # at most 300 pixels a step: long moves accelerate
            # past the target, off the screen's edge
            ex, ey = max(-300, min(300, ex)), max(-300, min(300, ey))
            cx, cy = round(ex / self.gain[0]), round(ey / self.gain[1])
            self.move(cx, cy)
            q = self.settled(p)
            # unmoved: the screen not drawn yet (emulated), no measure
            if q is not None and q != p:
                for i, (c, a, b) in enumerate(((cx, p[0], q[0]), (cy, p[1], q[1]))):
                    if abs(c) >= 10:
                        self.gain[i] = min(3.0, max(0.3, (b - a) / c))
        return False

    def settled(self, before):
        # Where the pointer stops: emulated guests draw it late
        last = self.pointer()
        for _ in range(int(10 * SLOW)):
            if last is not None and last != before:
                now = self.pointer()
                if now == last:
                    return now
                last = now
            else:
                time.sleep(0.3)
                last = self.pointer()
        return last

    def raw(self, text):
        # Without the monitor helper's pause: double clicks need speed
        self.mon.sock.sendall((text + "\n").encode())
        time.sleep(0.04)

    def click(self, x, y, double=False):
        if not self.goto(x, y):
            print(f"  the pointer not brought to {x},{y} (at {self.pointer()})", flush=True)
            return False
        for _ in range(2 if double else 1):
            self.raw("mouse_button 1")
            self.raw("mouse_button 0")
        time.sleep(0.5)
        self.mon.drain()
        return True

    def keys(self, *names):
        for k in names:
            self.mon.cmd("sendkey " + k)
            time.sleep(0.05)

    def text(self, s):
        for ch in s:
            self.mon.cmd("sendkey " + common.key_name(ch))
            time.sleep(0.03)

    def shot(self, name):
        common.shot(self.mon, self.d, name)


# ONE EDITION

class Stop(Exception):
    # The rest of an edition's checks can't run
    pass


def qemu_args(sock, card):
    args = common.qemu_args(sock)
    i = args.index("-net")
    args[i:i + 2] = ["-netdev", "user,id=n0", "-device", f"{card},netdev=n0,romfile="]
    # UEFI x86_64: USB's mouse, as run-uefi-x86_64.sh (the firmware's
    # PS/2 one doesn't move the pointer)
    if common.EDITION == "uefi" and common.ARCH == "x86_64":
        i = args.index("q35")
        args[i:i + 1] = ["q35,i8042=off", "-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-mouse"]
    return args


def run_edition(name):
    card = EDITIONS[name][2]
    d = os.path.join(OUT, name)
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d):
        if f.endswith((".png", ".ppm")):
            os.remove(os.path.join(d, f))
    common.require_system()
    sock = os.path.join(d, "monitor.sock")
    if os.path.exists(sock):
        os.remove(sock)
    server = Server()
    results = []
    shots = []

    def check(title, ok, detail=""):
        results.append((title, bool(ok), detail))
        print(("PASS " if ok else "FAIL ") + title + (f": {detail}" if detail and not ok else ""), flush=True)

    def form_value(after):
        r = server.wait("/form", after, 60)
        return None if r is None else (r[1].get("t") or [""])[0]

    proc = subprocess.Popen(qemu_args(sock, card), cwd=common.ROOT, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    try:
        mon = common.Monitor(sock)
        scr = Screen(mon, d)
        time.sleep(common.BOOT_WAIT + 10 * SLOW)

        # The page; the SVG asked for and drawn:
        scr.text(f"NETSURF {BASE}/t1.htm")
        scr.keys("ret")
        check("the page loaded", server.wait("/t1.htm", 0, 180) is not None)
        check("the SVG image asked for", server.wait("/pic.svg", 0, 60) is not None)
        time.sleep(4 * SLOW)
        w, h = scr.size()
        scr.shot("page")
        shots.append(("page", "the test page: the SVG (a gradient square, white circle) at the right"))
        check("the pointer found on the screen", scr.pointer() is not None, f"screen {w}x{h}")
        # The SVG drawn: its circle's black outline, 4 px wide, around
        # (520, 160) on the page
        # (drawn after the page: slow guests take a while)
        for _ in range(int(20 * SLOW)):
            img = scr.grab()
            area = img[TOOLBAR + 60:TOOLBAR + 260, 420:620].mean(axis=2)
            dark = int((area < 80).sum())
            if dark > 600:
                break
            time.sleep(1)
        check("the SVG drawn (its circle's outline)", dark > 600, f"{dark} dark pixels")

        # The mouse: moves the pointer (UEFI's firmware may have no
        # mouse driver), else the rest can't be steered
        p = scr.pointer()
        scr.move(40, 40)
        q = scr.settled(p)
        check("the mouse moves the pointer", p is not None and q is not None and q != p, f"{p} -> {q}")
        if not results[-1][1]:
            raise Stop()

        # Keys: - = ) + _ typed into a form field arrive as typed:
        scr.click(*IN)
        scr.text("a-=)+_b")
        scr.keys("ret")
        got = form_value(0)
        check("typed into a form: a-=)+_b", got == "a-=)+_b", repr(got))

        # A word double-clicked, Ctrl+C (NetSurf stays), pasted:
        time.sleep(2 * SLOW)
        scr.click(*WORD, double=True)
        scr.keys("ctrl-c")
        scr.click(*IN)
        scr.keys("ctrl-a", "ctrl-v", "ret")
        got = form_value(1)
        check("a page word double-clicked, copied, pasted into a form", got == "zebra42", repr(got))

        # A form field's text copied into the address bar:
        time.sleep(2 * SLOW)
        scr.click(*URL_FIELD)
        scr.keys("ctrl-a", "ctrl-c")
        scr.click(*ADDRESS)
        scr.keys("ctrl-a", "ctrl-v", "ret")
        check("a form field copied, pasted into the address bar", server.wait("/pasted", 0, 60) is not None)

        # A word of the address bar double-clicked, copied, pasted:
        time.sleep(2 * SLOW)
        scr.click(*ADDRESS_HTTP, double=True)
        scr.keys("ctrl-c")
        scr.click(*IN)
        scr.keys("ctrl-a", "ctrl-v", "ret")
        got = form_value(2)
        check("an address bar word double-clicked, copied, pasted", got == "http", repr(got))

        # A download, complete:
        time.sleep(2 * SLOW)
        scr.click(*DL)
        check("the download asked for", server.wait("/dl.bin", 0, 60) is not None)
        time.sleep(5 * SLOW)

        # That file uploaded back through the file chooser:
        scr.click(*FILE)
        time.sleep(2 * SLOW)
        scr.shot("chooser")
        shots.append(("chooser", "the file chooser: path, list, OK and Cancel"))
        bh = TOOLBAR - 6
        pad = bh // 2
        rows = min(16, (h - 16 - 3 * bh - 4 * pad) // bh)
        win_h = 3 * bh + rows * bh + 2 + 4 * pad
        path_y = (h - win_h) // 2 + pad + bh + pad // 2 + bh // 2
        # typed over: a click into the field selects it all
        scr.click(w // 2, path_y)
        scr.text("C:\\USERS\\ROOT\\Downloads\\dl.bin")
        scr.shot("path")
        shots.append(("path", "the path typed into the file chooser"))
        scr.keys("ret")
        time.sleep(1 * SLOW)
        scr.click(*SEND)
        r = server.wait("/upload", 0, 120)
        body = r[3] if r else b""
        check("the download uploaded back byte for byte", DL_DATA in body and b'filename="dl.bin"' in body,
              f"{len(body)} bytes posted")

        # A slow download cancelled:
        time.sleep(2 * SLOW)
        scr.click(*SLOWLINK)
        server.wait("/slow.bin", 0, 60)
        time.sleep(3 * SLOW)
        scr.shot("download")
        shots.append(("download", "the download window: path, bytes, bar, Cancel"))
        dw, dh = bh * 18, 4 * bh + 4 * pad
        cancel = ((w - dw) // 2 + dw - pad - 2 * bh, (h - dh) // 2 + 3 * bh + 3 * pad + bh // 2)
        scr.click(*cancel)
        deadline = time.time() + 30 * SLOW
        while time.time() < deadline and not server.slow["aborted"]:
            time.sleep(0.5)
        check("Cancel ended the download", server.slow["aborted"] and not server.slow["done"],
              f"{server.slow['sent']} of {SLOW_SIZE} bytes sent")
        time.sleep(2 * SLOW)
        scr.shot("cancelled")
        shots.append(("cancelled", "after Cancel: no window, the status bar says so"))

        # Cookies across a restart:
        scr.click(*ADDRESS)  # typed over, as the path above
        scr.text(f"{BASE}/setcookie")
        scr.keys("ret")
        server.wait("/setcookie", 0, 60)
        time.sleep(3 * SLOW)
        scr.click(w - 14, 14)  # NetSurf's close button
        time.sleep(8 * SLOW)
        scr.text(f"NETSURF {BASE}/showcookie")
        scr.keys("ret")
        r = server.wait("/showcookie", 0, 180)
        cookie = r[2].get("Cookie", "") if r else ""
        check("the cookie kept across a restart", "zdos=works" in cookie, repr(cookie))
        time.sleep(4 * SLOW)
        scr.click(w - 14, 14)
        time.sleep(8 * SLOW)
        scr.shot("end")
        shots.append(("end", "NetSurf closed: the prompt back"))
        mon.cmd("quit")
    except Stop:
        pass
    except Exception as e:  # noqa: BLE001
        check("the run finished", False, repr(e))
    finally:
        time.sleep(2)
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        server.close()

    passed = sum(1 for r in results if r[1])
    with open(os.path.join(d, "results.md"), "w") as f:
        f.write(f"# NetSurf on {name}: {passed} of {len(results)} passed\n\n")
        for title, ok, detail in results:
            f.write(f"- {'PASS' if ok else 'FAIL'} {title}" + (f" ({detail})" if detail and not ok else "") + "\n")
        f.write("\nTo review:\n\n")
        for shot, note in shots:
            f.write(f"- `{shot}.png`: {note}\n")
    print(f"{name}: {passed} of {len(results)} passed; {d}/results.md", flush=True)
    return passed == len(results)


def main():
    if os.environ.get("NETSURF_TEST_CHILD"):
        sys.exit(0 if run_edition(common.NAME) else 1)
    names = sys.argv[1:] or [common.NAME]
    failed = []
    for name in names:
        if name not in EDITIONS:
            sys.exit(f"no edition {name} (have {', '.join(EDITIONS)})")
        edition, arch, _ = EDITIONS[name]
        env = dict(os.environ, ZDOS_EDITION=edition, ZDOS_ARCH=arch, NETSURF_TEST_CHILD="1")
        if subprocess.run([sys.executable, os.path.abspath(__file__)], env=env).returncode != 0:
            failed.append(name)
    print("all passed" if not failed else "failed: " + " ".join(failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
