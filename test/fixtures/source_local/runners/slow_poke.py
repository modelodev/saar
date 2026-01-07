#!/usr/bin/env python3
"""Slow health check server for timeout testing."""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            time.sleep(10)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"{\"status\":\"healthy\"}")
            return
        if self.path == "/echo":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if self.path != "/echo":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)


def main():
    if "--provision" in sys.argv:
        print(json.dumps({"t": "provision_result", "status": "success", "log_files": []}))
        return 0

    host = os.environ.get("SAD_HOST", "127.0.0.1")
    port = int(os.environ.get("SAD_PORT", os.environ.get("PORT", "8080")))
    HTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
