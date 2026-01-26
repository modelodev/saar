# Operations

Operational notes for running SAAR in local or server environments.

## Start/stop

Start the server:

```bash
gleam run -m saar -- serve --port 8081 --config runtime/config.toml
```

Stop and delete instances explicitly:

- `POST /sys/agents/:id/stop` stops the process (workspace remains).
- `DELETE /sys/agents/:id` removes workspace and purges artifacts.

## Wrapper and signals

- The wrapper is PID namespace aware and handles SIGTERM → SIGKILL.
- SAAR does not send signals directly to runners.

## Timeouts

Core limits are configured under `[limits]` in `config.toml`:

- `call_timeout_ms` for interactions
- `shutdown_timeout_ms` for stop/delete
- `max_runner_event_bytes` for JSONL events

## Notes

- SAAR does not automatically clean orphaned workspaces.
- Artifacts are available until instance deletion.

## Related docs

- `docs/config.md`
- `docs/runner_protocol.md`
