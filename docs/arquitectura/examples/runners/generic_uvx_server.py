#!/usr/bin/env python3
"""Generic UVX Server runner for SAAR continuous profiles.

This runner starts a long-running server process using uvx.
It handles:
- Provisioning (--provision): installs the tool
- Execution: starts the server with configured host/port
- Signal forwarding: propagates SIGTERM/SIGINT to child

SAAR validates input against closed schemas (std:chat, std:files, chat extended)
before invoking this runner. The runner receives already-validated payloads and
doesn't need to understand schema structure. Templates in args/env_map are
resolved by SAAR (strict) before invoking runners.
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import threading
from typing import Any, Dict, Optional

CHILD_PROCESS: Optional[subprocess.Popen[str]] = None

def emit(event: Dict[str, Any]) -> None:
    """Emit exactly one JSONL event to STDOUT (flush)."""
    sys.stdout.write(json.dumps(event, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def emit_log(message: str, level: str = "info", stream: Optional[str] = None) -> None:
    event: Dict[str, Any] = {"t": "log", "message": message, "level": level}
    if stream is not None:
        event["stream"] = stream
    emit(event)

def fatal_provision(kind: str, message: str) -> None:
    emit({
        "t": "provision_result",
        "status": "error",
        "log_files": [],
        "error": {"kind": kind, "message": message},
    })
    sys.exit(1)

def load_input(mode: str) -> Dict[str, Any]:
    """Load SAAR_INPUT_JSON from stdin."""
    try:
        return json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        msg = f"Invalid JSON: {exc}"
        if mode == "provision":
            fatal_provision("bad_request", msg)
        emit_log(msg, level="error")
        sys.exit(1)


def parse_args() -> argparse.Namespace:
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--provision", action="store_true")
    parser.add_argument("--help", action="store_true")
    args, unknown = parser.parse_known_args()
    if unknown:
        parser.error(f"Unknown arguments: {' '.join(unknown)}")
    if args.help:
        sys.stderr.write("Usage: generic_uvx_server.py [--provision]\n")
        sys.exit(0)
    return args


def require_runner_def(mode: str, data: Dict[str, Any]) -> Dict[str, Any]:
    """Extract and validate runner_def from input."""
    runner_def = data.get("runner_def")
    if not isinstance(runner_def, dict):
        if mode == "provision":
            fatal_provision("infra_error", "runner_def missing")
        emit_log("runner_def missing", level="error")
        sys.exit(1)
    return runner_def


def get_network_info(data: Dict[str, Any]) -> Dict[str, str]:
    """Get network info from SAAR_INPUT_JSON (preferred) or environment."""
    runner_block = data.get("runner") or {}
    host = runner_block.get("host") or os.environ.get("SAAR_HOST")
    port = runner_block.get("port") or os.environ.get("SAAR_PORT")

    if not host or not port:
        emit_log("Missing host/port from SAAR_INPUT_JSON and SAAR_HOST/SAAR_PORT", level="error")
        sys.exit(1)

    return {"host": str(host), "port": str(port)}


def do_provision(tool_cfg: Dict[str, Any]) -> None:
    """Run provisioning: install the tool using uv."""
    package = tool_cfg.get("package")
    if not package:
        fatal_provision("bad_request", "Missing tool_config.package")

    cmd = ["uv", "tool", "install", "--force", package]
    for pkg in tool_cfg.get("with_packages", []):
        cmd.extend(["--with", pkg])

    try:
        subprocess.run(cmd, check=True, capture_output=True)
    except subprocess.CalledProcessError as exc:
        error_msg = exc.stderr.decode(errors="ignore") if exc.stderr else str(exc)
        fatal_provision("infra_error", f"Provisioning failed: {error_msg}")

    emit({"t": "provision_result", "status": "success", "log_files": []})
    sys.exit(0)


def build_command(runner_def: Dict[str, Any]) -> list[str]:
    """Build the command to execute."""
    tool_cfg = runner_def.get("tool_config", {})
    package = tool_cfg.get("package")
    command = tool_cfg.get("command") or runner_def.get("command")

    if not package or not command:
        emit_log("tool_config.package/command must be set", level="error")
        sys.exit(1)

    full_cmd = ["uvx"]
    for pkg in tool_cfg.get("with_packages", []):
        full_cmd.extend(["--with", pkg])
    full_cmd.extend(["--from", package, command])

    # Add args (contract: templates are resolved by SAAR before invoking runners)
    raw_args = runner_def.get("args", [])
    for arg in raw_args:
        full_cmd.append(str(arg))

    return full_cmd


def configure_env(
    runner_def: Dict[str, Any],
    host: str,
    port: str,
) -> Dict[str, str]:
    """Build environment variables for the server process."""
    env = os.environ.copy()

    # env_map already resolved by SAAR
    for key, value in runner_def.get("env_map", {}).items():
        env[key] = str(value)

    # Set host/port via configured env vars
    runtime = runner_def.get("runtime", {})
    if port_var := runtime.get("port_env_var"):
        env[port_var] = port
    if host_var := runtime.get("host_env_var"):
        env[host_var] = host

    return env


def handle_signal(sig: int, _frame: Any) -> None:
    """Forward signals to child process for graceful shutdown."""
    global CHILD_PROCESS
    if CHILD_PROCESS is not None:
        emit_log(f"Received signal {sig}, forwarding to child...", level="info")
        CHILD_PROCESS.send_signal(sig)

def _pipe_stream_to_logs(stream: Any, stream_name: str) -> None:
    for line in iter(stream.readline, ""):
        emit_log(line.rstrip("\n"), level="info", stream=stream_name)


def main() -> None:
    """Main entry point."""
    global CHILD_PROCESS

    args = parse_args()
    mode = "provision" if args.provision else "server"
    data = load_input(mode)
    runner_def = require_runner_def(mode, data)

    if args.provision:
        do_provision(runner_def.get("tool_config", {}))
        return

    # Get network info from input (fallback to environment)
    network = get_network_info(data)
    host = network["host"]
    port = network["port"]

    # Build command and environment
    cmd = build_command(runner_def)
    env = configure_env(runner_def, host, port)

    # Set up signal handlers for graceful shutdown
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    # Start the server process
    # IMPORTANT: child stdout/stderr must NOT leak to our stdout, because SAAR expects JSONL.
    # We capture both streams and re-emit them as `t="log"` events.
    try:
        CHILD_PROCESS = subprocess.Popen(
            cmd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            errors="replace",
        )

        assert CHILD_PROCESS.stdout is not None
        assert CHILD_PROCESS.stderr is not None

        t_out = threading.Thread(target=_pipe_stream_to_logs, args=(CHILD_PROCESS.stdout, "stdout"), daemon=True)
        t_err = threading.Thread(target=_pipe_stream_to_logs, args=(CHILD_PROCESS.stderr, "stderr"), daemon=True)
        t_out.start()
        t_err.start()

        # Wait for the process to complete
        exit_code = CHILD_PROCESS.wait()
        sys.exit(exit_code)

    except Exception as exc:
        emit_log(f"Failed to start server: {exc}", level="error")
        sys.exit(1)


if __name__ == "__main__":
    main()
