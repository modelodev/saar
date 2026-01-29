#!/usr/bin/env python3
"""Echo CLI runner for testing."""
import json
import sys
import time


def emit(event):
    try:
        sys.stdout.write(json.dumps(event) + "\n")
        sys.stdout.flush()
    except BrokenPipeError:
        # The consumer closed stdout early (expected in some tests).
        # Exit quietly without a Python traceback.
        try:
            sys.stdout.close()
        except Exception:
            pass


def main():
    if "--provision" in sys.argv:
        emit({"t": "provision_result", "status": "success", "log_files": []})
        return 0

    input_json = json.loads(sys.stdin.read())
    payload = input_json
    if isinstance(input_json, dict) and input_json.get("t") == "input":
        payload = input_json.get("payload", {})

    delay_ms_raw = payload.get("params", {}).get("delay_ms", 100)
    try:
        delay_ms = int(delay_ms_raw)
    except (TypeError, ValueError):
        delay_ms = 100
    time.sleep(delay_ms / 1000)

    response = {
        "t": "result",
        "status": "success",
        "data": payload.get("input", {}),
        "artifacts": [],
        "error": None,
    }
    emit(response)
    return 0


if __name__ == "__main__":
    sys.exit(main())
