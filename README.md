# SAAR

SAAR runs external agents (CLI tools or HTTP servers) as isolated instances with strict contracts and deterministic operations.

## Purpose

- Integrate agents without modifying the core: profiles + reusable runners.
- Expose consistent capabilities via native HTTP and protocol adapters.
- Keep isolation and hard limits (workspaces, timeouts, bounded streaming).

SAAR is not a model provider and not an agent framework. It orchestrates execution and normalizes behavior.

## Design philosophy

- Strict contracts: JSONL on STDOUT, fail fast, per-event limits.
- Clear separation: core (SAAR) vs profiles vs runners.
- Operational isolation: wrapper with PID namespace and access policies.
- Determinism: stop and delete are explicit; no implicit cleanup.

## Mental model

### Agent lifecycle

1) Create instance from a profile (`/sys/agents`).
2) Provisioning (if needed) and ready state.
3) Interactions (`/agents/:id/interact`).
4) Stop (terminates process, keeps workspace).
5) Delete (removes workspace and purges artifacts).

Workspaces persist while SAAR is running and are removed only on `DELETE /sys/agents/:instance_id`. Reusing the same `instance_id` reuses the workspace.

### Interaction modes

- Native HTTP (`/agents/:id/interact`).
- Protocol adapters (A2A, AG-UI) when enabled.

### Artifacts

- Runners write files inside the workspace and return references in `artifacts`.
- SAAR registers artifacts and serves them via `/artifacts/:id`.
- Dotfiles/dotdirs are ignored by default unless explicitly included in `artifact_config.include`.

## Profiles and runners

A profile declares how to run an agent and which capabilities it exposes. A runner is the script that executes the tool and emits JSONL events.

Minimal profile example (CLI runner):

```json
{
  "meta": {"id": "aider", "lifecycle": "transient"},
  "parameters": {
    "model": {"source": "config", "key": "params.model", "type": "string"}
  },
  "runner": {
    "type": "generic_uvx_unified",
    "tool_config": {"package": "aider-chat", "command": "aider", "python": "3.12"},
    "env_map": {"AIDER_MODEL": "openrouter/{{params.model}}"},
    "args": ["--message", "{{helpers.last_user_content}}"]
  },
  "interface": {"protocol": "runner", "capabilities": {"chat": {"input_schema": {"$ref": "std:chat"}}}}
}
```

See `RUNNERS_AND_AGENTS.md` and `docs/runner_protocol.md` for details.

## Quickstart

Start SAAR with a local config:

```bash
gleam run -m saar -- serve --port 8081 --config runtime/config.toml
```

Create an instance:

```bash
curl -sS -X POST "http://127.0.0.1:8081/sys/agents" \
  -H "Authorization: Bearer dev" \
  -H "content-type: application/json" \
  -d '{"profile_id":"aider","instance_id":"aider-ws-1"}'
```

Interact (sync):

```bash
curl -sS -X POST "http://127.0.0.1:8081/agents/aider-ws-1/interact" \
  -H "Authorization: Bearer dev" \
  -H "content-type: application/json" \
  -d '{"capability":"chat","inputs":{"messages":[{"role":"user","content":"Hello"}]}}'
```

## Essential configuration

- `profiles.sources`: profile/runner sources (dir or git).
- `profiles.git_cache_dir`: local git cache for sources of type git.
- `workspaces.directory`: base directory for instance workspaces.
- `limits.*`: time and size limits for safety and stability.

## Security and isolation

- Runners are launched through a wrapper with PID namespace isolation.
- Access policies are enforced by configuration (landlock).
- Artifacts are served by opaque ids, never by raw paths.

## Related docs

- `RUNNERS_AND_AGENTS.md`
- `INTEGRATION.md`
- `docs/protocols.md`
- `docs/runner_protocol.md`
- `docs/config.md`
