# Protocols

This document summarizes SAAR's public protocol surfaces and their contracts.

## 1. Native HTTP

Core endpoints:
- `POST /sys/agents`: create instance
- `GET /sys/agents/:id/status`: instance status
- `DELETE /sys/agents/:id`: delete instance (purges workspace + artifacts)
- `POST /agents/:id/interact`: invoke capability
- `GET /agents/:id`: instance view
- `GET /artifacts/:artifact_id`: download artifact

### Response modes

- `sync`: `POST /agents/:id/interact` returns the final response.
- `stream`: `text/event-stream` with incremental events until terminal event.
- `deferred`: returns a `task_id` and the result is retrieved via `/tasks/:task_id`.

### Tasks (deferred)

Minimal task fields:
- `task_id`, `instance_id`, `capability`, `state`
- Terminal states: `completed`, `failed`, `cancelled`

`GET /tasks/:task_id` returns the task. `GET /tasks/:task_id/subscribe` streams updates.

### Artifacts

- Artifacts are registered by SAAR and referenced by opaque ids.
- Dotfiles/dotdirs are ignored by default when collecting artifacts unless explicitly included.

## 2. Runner protocol

CLI runners use JSONL over STDOUT with strict event shapes. See `docs/runner_protocol.md` for details.

## 3. A2A and AG-UI

SAAR can expose protocol adapters that translate between SAAR interactions and:
- A2A (Agent-to-Agent)
- AG-UI (Agent-GUI)

The adapter contract preserves:
- `task` lifecycle and terminal states
- `artifacts` with opaque ids and optional URLs
- streaming semantics

## 4. Capability mapping

Capabilities are part of SAAR's contract and are defined in profiles:
- Runner profiles map a capability to a runner invocation.
- HTTP profiles map a capability to an upstream HTTP request.

## Related docs

- `docs/runner_protocol.md`
- `docs/gateway.md`
- `INTEGRATION.md`
