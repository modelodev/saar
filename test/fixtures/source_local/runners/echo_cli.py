#!/usr/bin/env python3
"""Echo CLI runner for testing."""
import json
import sys
import time


def emit(event):
    sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()


def main():
    if "--provision" in sys.argv:
        emit({"t": "provision_result", "status": "success", "log_files": []})
        return 0

    input_json = json.loads(sys.stdin.readline())
    delay_ms = input_json.get("params", {}).get("delay_ms", 100)
    time.sleep(delay_ms / 1000)

    response = {
        "t": "result",
        "status": "success",
        "data": input_json.get("input", {}),
        "artifacts": [],
        "error": None,
    }
    emit(response)
    return 0


if __name__ == "__main__":
    sys.exit(main())
