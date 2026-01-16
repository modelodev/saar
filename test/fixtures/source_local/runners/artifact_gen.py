#!/usr/bin/env python3
"""Runner that generates artifacts."""
import json
import os
import sys


def emit(event):
    sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()


def main():
    input_json = json.loads(sys.stdin.read())
    workspace = os.environ.get("SAAR_WORKSPACE", "/tmp")

    output_path = os.path.join(workspace, "outputs", "report.pdf")
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "wb") as handle:
        handle.write(b"%PDF-1.4 test content")

    emit(
        {
            "t": "result",
            "status": "success",
            "data": {},
            "artifacts": [
                {"name": "report.pdf", "path": "outputs/report.pdf", "mime": "application/pdf"}
            ],
            "error": None,
        }
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
