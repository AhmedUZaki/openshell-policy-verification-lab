#!/usr/bin/env python3
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stdout.write("%s %s\n" % (self.address_string(), fmt % args))
        sys.stdout.flush()

    def marker(self):
        marker = self.headers.get("X-Origin-Name", "")
        return marker if marker in {"A", "B"} else "UNKNOWN"

    def send_text(self, status, text):
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/public" and query.get("stream") == ["1"]:
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                for item in ["STREAM_STARTED\n"] + [f"HEARTBEAT_{i}\n" for i in range(1, 121)]:
                    data = item.encode("utf-8")
                    self.wfile.write(f"{len(data):X}\r\n".encode("ascii") + data + b"\r\n")
                    self.wfile.flush()
                    time.sleep(1)
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if parsed.path == "/public":
            self.send_text(200, f"{self.marker()}_PUBLIC\n")
        elif parsed.path == "/private":
            self.send_text(200, f"{self.marker()}_PRIVATE\n")
        else:
            self.send_text(404, "NOT_FOUND\n")

    def do_POST(self):
        parsed = urlsplit(self.path)
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)
        if parsed.path == "/public":
            self.send_text(200, f"{self.marker()}_POST\n")
        else:
            self.send_text(404, "NOT_FOUND\n")

    def do_HEAD(self):
        parsed = urlsplit(self.path)
        if parsed.path == "/public":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
