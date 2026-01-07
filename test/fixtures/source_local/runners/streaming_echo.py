#!/usr/bin/env python3
"""Runner that streams output."""
import json
import sys
import time


def emit(event):
    sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()


def main():
    input_json = json.loads(sys.stdin.read())
    messages = input_json.get("input", {}).get("messages", [])
    content = ""
    if messages:
        content = messages[-1].get("content", "")

    for word in content.split():
        emit({"t": "chunk", "delta": word + " "})
        time.sleep(0.05)

    emit(
        {
            "t": "result",
            "status": "success",
            "data": {"content": content},
            "artifacts": [],
            "error": None,
        }
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
