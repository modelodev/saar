#!/usr/bin/env python3
"""Generic UVX runner for SAAR transient profiles.

This runner executes a one-shot command using uvx and returns the result.
It handles:
- Provisioning (--provision): installs the tool
- Execution: runs the command with resolved args/env
- Artifact collection: gathers output files matching patterns

SAAR validates input against closed schemas (std:chat, std:files, chat extended)
before invoking this runner. The runner receives already-validated payloads and
doesn't need to understand schema structure. Templates in args/env_map are
resolved by SAAR (strict) before invoking runners.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List

def emit(event: Dict[str, Any]) -> None:
    """Emit exactly one JSONL event to STDOUT (flush)."""
    sys.stdout.write(json.dumps(event, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def normalize_args(values: Iterable[Any]) -> List[str]:
    """Convert runner_def.args to strings.

    Contract: templates are resolved by SAAR before invoking runners.
    """
    return [str(v) for v in values]


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


def require_runner_def(data: Dict[str, Any]) -> Dict[str, Any]:
    """Extract and validate runner_def from input."""
    runner_def = data.get("runner_def")
    if not isinstance(runner_def, dict):
        emit({
            "t": "result",
            "status": "error",
            "data": None,
            "artifacts": [],
            "error": {"kind": "infra_error", "message": "runner_def missing"},
        })
        sys.exit(1)
    return runner_def


def parse_args() -> argparse.Namespace:
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--provision", action="store_true")
    parser.add_argument("--help", action="store_true")
    args, unknown = parser.parse_known_args()
    if unknown:
        parser.error(f"Unknown arguments: {' '.join(unknown)}")
    if args.help:
        sys.stderr.write("Usage: generic_uvx.py [--provision]\n")
        sys.exit(0)
    return args


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
    
    cmd = ["uv", "tool", "install", "--force", package]
    for pkg in tool_cfg.get("with_packages", []):
        cmd.extend(["--with", pkg])
    
    try:
        subprocess.run(cmd, check=True, capture_output=True)
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


def main() -> None:
    """Main entry point."""
    args = parse_args()
    data = load_input()
    runner_def = require_runner_def(data)

    if args.provision:
        do_provision(runner_def.get("tool_config", {}))

    # Build environment
    env = os.environ.copy()
    for key, value in runner_def.get("env_map", {}).items():
        env[key] = str(value)

    # Build arguments
    raw_args = runner_def.get("args", [])
    args_list = normalize_args(raw_args)

    # Build command
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

    full_cmd = ["uvx"]
    for pkg in tool_cfg.get("with_packages", []):
        full_cmd.extend(["--with", pkg])
    full_cmd.extend(["--from", package, command, *args_list])
    
    workspace = Path.cwd()

    # Execute command
    try:
        result = subprocess.run(
            full_cmd,
            env=env,
            capture_output=True,
            text=True,
            errors="replace",
            cwd=str(workspace),
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

    # Collect artifacts
    artifacts = collect_artifacts(workspace, runner_def.get("artifact_config", {}))
    
    # Build response
    status = "success" if result.returncode == 0 else "error"
    payload: Dict[str, Any] = {
        "status": status,
        "data": {"stdout": result.stdout, "stderr": result.stderr},
        "artifacts": artifacts,
        "error": None,
    }
    
    if status == "error":
        payload["error"] = {
            "kind": "agent_error",
            "message": f"Exit code {result.returncode}",
        }
    
    emit({"t": "result", **payload})
    sys.exit(0 if status == "success" else 1)


if __name__ == "__main__":
    main()
