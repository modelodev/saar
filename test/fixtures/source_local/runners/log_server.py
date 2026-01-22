#!/usr/bin/env python3
"""HTTP server that emits a log event on start."""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def emit_log(message: str):
    sys.stdout.write(json.dumps({"t": "log", "level": "info", "message": message}) + "\n")
    sys.stdout.flush()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b"{\"status\":\"healthy\"}")
            return

        self.send_response(404)
        self.end_headers()


def main():
    emit_log("server-start")
    host = os.environ.get("SAAR_HOST", "127.0.0.1")
    port = int(os.environ.get("SAAR_PORT", "0"))
    server = ThreadingHTTPServer((host, port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
