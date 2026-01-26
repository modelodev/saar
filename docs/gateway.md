# Gateway

The gateway is SAAR's HTTP surface. It enforces auth, exposes native endpoints, and serves artifacts.

## Security

- All endpoints require `Authorization: Bearer <api_key>` unless explicitly documented.
- `/artifacts` and `/ui` are treated as sensitive surfaces and never expose filesystem paths.

## Core endpoints

### Instances

- `POST /sys/agents` create instance
- `GET /sys/agents/:id/status` status
- `POST /sys/agents/:id/stop` stop instance
- `DELETE /sys/agents/:id` delete instance (purges workspace + artifacts)

### Interactions

- `POST /agents/:id/interact` invoke a capability
- `GET /agents/:id` instance view

### Artifacts

- `GET /artifacts/:artifact_id` returns the file contents
- `artifact_id` is opaque; SAAR validates the lookup and serves from the workspace

## Streaming (SSE)

If a capability uses `response_mode=stream`, the gateway returns `text/event-stream` and emits events until a terminal event. There is no replay or resume.

## Error handling

- Errors use Problem Details with a stable `type` and `title`.
- `422` is used when an instance is busy.

## Related docs

- `docs/protocols.md`
- `docs/runner_protocol.md`
