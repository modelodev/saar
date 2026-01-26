# Runner Protocol

This document defines the runner contract used by SAAR for CLI-based agents.

## Launch and wrapper

- SAAR always invokes `wrapper -- <runner> ...`.
- The wrapper creates a PID namespace, launches the runner, and controls stop/kill.
- Control is sent to the wrapper via JSONL on stdin:
  - `{"t":"input","payload":<SAAR_INPUT_JSON>}`
  - `{"t":"stop"}` or EOF to stop.

## Input and output

- Runner STDIN receives `SAAR_INPUT_JSON` (validated) from the wrapper.
- Runner STDOUT is a JSONL stream of events (one JSON object per line).
- STDERR is out of contract (local diagnostics only).

## Required events

Minimum events:
- `{"t":"log","message":"...","level":"info"}` (optional)
- `{"t":"chunk","delta":"..."}` (optional, streaming only)
- `{"t":"result", ...RunnerResponse...}` (required for transient)
- `{"t":"provision_result", ...}` (required for `--provision`)

Each event must end with `\n`. SAAR enforces per-line size limits.

## Provisioning

`./runner --provision` must be idempotent and end with a single `t="provision_result"` event.

## Transient vs continuous

- Transient: runner emits a single `t="result"` event and exits.
- Continuous: runner keeps running and emits `t="log"` (and optionally `t="chunk"`).

## Artifacts

- `artifacts` in `RunnerResponse` must be **relative** paths inside the workspace.
- Dotfiles/dotdirs are ignored by default unless explicitly included in `artifact_config.include`.

## Related docs

- `docs/protocols.md`
- `RUNNERS_AND_AGENTS.md`
- `docs/wrapper_pid_namespace.md`
