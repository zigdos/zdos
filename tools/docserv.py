#!/usr/bin/env python3
# HTTP server for the generated HTML docs:
#   docserv.py [FOLDER] [--port N]   default docs/html, port 8008
# Clean URLs: /apps serves apps.html.

import argparse
import http.server
import os
import sys
import urllib.parse

DEFAULT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "html")

ap = argparse.ArgumentParser(description="Serves the generated HTML docs")
ap.add_argument("folder", nargs="?", default=DEFAULT_DIR, help="default: docs/html of this tree")
ap.add_argument("--port", type=int, default=8008, help="default 8008 (8000 is the network tests')")
args = ap.parse_args()

ROOT = os.path.realpath(args.folder)
if not os.path.isdir(ROOT):
    print(f"Error: The directory '{ROOT}' does not exist.")
    sys.exit(1)


class CleanURLHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    # /name -> /name.html (or .htm) when that file is in the folder:
    def clean(self):
        path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path).strip("/")
        base = os.path.realpath(os.path.join(ROOT, path))
        # Only inside the folder: nothing outside is looked at
        if not path or not base.startswith(ROOT + os.sep):
            return
        if path.endswith((".html", ".htm")) or os.path.exists(base):
            return
        for ext in (".html", ".htm"):
            if os.path.isfile(base + ext):
                self.path = "/" + urllib.parse.quote(path + ext)
                return

    def do_GET(self):
        self.clean()
        return super().do_GET()

    def do_HEAD(self):
        self.clean()
        return super().do_HEAD()


with http.server.ThreadingHTTPServer(("", args.port), CleanURLHandler) as httpd:
    print(f"Serving folder: {ROOT}")
    print(f"Server running at: http://localhost:{args.port}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping server...")
