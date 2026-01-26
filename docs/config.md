# Configuration

This document describes profile definitions, parameter resolution, and workspace handling, plus the essential `config.toml` keys.

## 1. Profiles

A JSON profile fully describes an agent: metadata, parameters, runner, and capabilities.

### 1.1 Structure (minimal)

```json
{
  "meta": {
    "id": "aider",
    "lifecycle": "transient",
    "description": "AI pair programmer"
  },
  "parameters": {
    "api_key": {"source": "secret", "key": "OPENAI_API_KEY", "type": "string"},
    "model": {"source": "config", "key": "params.model", "type": "string"}
  },
  "runner": {
    "type": "generic_uvx_unified",
    "mode": "auto",
    "tool_config": {"package": "aider-chat", "command": "aider", "python": "3.12"}
  },
  "interface": {
    "protocol": "runner",
    "capabilities": {
      "chat": {"input_schema": {"$ref": "std:chat"}, "streaming": false}
    }
  }
}
```

Key fields:
- `meta.id` is the profile identifier used by `/sys/agents`.
- `parameters` define values resolved at runtime (from secrets, config, or fixed values).
- `runner` defines how SAAR launches the tool and collects artifacts.
- `interface.capabilities` expose operations to clients.

## 2. Parameters

Parameters are resolved by SAAR before invoking a runner:

- `source = "secret"`: read from the environment or secret store.
- `source = "config"`: read from `config.toml` (for example `params.model`).
- `source = "fixed"`: constant value.

Resolved values are available in templates like `{{params.model}}` and helpers such as `{{helpers.last_user_content}}`.

## 3. Workspaces

Each instance has a dedicated workspace directory where the runner can read and write files.

Rules:
- Paths reported by a runner must be **inside** the workspace.
- SAAR validates paths before registering artifacts.
- Dotfiles/dotdirs are ignored by default when collecting artifacts unless explicitly included in `artifact_config.include`.

Lifecycle:
1) Workspace created on instance creation.
2) Workspace persists during interactions.
3) Workspace removed on `DELETE /sys/agents/:instance_id`.

## 4. `config.toml` essentials

| Key | Meaning | Default |
| --- | --- | --- |
| `server.host` / `server.port` | Gateway bind | `0.0.0.0` / `8080` |
| `auth.api_key` | API key (Bearer) | required |
| `profiles.sources` | Profile/runner sources (dir or git) | `[{type="dir", path="."}]` |
| `profiles.git_cache_dir` | Local git cache for `sources` of type `git` | `./.saar/cache/git` |
| `runners.python_bin` | Python interpreter for `.py` runners | `python3` |
| `workspaces.directory` | Base directory for workspaces | `./workspaces` |
| `limits.max_runner_event_bytes` | Max JSONL line size | `262144` |
| `limits.max_stdout_bytes` | Max total stdout bytes per interaction | `10485760` |
| `limits.call_timeout_ms` | Max interaction time | `120000` |

See `docs/plan/limits.md` for the full limits table.
