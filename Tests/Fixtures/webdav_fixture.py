#!/usr/bin/env python3
"""Tiny WebDAV fixture. Prints the port on stdout, then serves until killed.

Usage: webdav_fixture.py ROOT [user password]
"""
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse
from xml.sax.saxutils import escape

ROOT = Path(sys.argv[1]).resolve()
USER = sys.argv[2] if len(sys.argv) > 2 else ""
PASSWORD = sys.argv[3] if len(sys.argv) > 3 else ""
ROOT.mkdir(parents=True, exist_ok=True)


def safe(url_path: str) -> Path:
    parsed = urlparse(url_path)
    rel = unquote(parsed.path).lstrip("/")
    if rel == "dav":
        rel = ""
    elif rel.startswith("dav/"):
        rel = rel[4:]
    candidate = (ROOT / rel).resolve()
    if candidate != ROOT and ROOT not in candidate.parents:
        raise PermissionError(rel)
    return candidate


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.command, self.path))

    def drain(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length:
            self.rfile.read(length)

    def plain(self, status, text):
        body = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self) -> bool:
        if not USER:
            return True
        header = self.headers.get("Authorization", "")
        import base64
        expected = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
        return header == expected

    def reject(self):
        body = b"unauthorized"
        self.send_response(401)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("WWW-Authenticate", 'Basic realm="isenough"')
        self.end_headers()
        self.wfile.write(body)

    def do_PROPFIND(self):
        self.drain()
        if not self.authorized():
            self.reject()
            return
        try:
            path = safe(self.path)
        except PermissionError as exc:
            self.plain(400, str(exc))
            return
        if not path.exists():
            self.send_error(404)
            return
        depth = self.headers.get("Depth", "1")
        items = [path]
        if path.is_dir() and depth != "0":
            items.extend(sorted(p for p in path.iterdir()))
        parts = ['<?xml version="1.0" encoding="utf-8"?>', '<multistatus xmlns="DAV:">']
        for item in items:
            rel = item.relative_to(ROOT).as_posix()
            href = "/dav/" + rel
            if item.is_dir() and not href.endswith("/"):
                href += "/"
            length = item.stat().st_size if item.is_file() else 0
            kind = "<collection/>" if item.is_dir() else ""
            parts.append(
                "<response><href>%s</href><propstat><prop><getcontentlength>%d</getcontentlength><resourcetype>%s</resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response>"
                % (escape(href), length, kind)
            )
        parts.append("</multistatus>")
        body = "".join(parts).encode()
        self.send_response(207)
        self.send_header("Content-Type", "application/xml")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.drain()
        if not self.authorized():
            self.reject()
            return
        try:
            path = safe(self.path)
        except PermissionError:
            self.send_error(400)
            return
        if not path.is_file():
            self.send_error(404)
            return
        data = path.read_bytes()
        spec = self.headers.get("Range")
        if spec and spec.startswith("bytes="):
            start_s, _, end_s = spec[6:].partition("-")
            start = int(start_s) if start_s else 0
            end = int(end_s) if end_s else len(data) - 1
            end = min(end, len(data) - 1)
            if start > end or start >= len(data):
                self.send_error(416)
                return
            chunk = data[start : end + 1]
            self.send_response(206)
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, len(data)))
            self.send_header("Content-Length", str(len(chunk)))
            self.end_headers()
            self.wfile.write(chunk)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_PUT(self):
        if not self.authorized():
            self.reject()
            return
        try:
            path = safe(self.path)
        except PermissionError:
            self.send_error(400)
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(body)
        self.send_response(201)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_MOVE(self):
        self.drain()
        if not self.authorized():
            self.reject()
            return
        dest = self.headers.get("Destination")
        overwrite = self.headers.get("Overwrite", "T")
        if not dest:
            self.send_error(400)
            return
        try:
            source = safe(self.path)
            target = safe(urlparse(dest).path)
        except PermissionError:
            self.send_error(400)
            return
        if not source.exists():
            self.send_error(404)
            return
        if target.exists() and overwrite.upper() == "F":
            self.send_error(412)
            return
        target.parent.mkdir(parents=True, exist_ok=True)
        source.replace(target)
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_DELETE(self):
        self.drain()
        if not self.authorized():
            self.reject()
            return
        try:
            path = safe(self.path)
        except PermissionError:
            self.send_error(400)
            return
        if not path.exists():
            self.send_error(404)
            return
        if path.is_dir():
            os.rmdir(path)
        else:
            path.unlink()
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_MKCOL(self):
        self.drain()
        if not self.authorized():
            self.reject()
            return
        try:
            path = safe(self.path)
        except PermissionError:
            self.send_error(400)
            return
        if path.exists():
            self.send_response(405)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        path.mkdir(parents=True, exist_ok=True)
        self.send_response(201)
        self.send_header("Content-Length", "0")
        self.end_headers()


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
