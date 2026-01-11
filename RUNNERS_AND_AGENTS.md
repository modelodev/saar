# RUNNERS_AND_AGENTS

This document describes how to integrate external runners/agents with **SAD**.
It is intended for third-party developers building agents that SAD can invoke.

## Glossary

- **Runner**: the executable process SAD starts (CLI) or connects to (HTTP) to fulfill an interaction.
- **Agent**: the logical component providing capabilities. An agent may be implemented as a runner.
- **Interface**: how SAD talks to a runner. Current interfaces are:
  - **Runner (CLI/Port)**: SAD spawns a process and exchanges JSONL via stdin/stdout.
  - **HTTP**: SAD calls HTTP endpoints and may consume SSE for streaming.

## Core Contract

### Events (CLI/Port)

Runners communicate with SAD using **JSON Lines** (one JSON object per line) on stdout.
Each line must end with `\n`.

Common event shapes:

- `{"t":"log","level":"info"|"warn"|"error","message":"..."}`
- `{"t":"chunk","delta":"..."}`
- `{"t":"result","status":"success"|"error", ... }`
- `{"t":"provision_result","status":"success"|"error", ... }`

Notes:
- SAD enforces size limits per line/event and on total stdout.
- If your runner writes a partial line without `\n`, SAD treats it as an error.

### Fail-fast

SAD is designed to be **fail-fast**:
- If the runner emits invalid JSONL, violates the event sequence, or exceeds limits, the interaction fails.
- SAD does not rely on retry loops to “eventually succeed”.

As a runner author, prefer:
- Deterministic startup.
- Clear error events.
- Fast failure when requirements are not met.

## URL-backed FileRefs (Important)

When a user/client uploads a file to SAD, SAD represents it as a **URL-backed file reference**.

### What this means

- SAD will provide a `FileRef` with a `url`.
- The URL is the source of truth for the file contents.
- The file may be **binary** (PDF, images, etc.). Do not assume UTF-8.

### Runner-facing delivery models

A runner can receive a file in one of two ways (declared in the profile):

1) **Runner pulls the URL**
   - SAD passes the `FileRef.url` as part of the request payload.
   - The runner downloads the file.
   - Use this when the runner can reach SAD's file URLs.

2) **SAD proxies URL → multipart**
   - SAD downloads the file from `FileRef.url` and sends it to the runner as `multipart/form-data`.
   - Use this when the runner cannot access SAD's URLs directly, or when the runner API expects multipart.

### Multipart profile convention (v0)

- Multipart request bodies are **declared in the profile**.
- A multipart body uses:
  - `file_field`: a single multipart field name (e.g. `file`)
  - `files`: a list of `FileRef`

If multiple files are provided, SAD uses **N requests (one per file)** and fails fast on the first error.

### Guidance for runner authors

- Always handle:
  - timeouts and network errors,
  - file size limits,
  - binary data (do not decode as text unless you know it is text).
- Prefer returning structured JSON from upload endpoints (status + message), not raw echoed bytes.

### Security considerations

Treat `FileRef.url` as potentially:
- short-lived (TTL-based),
- authenticated/authorized,
- restricted to SAD’s network boundary.

Do not log full URLs if they may contain sensitive tokens.

## HTTP Interface

### Non-streaming requests

If your agent exposes an HTTP API:
- Implement predictable request/response behavior.
- Keep response bodies bounded; SAD enforces a maximum response size.

### Streaming via SSE upstream

If your agent streams output via Server-Sent Events (SSE):
- Use `Content-Type: text/event-stream`.
- Emit SSE `data:` frames.
- SAD expects each `data:` payload to be a JSON object compatible with the runner event shapes.
  - `t=log`, `t=chunk`, and finally `t=result`.

SAD ignores `log` and `chunk` during SSE consumption until it sees a `result`.
If the stream closes without a `result`, the interaction fails.

## Managed Ports (HTTP servers started by SAD)

Some agents are started by SAD but expose an HTTP server.
In that case SAD assigns a port and injects it via environment variables.

### Required env vars

When using managed ports, your runner should read:
- `SAD_HOST`: the host it should bind to.
- `SAD_PORT`: the port it should bind to.

SAD may also inject additional env vars if configured:
- `host_env_var`: custom env var name for the host value.
- `port_env_var`: custom env var name for the port value.

### Binding rules

- Bind to `SAD_HOST:SAD_PORT` exactly.
- Start listening as early as possible.
- Provide a health endpoint if your profile declares a health check.

## Health Checks

If your HTTP interface declares a health check:
- Implement the endpoint to return quickly.
- Return a stable status code when healthy.

SAD performs health checks without business retries; health check failures are treated as infra errors.

## Limits (What SAD enforces)

Exact keys and defaults live in SAD’s config docs, but as a runner author you should assume:
- **Health check timeout** (ms)
- **Max HTTP response bytes**
- **Max runner event bytes** (JSONL line size)
- **Max file fetch bytes** (URL-backed files)
- **Managed port host** (bind host)

Your runner should stay within these bounds and fail clearly when it cannot.

## Developing and Testing

Recommended practices:
- Provide a minimal echo/health implementation for smoke tests.
- Test both transient execution (CLI runner) and continuous mode (managed port HTTP server) if supported.
- For streaming, ensure your SSE stream always ends with `t=result`.

## Versioning

This document describes the current v0 expectations.
If you publish a runner, pin and test against a specific SAD version, and track changes in this contract over time.
