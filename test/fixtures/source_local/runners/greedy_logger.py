#!/usr/bin/env python3
"""Runner that emits many log events."""
import json
import sys


def emit(event):
    sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()


def main():
    for _ in range(10000):
        emit({"t": "log", "level": "info", "message": "x" * 100})

    emit({"t": "result", "status": "success", "data": {}, "artifacts": [], "error": None})
    return 0


if __name__ == "__main__":
    sys.exit(main())
