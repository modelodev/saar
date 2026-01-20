#!/usr/bin/env python3
"""Echo HTTP server for testing."""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
import time


class Handler(BaseHTTPRequestHandler):
    # Silence default access logs to keep test output clean.
    # Set SAAR_ECHO_SERVER_VERBOSE=1 to re-enable.
    def log_message(self, format, *args):
        if os.environ.get("SAAR_ECHO_SERVER_VERBOSE"):
            super().log_message(format, *args)
    def _send_json(self, payload: dict, status: int = 200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            return

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == "/health":
            self._send_json({"status": "healthy"})
            return

        if path == "/env":
            keys = ["SAAR_HOST", "SAAR_PORT", "TEST_HOST", "TEST_PORT"]
            self._send_json({k: os.environ.get(k) for k in keys})
            return

        if path == "/headers":
            self._send_json({
                "headers": {k.lower(): v for k, v in self.headers.items()},
            })
            return

        if path in ("/big", "/file", "/bin"):
            size = int(query.get("size", ["0"])[0])
            if path == "/big":
                content = b"a" * max(size, 0)
            elif path == "/file":
                content = b"b" * max(size, 0)
            else:
                # Return non-UTF8 bytes to validate binary proxying.
                marker = b"\xff\x00\xfe\xff"
                padding = b"x" * max(size - len(marker), 0)
                content = marker + padding
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            return

        if path == "/sleep":
            ms = int(query.get("ms", ["0"])[0])
            time.sleep(max(ms, 0) / 1000.0)
            self._send_json({"slept_ms": ms})
            return

        if path == "/sse":
            mode = query.get("mode", ["ok"])[0]
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()

            def emit(data: str):
                try:
                    self.wfile.write(f"data: {data}\n\n".encode("utf-8"))
                    self.wfile.flush()
                except BrokenPipeError:
                    return

            if mode == "invalid_json":
                emit("{not json}")
                return

            if mode == "unexpected_tag":
                emit(json.dumps({"t": "ping"}))
                return

            emit(json.dumps({"t": "log", "message": "hello", "level": "info"}))
            emit(json.dumps({"t": "chunk", "delta": "hi"}))

            if mode == "no_result":
                return

            emit(json.dumps({"t": "result", "status": "success", "data": {"answer": "ok"}, "artifacts": [], "error": None}))
            return

        if path == "/echo":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path not in ("/echo", "/multipart_check"):
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)

        if parsed.path == "/multipart_check":
            marker = b"\xff\x00\xfe\xff"
            self._send_json({
                "content_length": len(body),
                "contains_marker": marker in body,
                "track_id": "track-123",
            })
            return

        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)


def main():
    if "--provision" in sys.argv:
        print(json.dumps({"t": "provision_result", "status": "success", "log_files": []}))
        return 0

    host = os.environ.get("SAAR_HOST", "127.0.0.1")
    port = int(os.environ.get("SAAR_PORT", os.environ.get("PORT", "8080")))

    try:
        server = ThreadingHTTPServer((host, port), Handler)
    except OSError as exc:
        # Tests may intentionally trigger binding errors.
        if os.environ.get("SAAR_ECHO_SERVER_VERBOSE"):
            print(
                f"echo_server failed to bind {host}:{port}: {exc}",
                file=sys.stderr,
            )
        return 1

    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
