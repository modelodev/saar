#!/usr/bin/env python3
"""Filesystem probe runner.

This runner is intentionally deterministic and is used by integration tests to
prove the Landlock sandbox boundaries.

It writes and reads inside SAD_WORKSPACE, then attempts to read/write outside
(using a sibling path) and reports whether access was denied.
"""

import json
import os
import errno
import sys


def emit(event):
    sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()


def attempt_write(path, contents):
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(contents)
        return {"ok": True, "errno": None}
    except OSError as e:
        return {"ok": False, "errno": e.errno}


def attempt_read(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = f.read()
        return {"ok": True, "errno": None, "data": data}
    except OSError as e:
        return {"ok": False, "errno": e.errno, "data": None}


def is_permission_denied(err_no):
    return err_no in (errno.EPERM, errno.EACCES)


def main():
    # Consume the input payload, but it is not needed.
    _ = sys.stdin.read()

    workspace = os.environ.get("SAD_WORKSPACE")
    if not workspace:
        emit({
            "t": "result",
            "status": "error",
            "data": None,
            "artifacts": [],
            "error": {"kind": "infra_error", "message": "missing SAD_WORKSPACE"},
        })
        return 2

    inside_path = os.path.join(workspace, "ok.txt")
    outside_path = os.path.abspath(os.path.join(workspace, "..", "denied", "out.txt"))

    inside_write = attempt_write(inside_path, "ok")
    inside_read = attempt_read(inside_path)

    outside_write = attempt_write(outside_path, "no")
    outside_read = attempt_read(outside_path)

    inside_ok = inside_write["ok"] and inside_read["ok"] and inside_read["data"] == "ok"

    outside_write_denied = (not outside_write["ok"]) and is_permission_denied(outside_write["errno"])
    outside_read_denied = (not outside_read["ok"]) and is_permission_denied(outside_read["errno"])

    # Keep values JSON-null-free because the runner contract JSON decoder
    # currently maps values containing `null` to `json.null()`.
    data = {
        "workspace": workspace,
        "inside_path": inside_path,
        "outside_path": outside_path,
        "inside_ok": inside_ok,
        "outside_write_denied": outside_write_denied,
        "outside_read_denied": outside_read_denied,
    }

    # This runner always reports success so the SAD API returns 200.
    # The integration test asserts the boolean flags in `data`.
    emit({
        "t": "result",
        "status": "success",
        "data": data,
        "artifacts": [],
        "error": None,
    })

    # Always exit 0: status is reported via the result event.
    return 0


if __name__ == "__main__":
    sys.exit(main())
