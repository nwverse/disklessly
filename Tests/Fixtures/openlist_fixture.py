#!/usr/bin/env python3
"""OpenList 3 / AList 3 mock. Prints the listen port, then serves until killed.

Routes: POST /api/auth/login, /api/fs/list, /api/fs/get, /api/fs/remove, /api/fs/mkdir
        PUT  /api/fs/put
        GET  /raw/<path>  (the raw_url target, with Range)
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(sys.argv[1]).resolve()
USER = sys.argv[2]
PASSWORD = sys.argv[3]
TOKEN = "openlist-token-fixture"
ROOT.mkdir(parents=True, exist_ok=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.command, self.path))

    def drain(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        return self.rfile.read(length) if length else b""

    def send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        return self.headers.get("Authorization") == TOKEN

    def do_POST(self):
        raw = self.drain()
        path = urlparse(self.path).path
        try:
            payload = json.loads(raw.decode() or "{}")
        except json.JSONDecodeError:
            self.send_json(400, {"code": 400, "message": "bad json"})
            return
        if path == "/api/auth/login":
            if payload.get("username") == USER and payload.get("password") == PASSWORD:
                self.send_json(200, {"code": 200, "message": "success", "data": {"token": TOKEN}})
            else:
                self.send_json(200, {"code": 401, "message": "invalid"})
            return
        if not self.authorized():
            self.send_json(401, {"code": 401, "message": "unauthorized"})
            return
        if path == "/api/fs/mkdir":
            target = ROOT.joinpath(payload.get("path", "/").lstrip("/"))
            target.mkdir(parents=True, exist_ok=True)
            self.send_json(200, {"code": 200, "message": "success", "data": None})
            return
        if path == "/api/fs/list":
            directory = ROOT.joinpath(payload.get("path", "/").lstrip("/"))
            if not directory.is_dir():
                self.send_json(200, {"code": 500, "message": "not found", "data": None})
                return
            content = []
            for child in sorted(directory.iterdir()):
                content.append({"name": child.name, "size": child.stat().st_size if child.is_file() else 0, "is_dir": child.is_dir()})
            self.send_json(200, {"code": 200, "message": "success", "data": {"content": content, "total": len(content)}})
            return
        if path == "/api/fs/get":
            target = ROOT.joinpath(payload.get("path", "").lstrip("/"))
            if not target.is_file():
                self.send_json(200, {"code": 500, "message": "not found", "data": None})
                return
            host, port = self.server.server_address
            rel = target.relative_to(ROOT).as_posix()
            raw_url = "http://%s:%s/raw/%s" % (host, port, rel)
            self.send_json(200, {"code": 200, "message": "success", "data": {"name": target.name, "size": target.stat().st_size, "raw_url": raw_url}})
            return
        if path == "/api/fs/remove":
            directory = ROOT.joinpath(payload.get("dir", "/").lstrip("/"))
            for name in payload.get("names", []):
                item = directory / name
                if item.is_file():
                    item.unlink()
            self.send_json(200, {"code": 200, "message": "success", "data": None})
            return
        self.send_json(404, {"code": 404, "message": "no route"})

    def do_PUT(self):
        body = self.drain()
        if not self.authorized():
            self.send_json(401, {"code": 401, "message": "unauthorized"})
            return
        file_path = unquote(self.headers.get("File-Path", ""))
        target = ROOT.joinpath(file_path.lstrip("/"))
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(body)
        self.send_json(200, {"code": 200, "message": "success", "data": None})

    def do_GET(self):
        self.drain()
        parsed = urlparse(self.path)
        if not parsed.path.startswith("/raw/"):
            self.send_json(404, {"code": 404, "message": "no route"})
            return
        target = ROOT.joinpath(parsed.path[len("/raw/"):])
        if not target.is_file():
            self.send_error(404)
            return
        data = target.read_bytes()
        spec = self.headers.get("Range")
        if spec and spec.startswith("bytes="):
            start_s, _, end_s = spec[6:].partition("-")
            start = int(start_s) if start_s else 0
            end = int(end_s) if end_s else len(data) - 1
            end = min(end, len(data) - 1)
            chunk = data[start:end + 1]
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


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
