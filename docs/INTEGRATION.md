# SAAR Integration Guide

This document is for clients consuming SAAR (for example, a SAM-like client). It explains how to discover capabilities, invoke them, and handle response modes.

## 1. Discover capabilities

Use `GET /agents/:instance_id` to retrieve `capabilities`. Each capability declares:

- `input_schema`
- `response_mode` (`sync`, `stream`, `deferred`)
- `streaming` (SSE support)
- optional limits

The `capabilities` map is the authoritative list of operations clients can invoke.

### 1.1 File semantics

If a capability accepts files, the native view includes a `files` block:

- `files.accepts`
- `files.max_files`
- `files.ingest_effect` (`immediate` or `eventual`)

When `ingest_effect = "eventual"`, do not assume that uploads are immediately available for queries.

## 2. Invoke a capability (native API)

Endpoint: `POST /agents/:instance_id/interact`

Body:

- `capability`: capability id
- `inputs`: data conforming to `input_schema`
- `context.trace_id`: client-provided id for correlation

### 2.1 Ingest metadata

When file ingestion is involved, SAAR may include stable metadata in `data.metadata`:

- `ingest_effect`
- `max_files`
- `track_id` (if provided by the agent)

### 2.2 Busy state (422)

SAAR does not queue interactions per instance. If an instance is busy, `POST /agents/:id/interact` returns `422` (Problem Details). Clients should back off or use a different instance.

### 2.3 Meaning of capability

Capabilities are part of SAAR’s contract, not necessarily built-in operations of the underlying tool. Profiles map capabilities to runner invocations or HTTP requests.

## 3. Response modes

### 3.1 Sync

The response is returned immediately in the same HTTP call. Clients should parse the JSON and download `artifacts` if present.

### 3.2 Stream (SSE)

SAAR returns `text/event-stream` and emits incremental events until a terminal event. There is no replay or resume if the client disconnects.

### 3.3 Deferred (tasks)

SAAR returns a `task_id` and the client retrieves the result later.

#### Create task

`POST /agents/:instance_id/interact` can return `202` with:

- `task_id`
- `state: "running"`
- `instance_id`
- `capability`
- `links.get` and `links.subscribe`

#### Poll task

`GET /tasks/:task_id` returns at least:

- `task_id`, `instance_id`, `capability`, `state`
- terminal states: `completed`, `failed`, `cancelled`

#### Subscribe (SSE)

`GET /tasks/:task_id/subscribe` emits task updates. The stream closes on terminal state.

### 3.4 Cancelled vs failed

- `failed`: the agent or bridge failed.
- `cancelled`: SAAR aborted execution (stop/delete/shutdown).

Clients should not treat `cancelled` as a failure for retry logic.

## 4. A2A facade (summary)

If A2A is enabled, SAAR maps tasks and artifacts to A2A task lifecycle semantics and preserves `completed/failed/cancelled` distinctions.

## Related docs

- `docs/protocols.md`
- `docs/runner_protocol.md`
- `docs/gateway.md`
