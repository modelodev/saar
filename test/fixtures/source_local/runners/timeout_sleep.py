#!/usr/bin/env python3
"""Runner that sleeps and exits on timeout stop."""
import json
import os
import signal
import sys
import time


def write_marker():
    marker = os.environ.get("SAAR_TIMEOUT_MARKER")
    if not marker:
        return
    with open(marker, "w", encoding="utf-8") as handle:
        handle.write("stopped")
        handle.flush()


def handle_sigterm(_signum, _frame):
    write_marker()
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, handle_sigterm)
    signal.signal(signal.SIGINT, handle_sigterm)

    raw = sys.stdin.read()
    if not raw:
        return 1
    _input_json = json.loads(raw)

    time.sleep(5.0)
    print(
        json.dumps(
            {
                "t": "result",
                "status": "success",
                "data": {"content": "done"},
                "artifacts": [],
                "error": None,
            }
        )
    )
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
