#!/usr/bin/env python3
"""Echo HTTP server runner for testing."""
import sys
import json
import os
from http.server import HTTPServer, BaseHTTPRequestHandler

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"status": "healthy"}')
        else:
            self.send_response(404)
            self.end_headers()
    
    def do_POST(self):
        if self.path == "/echo":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            response = {"status": "success", "data": json.loads(body)}
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()

def main():
    if "--provision" in sys.argv:
        print(json.dumps({"t": "provision_result", "status": "success", "log_files": []}))
        return 0
    
    port = int(os.environ.get("PORT", 8080))
    server = HTTPServer(("127.0.0.1", port), Handler)
    print(json.dumps({"t": "log", "level": "info", "message": f"Server running on port {port}"}))
    server.serve_forever()

if __name__ == "__main__":
    sys.exit(main())
