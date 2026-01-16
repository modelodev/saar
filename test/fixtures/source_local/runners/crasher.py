#!/usr/bin/env python3
"""Server that crashes after first request."""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    # Silence default access logs to keep test output clean.
    def log_message(self, format, *args):
        return
    crashed = False

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"{\"status\":\"healthy\"}")
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
        if not Handler.crashed:
            Handler.crashed = True
            sys.stdout.flush()
            os._exit(1)


def main():
    if "--provision" in sys.argv:
        print(json.dumps({"t": "provision_result", "status": "success", "log_files": []}))
        return 0
    if os.environ.get("SAAR_CRASH_ON_START") == "1":
        os._exit(1)

    host = os.environ.get("SAAR_HOST", "127.0.0.1")
    port = int(os.environ.get("SAAR_PORT", os.environ.get("PORT", "8080")))
    HTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
