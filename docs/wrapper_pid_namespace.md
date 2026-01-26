# Wrapper (PID Namespace)

SAAR launches runners through a wrapper that isolates process trees and enforces stop semantics.

## Behavior

- The wrapper creates a PID namespace (rootless) and launches the runner.
- It forwards `SAAR_INPUT_JSON` to the runner's stdin.
- It listens for control lines:
  - `{"t":"input","payload":<SAAR_INPUT_JSON>}`
  - `{"t":"stop"}` or EOF

## Stop sequence

1) Wait for graceful exit.
2) Send SIGTERM to the subtree.
3) After timeout, send SIGKILL.

## Contracts

- The wrapper must stay silent on STDOUT.
- All runner output must be JSONL events on STDOUT.

## Related docs

- `docs/runner_protocol.md`
