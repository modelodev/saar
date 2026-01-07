#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

check_jsonl() {
  python3 - <<'PY'
import json
import sys

for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    try:
        json.loads(line)
    except Exception as exc:
        sys.stderr.write(f"invalid json line: {exc}\n")
        sys.exit(1)
PY
}

run_and_check() {
  sh -c "$1" | check_jsonl
}

run_and_check "python3 \"$ROOT_DIR/test/fixtures/source_local/runners/echo_cli.py\" --provision < \"$ROOT_DIR/test/fixtures/payloads/chat_simple.json\""
run_and_check "python3 \"$ROOT_DIR/test/fixtures/source_local/runners/echo_cli.py\" < \"$ROOT_DIR/test/fixtures/payloads/chat_simple.json\""
run_and_check "python3 \"$ROOT_DIR/test/fixtures/source_local/runners/streaming_echo.py\" < \"$ROOT_DIR/test/fixtures/payloads/chat_simple.json\""
