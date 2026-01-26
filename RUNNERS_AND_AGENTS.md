# RUNNERS_AND_AGENTS

This document describes how SAAR connects external **agents** (CLI tools and HTTP servers) to SAAR **instances** using **profiles**, **runners**, and **capabilities**.

It is intended for:
- authors of runner implementations (CLI/HTTP)
- authors of profile JSON documents

## Glossary

- **Instance**: a running agent managed by SAAR. Instances are created from a profile.
- **Profile**: declarative JSON describing how to start/connect to an agent and what capabilities SAAR exposes.
- **Capability**: a client-visible operation under `interface.capabilities`.
- **Runner**: the executable process SAAR starts (CLI) or the HTTP server SAAR connects to.
- **Interface**: how SAAR talks to a runner. Current interfaces are:
  - **Runner (CLI/Port)**: SAAR spawns a process and exchanges JSONL via stdin/stdout.
  - **HTTP**: SAAR calls HTTP endpoints and may consume SSE for streaming.

Important: capabilities are part of SAAR’s contract. They do not need to exist as first-class operations in the underlying agent.

## How capabilities are implemented

### Runner interface (`protocol: runner`)

In runner-based profiles, capabilities are “virtual”. They are implemented by how the profile invokes the runner.

Typical patterns:
- A CLI with no built-in capabilities (e.g. Aider) can still expose `chat` in SAAR.
- If the CLI does only one thing, the profile usually exposes a single capability.
- If multiple operations are needed, define multiple capabilities and map each to different args/env.

Example (vNext): `docs/arquitectura/examples/profiles/aider/aider_vnext.json` maps `chat` to `aider --message {{helpers.last_user_content}}`.

### HTTP interface (`protocol: http`)

In HTTP-based profiles, capabilities usually map to distinct upstream endpoints:
- The profile specifies `path` and `method`.
- The profile builds the request body using templates (including JSON Pointers).
- The profile declares how to extract content and artifacts via response mapping.

Example (vNext): `docs/arquitectura/examples/profiles/lightrag/lightrag_vnext.json` exposes `chat` and `files`.

## Response delivery modes

A capability also defines how SAAR delivers the result to clients via `response_mode`.

### Sync

SAAR returns the final response in the same HTTP request. This is the default when `response_mode` is omitted.

### Stream

SAAR returns `text/event-stream` and emits incremental events until a terminal event.

This requires `response_mode: "stream"`, `streaming: true`, and that the runner/upstream can produce incremental output.

### Deferred (tasks)

SAAR returns immediately with a task identifier. The client later fetches the result via task APIs (polling or SSE task subscription).
This requires `response_mode: "deferred"` and `streaming: false`.

Operational notes:
- SAAR does not maintain a per-instance queue. If the agent is busy, new interactions are rejected.
- SAAR distinguishes failure vs cancellation:
  - `failed`: the agent/upstream returned an error
  - `cancelled`: SAAR aborted the execution (stop/delete/shutdown/enforcement)

## Core contract: events (CLI/Port)

Runners communicate with SAAR using **JSON Lines** (one JSON object per line) on stdout.
Each line must end with `\n`.

Common event shapes:
- `{"t":"log","level":"info"|"warn"|"error","message":"..."}`
- `{"t":"chunk","delta":"..."}`
- `{"t":"result","status":"success"|"error", ... }`
- `{"t":"provision_result","status":"success"|"error", ... }`

Notes:
- SAAR enforces size limits per line/event and on total stdout.
- If your runner writes a partial line without `\n`, SAAR treats it as an error.

### Fail-fast

SAAR is designed to be **fail-fast**:
- If the runner emits invalid JSONL, violates the event sequence, or exceeds limits, the interaction fails.
- SAAR does not rely on retry loops to “eventually succeed”.

As a runner author, prefer deterministic startup and clear error events.

## Artifacts and dotfiles

SAAR ignores dotfiles/dotdirs (path segments starting with `.`) when collecting
artifacts, unless the profile explicitly opts in with an include pattern that
mentions a dot segment (e.g. `.well-known/**` or `**/.well-known/**`).

Runner guidance:
- Put caches, installs, and temporary files under dot directories.
- If you need a dot-path as a real artifact, update `artifact_config.include`.

## URL-backed FileRefs (important)

When a client provides a file to SAAR, SAAR represents it as a **URL-backed file reference**.

What this means:
- SAAR will provide a `FileRef` with a `url`.
- The URL is the source of truth for the file contents.
- The file may be binary (PDF, images, etc). Do not assume UTF-8.

### Runner-facing delivery models

A runner can receive a file in one of two ways (declared in the profile):

1) Runner pulls the URL
- SAAR passes the `FileRef.url` as part of the request payload.
- The runner downloads the file.

2) SAAR proxies URL → multipart
- SAAR downloads the file from `FileRef.url` and sends it to the runner as `multipart/form-data`.
- Use this when the runner API expects multipart or cannot access SAAR’s file URLs.

### Multipart profile convention (v0)

Multipart request bodies are declared in the profile.

If multiple files are provided, SAAR may choose either:
- N requests (one per file), or
- a single multipart request with multiple file parts

depending on the declared capability and schema.

## HTTP interface

### Non-streaming requests

If your agent exposes an HTTP API:
- Implement predictable request/response behavior.
- Keep response bodies bounded; SAAR enforces a maximum response size.

### Streaming via SSE upstream

If your agent streams output via SSE:
- Use `Content-Type: text/event-stream`.
- Emit SSE `data:` frames.
- SAAR expects each `data:` payload to be a JSON object compatible with runner event shapes:
  - `t=log`, `t=chunk`, and finally `t=result`.

If the stream closes without a `result`, the interaction fails.

## Managed ports (HTTP servers started by SAAR)

Some agents are started by SAAR but expose an HTTP server. In that case SAAR assigns a port and injects it via environment variables.

Required env vars:
- `SAD_HOST`: host to bind to
- `SAD_PORT`: port to bind to

SAAR may also inject custom env var names via profile runtime config.

Binding rules:
- Bind to `SAD_HOST:SAD_PORT` exactly.
- Start listening as early as possible.
- Provide a health endpoint if the profile declares a health check.

## Limits (what SAAR enforces)

Exact keys and defaults live in SAAR’s config docs, but runner authors should assume:
- health check timeout
- max HTTP response bytes
- max runner event bytes (JSONL line size)
- max file fetch bytes

Your runner should stay within these bounds and fail clearly when it cannot.
