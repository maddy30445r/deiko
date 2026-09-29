#!/usr/bin/env python3
"""Serve site/ for local preview.

    python3 scripts/serve-site.py [port]

Exists because `python3 -m http.server` cannot serve video you can scrub.
SimpleHTTPRequestHandler ignores the Range header and answers every request
with the whole file, so Chrome can only seek inside what it has already
buffered — click past that and currentTime silently snaps back to 0. Any real
static host (S3, Netlify, nginx) does ranges, so this only ever bites locally,
which is exactly why it is confusing when it does.

Also sends no-store, so a reload always picks up the file you just edited.
"""

import os
import re
import sys
import http.server

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "site")


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def send_head(self):
        rng = self.headers.get("Range")
        path = self.translate_path(self.path)
        if not rng or os.path.isdir(path):
            return super().send_head()

        m = re.match(r"bytes=(\d*)-(\d*)\s*$", rng)
        if not m:
            return super().send_head()

        try:
            f = open(path, "rb")
        except OSError:
            self.send_error(404)
            return None

        with f:
            size = os.fstat(f.fileno()).st_size
            start, end = m.group(1), m.group(2)
            if start == "":
                # "bytes=-500" means the LAST 500 bytes, not "up to byte 500".
                start, end = max(0, size - int(end or 0)), size - 1
            else:
                start, end = int(start), (int(end) if end else size - 1)
            end = min(end, size - 1)

            if start >= size or start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return None

            self.send_response(206)
            self.send_header("Content-Type", self.guess_type(path))
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.send_header("Content-Length", str(end - start + 1))
            self.end_headers()

            # Write the slice here and return None: the caller copies to EOF
            # whenever send_head returns a file object.
            f.seek(start)
            remaining = end - start + 1
            while remaining > 0:
                chunk = f.read(min(64 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)
        return None


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8766
    print(f"site → http://localhost:{port}  (ranges on, cache off)")
    http.server.test(HandlerClass=Handler, port=port, bind="127.0.0.1")
