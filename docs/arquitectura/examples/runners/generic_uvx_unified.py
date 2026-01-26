#!/usr/bin/env python3
"""Generic UVX runner for SAAR (cli + server).

This runner supports two modes:
- cli: one-shot command, returns a RunnerResponse.
- server: long-running process, forwards logs as JSONL.

Mode can be set explicitly with runner_def.mode = "cli" | "server",
or inferred from runner_def/runtime + SAAR_INPUT_JSON meta.mode.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import signal
import subprocess
import sys
import threading
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

CHILD_PROCESS: Optional[subprocess.Popen[str]] = None


def uv_paths() -> Tuple[Path, Path, Path]:
    """Return workspace, cache dir, and tool dir for uv."""
    workspace = Path(os.environ.get("SAAR_WORKSPACE", os.getcwd()))
    cache_dir = workspace / ".tmp" / "uv-cache"
    tool_dir = workspace / ".local" / "share" / "uv" / "tools"
    cache_dir.mkdir(parents=True, exist_ok=True)
    tool_dir.mkdir(parents=True, exist_ok=True)
    return workspace, cache_dir, tool_dir


def apply_uv_env(env: Dict[str, str]) -> Tuple[Dict[str, str], Path]:
    """Apply uv-specific environment variables."""
    workspace, cache_dir, tool_dir = uv_paths()
    python_dir = str(Path(sys.executable).parent)

    env["HOME"] = str(workspace)
    env["XDG_CACHE_HOME"] = str(cache_dir)
    env["UV_CACHE_DIR"] = str(cache_dir)
    env["UV_HTTP_CACHE_DIR"] = str(cache_dir)
    env["UV_TEMP_DIR"] = str(cache_dir)
    env["TMPDIR"] = str(cache_dir)
    env["TEMP"] = str(cache_dir)
    env["TMP"] = str(cache_dir)
    env["XDG_DATA_HOME"] = str(tool_dir)
    env["UV_TOOL_DIR"] = str(tool_dir)
    env["UV_NO_CONFIG"] = "1"
    env["PYTHONNOUSERSITE"] = "1"
    env["PATH"] = f"{python_dir}:{env.get('PATH', '')}"
    return env, cache_dir


def emit(event: Dict[str, Any]) -> None:
    """Emit exactly one JSONL event to STDOUT (flush)."""
    sys.stdout.write(json.dumps(event, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def emit_log(message: str, level: str = "info", stream: Optional[str] = None) -> None:
    event: Dict[str, Any] = {"t": "log", "message": message, "level": level}
    if stream is not None:
        event["stream"] = stream
    emit(event)


def normalize_args(values: Iterable[Any]) -> List[str]:
    """Convert runner_def.args to strings."""
    return [str(v) for v in values]


def chunk_text(value: str, limit: int) -> List[str]:
    """Split text into chunks within a byte limit (UTF-8 safe)."""
    encoded = value.encode("utf-8")
    chunks: List[str] = []
    for i in range(0, len(encoded), limit):
        chunk = encoded[i:i + limit]
        chunks.append(chunk.decode("utf-8", errors="ignore"))
    return chunks




def collect_artifacts(workspace: Path, config: Dict[str, Any]) -> List[Dict[str, str]]:
    """Collect artifacts matching include/exclude patterns."""
    include_patterns = config.get("include") or ["**/*"]
    if isinstance(include_patterns, str):
        include_patterns = [include_patterns]
    exclude_patterns = config.get("exclude") or []
    if isinstance(exclude_patterns, str):
        exclude_patterns = [exclude_patterns]

    artifacts: List[Dict[str, str]] = []
    for path in workspace.rglob("*"):
        if not path.is_file():
            continue
        rel = str(path.relative_to(workspace))
        if not any(fnmatch.fnmatch(rel, pat) for pat in include_patterns):
            continue
        if any(fnmatch.fnmatch(rel, pat) for pat in exclude_patterns):
            continue
        artifacts.append({
            "name": path.name,
            "path": rel,
            "mime": "application/octet-stream",
        })
    return artifacts


def load_input() -> Dict[str, Any]:
    """Load SAAR_INPUT_JSON from stdin."""
    try:
        return json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        emit({
            "t": "result",
            "status": "error",
            "data": None,
            "artifacts": [],
            "error": {"kind": "bad_request", "message": f"Invalid JSON: {exc}"},
        })
        sys.exit(1)


def parse_args() -> Tuple[argparse.Namespace, List[str]]:
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--provision", action="store_true")
    parser.add_argument("--help", action="store_true")
    args, unknown = parser.parse_known_args()
    if args.help:
        sys.stderr.write("Usage: generic_uvx_unified.py [--provision]\n")
        sys.exit(0)
    return args, unknown


def require_runner_def(data: Dict[str, Any], mode: str) -> Dict[str, Any]:
    """Extract and validate runner_def from input."""
    runner_def = data.get("runner_def")
    if not isinstance(runner_def, dict):
        if mode == "provision":
            emit({
                "t": "provision_result",
                "status": "error",
                "log_files": [],
                "error": {"kind": "infra_error", "message": "runner_def missing"},
            })
        else:
            emit({
                "t": "result",
                "status": "error",
                "data": None,
                "artifacts": [],
                "error": {"kind": "infra_error", "message": "runner_def missing"},
            })
        sys.exit(1)
    return runner_def


def do_provision(tool_cfg: Dict[str, Any]) -> None:
    """Run provisioning: install the tool using uv."""
    package = tool_cfg.get("package")
    if not package:
        emit({
            "t": "provision_result",
            "status": "error",
            "log_files": [],
            "error": {"kind": "bad_request", "message": "Missing tool_config.package"},
        })
        sys.exit(1)

    env, cache_dir = apply_uv_env(os.environ.copy())
    cmd = ["uv", "tool", "install", "--force", "--cache-dir", str(cache_dir)]
    python = tool_cfg.get("python")
    if python:
        cmd.extend(["--python", str(python)])
    cmd.append(package)
    for pkg in tool_cfg.get("with_packages", []):
        cmd.extend(["--with", pkg])

    try:
        subprocess.run(cmd, check=True, capture_output=True, env=env)
    except subprocess.CalledProcessError as exc:
        error_msg = exc.stderr.decode(errors="ignore") if exc.stderr else str(exc)
        emit({
            "t": "provision_result",
            "status": "error",
            "log_files": [],
            "error": {"kind": "infra_error", "message": f"Provisioning failed: {error_msg}"},
        })
        sys.exit(1)

    emit({"t": "provision_result", "status": "success", "log_files": []})
    sys.exit(0)


def resolve_mode(runner_def: Dict[str, Any], data: Dict[str, Any], mode: str) -> str:
    """Resolve runner mode (cli/server) from runner_def or SAAR_INPUT_JSON."""
    raw_mode = runner_def.get("mode", "auto")
    if raw_mode in ("cli", "server"):
        return raw_mode
    if raw_mode not in ("auto", None):
        message = f"Invalid runner mode: {raw_mode}"
        if mode == "provision":
            emit({
                "t": "provision_result",
                "status": "error",
                "log_files": [],
                "error": {"kind": "bad_request", "message": message},
            })
        else:
            emit({
                "t": "result",
                "status": "error",
                "data": None,
                "artifacts": [],
                "error": {"kind": "bad_request", "message": message},
            })
        sys.exit(1)

    runtime = runner_def.get("runtime", {})
    if runtime.get("port_env_var") or runtime.get("host_env_var") or runtime.get("mode") == "managed_port":
        return "server"

    runner_block = data.get("runner") or {}
    if runner_block.get("host") or runner_block.get("port"):
        return "server"

    meta_mode = (data.get("meta") or {}).get("mode")
    if meta_mode == "continuous":
        return "server"
    if meta_mode == "transient":
        return "cli"

    message = "Unable to infer runner mode; set runner_def.mode"
    if mode == "provision":
        emit({
            "t": "provision_result",
            "status": "error",
            "log_files": [],
            "error": {"kind": "bad_request", "message": message},
        })
    else:
        emit({
            "t": "result",
            "status": "error",
            "data": None,
            "artifacts": [],
            "error": {"kind": "bad_request", "message": message},
        })
    sys.exit(1)


def build_command(runner_def: Dict[str, Any], extra_args: List[str]) -> List[str]:
    """Build the command to execute."""
    tool_cfg = runner_def.get("tool_config", {})
    package = tool_cfg.get("package")
    command = tool_cfg.get("command") or runner_def.get("command")

    if not package or not command:
        emit({
            "t": "result",
            "status": "error",
            "data": None,
            "artifacts": [],
            "error": {"kind": "bad_request", "message": "tool_config.package/command must be set"},
        })
        sys.exit(1)

    _, cache_dir, _ = uv_paths()
    full_cmd = ["uvx", "--cache-dir", str(cache_dir)]
    python = tool_cfg.get("python")
    if python:
        full_cmd.extend(["--python", str(python)])
    for pkg in tool_cfg.get("with_packages", []):
        full_cmd.extend(["--with", pkg])
    full_cmd.extend(["--from", package, command])

    raw_args = extra_args or runner_def.get("args", [])
    full_cmd.extend(normalize_args(raw_args))
    return full_cmd


def configure_env(
    runner_def: Dict[str, Any],
    host: Optional[str] = None,
    port: Optional[str] = None,
) -> Dict[str, str]:
    """Build environment variables for the process."""
    env = os.environ.copy()
    env, _ = apply_uv_env(env)
    for key, value in runner_def.get("env_map", {}).items():
        env[key] = str(value)

    if host is not None or port is not None:
        runtime = runner_def.get("runtime", {})
        if port is not None and runtime.get("port_env_var"):
            env[runtime.get("port_env_var")] = str(port)
        if host is not None and runtime.get("host_env_var"):
            env[runtime.get("host_env_var")] = str(host)

    return env


def get_network_info(data: Dict[str, Any]) -> Dict[str, str]:
    """Get network info from SAAR_INPUT_JSON (preferred) or environment."""
    runner_block = data.get("runner") or {}
    host = runner_block.get("host") or os.environ.get("SAAR_HOST")
    port = runner_block.get("port") or os.environ.get("SAAR_PORT")

    if not host or not port:
        emit_log("Missing host/port from SAAR_INPUT_JSON and SAAR_HOST/SAAR_PORT", level="error")
        sys.exit(1)

    return {"host": str(host), "port": str(port)}


def handle_signal(sig: int, _frame: Any) -> None:
    """Forward signals to child process for graceful shutdown."""
    global CHILD_PROCESS
    if CHILD_PROCESS is not None:
        emit_log(f"Received signal {sig}, forwarding to child...", level="info")
        CHILD_PROCESS.send_signal(sig)


def _pipe_stream_to_logs(stream: Any, stream_name: str, buffer: List[str]) -> None:
    for line in iter(stream.readline, ""):
        buffer.append(line)
        emit_log(line.rstrip("\n"), level="info", stream=stream_name)


def run_cli(runner_def: Dict[str, Any], extra_args: List[str]) -> None:
    """Run command in one-shot mode and emit result."""
    env = configure_env(runner_def)
    cmd = build_command(runner_def, extra_args)
    workspace = Path(os.environ.get("SAAR_WORKSPACE", os.getcwd()))

    stdout_buf: List[str] = []
    stderr_buf: List[str] = []

    try:
        proc = subprocess.Popen(
            cmd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            errors="replace",
            cwd=str(workspace),
            bufsize=1,
        )
    except Exception as exc:
        emit({
            "t": "result",
            "status": "error",
            "data": None,
            "artifacts": [],
            "error": {"kind": "infra_error", "message": str(exc)},
        })
        sys.exit(1)

    assert proc.stdout is not None
    assert proc.stderr is not None

    t_out = threading.Thread(
        target=_pipe_stream_to_logs,
        args=(proc.stdout, "stdout", stdout_buf),
        daemon=True,
    )
    t_err = threading.Thread(
        target=_pipe_stream_to_logs,
        args=(proc.stderr, "stderr", stderr_buf),
        daemon=True,
    )
    t_out.start()
    t_err.start()

    return_code = proc.wait()
    t_out.join()
    t_err.join()

    artifacts = collect_artifacts(workspace, runner_def.get("artifact_config", {}))
    status = "success" if return_code == 0 else "error"
    stdout_text = "".join(stdout_buf)
    stderr_text = "".join(stderr_buf)
    payload: Dict[str, Any] = {
        "status": status,
        "data": {"stdout": stdout_text, "stderr": stderr_text},
        "artifacts": artifacts,
        "error": None,
    }

    if status == "error":
        payload["error"] = {
            "kind": "agent_error",
            "message": "Exit code "
            + str(return_code)
            + "\nSTDOUT:\n"
            + stdout_text
            + "\nSTDERR:\n"
            + stderr_text,
        }

    emit({"t": "result", **payload})
    sys.exit(0)


def run_server(runner_def: Dict[str, Any], data: Dict[str, Any], extra_args: List[str]) -> None:
    """Run command in server mode and forward logs."""
    global CHILD_PROCESS

    network = get_network_info(data)
    host = network["host"]
    port = network["port"]

    cmd = build_command(runner_def, extra_args)
    env = configure_env(runner_def, host=host, port=port)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

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

        exit_code = CHILD_PROCESS.wait()
        sys.exit(exit_code)
    except Exception as exc:
        emit_log(f"Failed to start server: {exc}", level="error")
        sys.exit(1)


def main() -> None:
    """Main entry point."""
    args, extra_args = parse_args()
    data = load_input()
    mode = "provision" if args.provision else "run"
    runner_def = require_runner_def(data, mode)

    if args.provision:
        do_provision(runner_def.get("tool_config", {}))

    resolved_mode = resolve_mode(runner_def, data, mode)
    if resolved_mode == "cli":
        run_cli(runner_def, extra_args)
    elif resolved_mode == "server":
        run_server(runner_def, data, extra_args)
    else:
        emit({
            "t": "result",
            "status": "error",
            "data": None,
            "artifacts": [],
            "error": {"kind": "infra_error", "message": f"Unknown mode: {resolved_mode}"},
        })
        sys.exit(1)


if __name__ == "__main__":
    main()
