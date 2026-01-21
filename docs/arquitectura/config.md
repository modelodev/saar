# Configuración

Perfiles de agentes, resolución de parámetros y gestión de workspaces.

## Índice

1. [Perfiles](#1-perfiles) — Definición de agentes
2. [Parámetros](#2-parámetros) — Resolución de valores
3. [Workspaces](#3-workspaces) — Paths seguros

---

## 1. Perfiles

Un perfil JSON define completamente un agente.

### 1.1 Estructura

```json
{
  "meta": {
    "id": "aider",
    "lifecycle": "transient",
    "description": "AI pair programmer"
  },
  "parameters": {
    "api_key": {"source": "secret", "key": "OPENAI_API_KEY", "type": "string"},
    "model": {"source": "init", "key": "model", "default": "gpt-4", "type": "string"}
  },
  "runner": {
    "type": "generic_uvx",
    "tool_config": {"package": "aider-chat", "command": "aider"}
  },
  "interface": {
    "protocol": "runner",
    "capabilities": {
      "chat": {"input_schema": {"$ref": "std:chat"}, "streaming": false}
    }
  }
}
```

### 1.2 Meta

| Campo | Tipo | Requerido | Descripción |
|-------|------|-----------|-------------|
| `id` | string | ✅ | Identificador único |
| `name` | string | ❌ | Display name (default: `id`) |
| `lifecycle` | enum | ✅ | `transient` o `continuous` |
| `description` | string | ✅ | Descripción corta |

### 1.3 Parameters

| Source | Origen | Default permitido |
|--------|--------|-------------------|
| `fixed` | Valor embebido | Sí |
| `config` | `config.toml` | Sí |
| `secret` | Variable de entorno | **No** |
| `init` | Request de creación | Sí |

**Nota:** los defaults globales de agentes usan `source = "config"` con
`key = "params.<name>"` (ver §2.4).

```json
"parameters": {
  "api_key": {
    "source": "secret",
    "key": "OPENAI_API_KEY",
    "type": "string"
  },
  "model": {
    "source": "init",
    "key": "model",
    "default": "gpt-4",
    "type": "string"
  }
}
```

**Invariante:** `secret` nunca puede tener `default` (validado en decoder).

**Tipos:** `string`, `int`, `float`, `bool`

### 1.4 Runner

```json
"runner": {
  "type": "generic_uvx",
  "tool_config": {
    "package": "aider-chat",
    "command": "aider",
    "with_packages": ["openai"]
  },
  "env_map": {
    "OPENAI_API_KEY": "{{params.api_key}}"
  },
  "args": ["--model", "{{params.model}}"]
}
```

### 1.5 Interface

| Protocol | Uso |
|----------|-----|
| `runner` | Script CLI via port |
| `http` | Servidor HTTP persistente |

```json
  "interface": {
    "protocol": "http",
    "base_url": "http://{{runner.host}}:{{runner.port}}",
    "health_check": {
      "path": "/health",
      "method": "GET",
      "expect_statuses": [200]
    },
    "capabilities": {
      "chat": {
        "input_schema": {"$ref": "std:chat"},
        "method": "POST",
        "body": {
          "type": "json",
          "template": {
            "messages": { "$from": "/input/messages" }
          }
        },
        "streaming": true,
        "limits": {"call_timeout_ms": 60000}
      }
    }
  }
```

**Nota:** `capabilities` vive DENTRO de `interface`, no como campo top-level.

### 1.6 Fuentes de perfiles

```toml
# config.toml
[profiles]
sources = [
  {type = "dir", path = "./profiles"},
  {type = "git", url = "https://example.com/profiles.git", ref = "main"}
]
git_cache_dir = "./.saar/cache/git"
```

---

## 2. Parámetros

Módulo **puro** que convierte `Parameter` → `ConfigValue`.

### 2.1 Principios

- **Puro:** Sin IO. Las fuentes se inyectan como argumentos.
- **Fail-fast:** Acumula todos los errores, no para en el primero.
- **Único punto:** Solo `params.gleam` resuelve parámetros.
- **Actor no resuelve:** Recibe `ResolvedParams` ya resueltos.

### 2.2 API

```gleam
// NOTA: ResolvedParams está definido en tipos.md §8
// Es Dict(String, ResolvedValue) donde ResolvedValue distingue
// entre NormalValue (logueable) y SecretVal (NUNCA loguear).

/// Resuelve todos los parámetros de un perfil.
/// Los secretos se envuelven en SecretVal para prevenir logs accidentales.
pub fn resolve(
  parameters: Dict(String, Parameter),
  config_values: Dict(String, ConfigValue),
  env_lookup: fn(String) -> Result(String, Nil),
  init_params: Dict(String, ConfigValue),
) -> Result(ResolvedParams, List(ParamResolutionError))
```

### 2.3 Algoritmo

```
Para cada parámetro:
  1. Determinar source (fixed/config/secret/init)
  2. Buscar valor en fuente correspondiente
  3. Si no existe y hay default → usar default
  4. Si no existe y no hay default → acumular error
  5. Validar tipo del valor
```

### 2.4 Defaults globales (`[params]`)

SAAR permite definir defaults globales para parámetros de agentes en
`config.toml` usando la sección `[params]`. Para evitar colisiones con
configuración del sistema, los perfiles deben referenciar estos valores con el
prefijo `params.`.

```toml
[params]
model = "gpt-4o-mini"
embedding_model = "text-embedding-3-large"
openrouter_url = "https://openrouter.ai/api/v1"
```

Ejemplo en perfil:

```json
"parameters": {
  "llm_model": {"source": "config", "key": "params.model", "type": "string"},
  "embedding_model": {"source": "config", "key": "params.embedding_model", "type": "string"}
}
```

**Reglas:**
- Solo valores simples (string/int/float/bool/list).
- No se permiten secrets en `[params]`.
- Si falta una clave `params.*` y no hay default en el perfil → error.

### 2.5 Errores

```gleam
  pub type ParamResolutionError {
    MissingConfig(param_name: String, config_key: String)
    MissingSecret(param_name: String, env_key: String)
    MissingInitParam(param_name: String, init_key: String)
    TypeMismatch(param_name: String, expected: ValueType, got: ValueType)
  }
```

### 2.6 Flujo

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   sys.gleam     │     │   AgentActor    │     │     Bridge      │
│                 │     │                 │     │                 │
│  params.resolve │────►│ ResolvedParams  │────►│ ResolvedParams  │
│  (único punto)  │     │ (en AgentState) │     │ (para interp.)  │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

---

## 3. Workspaces

Directorios aislados para cada instancia de agente.

> **SSOT:** Los tipos `WorkspacePath` y `PathError` están definidos en `tipos.md` §6.
> Este documento describe el uso y la operación.

### 3.1 Principio

El workspace es el directorio donde un agente puede leer/escribir.
Cualquier path que un runner reporte debe estar **dentro** de este directorio.

**Amenaza:** Path traversal (`../../etc/passwd`).

**Solución:** Tipo opaco `WorkspacePath` (ver `tipos.md` §6).

### 3.2 API de Workspace

| Función | Descripción |
|---------|-------------|
| `workspace_path_validate(root, raw)` | Valida y construye `WorkspacePath` seguro |
| `workspace_path_to_string(path)` | Extrae string del `WorkspacePath` |
| `workspace_path_to_absolute(root, path)` | Construye path absoluto |
| `workspace_dir_name(instance_id)` | Genera nombre de directorio |
| `workspace_for_instance(base, id)` | Path completo del workspace |

### 3.3 Operaciones de Limpieza

> **Nota:** Estas funciones viven en `saar/workspace.gleam` (módulo de IO).
> Los tipos están en `tipos.md` pero las operaciones de filesystem están separadas.

```gleam
/// Elimina workspace de una instancia.
/// Se llama al destruir una instancia (cleanup determinista).
pub fn cleanup(workspace_path: String) -> Result(Nil, String)
```

### 3.4 Estructura

```
./workspaces/
├── workspace-inst-abc/
│   ├── outputs/
│   │   └── report.pdf
└── workspace-inst-xyz/
    └── ...
```

### 3.5 Ciclo de Vida

1. Crear instancia
   - `workspace_for_instance(base, id)` → crear directorio

2. Interacciones
   - Runner escribe en workspace
   - Artefactos validados con `workspace_path_validate()`

3. Eliminar instancia
   - `cleanup(workspace_path)` → elimina directorio

### 3.6 Retención (artefactos y logs)

- **Artefactos:** el `artifact_registry` mantiene una whitelist en memoria `ArtifactId → #(InstanceId, WorkspacePath, mime)` para servir `/artifacts/:artifact_id`. SAAR v0 no implementa TTL/GC automático: los artefactos se eliminan al hacer `/delete` (stop ≠ delete).
- **Logs:** buffer en memoria acotado por `log_buffer_bytes` (para SSE). SAAR v0 no persiste logs a disco.

### 3.6.1 Decisión v0: no hacer “sweep” de huérfanos por PID

SAAR v0 **no** implementa cleanup automático de workspaces “huérfanos” basado en PID/`ps`/señales del sistema operativo.
Esto reduce complejidad y evita comportamientos no portables (contenedores, PID reuse, permisos, OS distintos).

**Contrato v0:**
- Cleanup de workspaces es **determinista** y ocurre en `DELETE /sys/agents/:instance_id` (delete ≠ stop).
- La limpieza de instancias antiguas/no eliminadas es responsabilidad de capas superiores (SAM/ops tooling), usando listados de instancias y borrados explícitos.

### 3.7 Configuración en `config.toml` (runtime)

Defaults canonicos: `docs/plan/limits.toml` (tabla generada en `docs/plan/limits.md`).

| Clave | Descripción | Default recomendado |
|-------|-------------|---------------------|
| `server.host` / `server.port` | Bind HTTP del gateway. | `0.0.0.0` / `8080` |
| `auth.api_key` | API key (Bearer). | requerido (loader) |
| `profiles.sources` | Fuentes de perfiles/runners (dir/git). | `[{type="dir", path="."}]` |
| `profiles.git_cache_dir` | Cache de repos git. | `./.saar/cache/git` |
| `runners.python_bin` | Ejecutar scripts `.py`. | `python3` |
| `workspaces.directory` | Base de workspaces por instancia. | `./workspaces` |
| `limits.port_range_min` / `limits.port_range_max` | Rango para port pool (`managed_port`). | `9000` / `9999` |
| `limits.log_buffer_bytes` | Límite del buffer en memoria para SSE. | `1_048_576` (1MB) |
| `limits.max_stdout_bytes` | Límite duro de bytes de STDOUT JSONL por interacción (protección OOM). | `10_485_760` (10MB) |
| `limits.max_runner_event_bytes` | Límite duro por linea JSONL (runner/streaming). | `262_144` |
| `limits.max_request_body_bytes` | Límite duro del body que SAAR acepta en requests entrantes (Mist `read_body`). | `1_048_576` (1MB) |
| `limits.max_http_response_bytes` | Límite duro del body que SAAR acepta desde agentes HTTP non-streaming. | `10_485_760` (10MB) |
| `limits.max_file_fetch_bytes` | Límite duro para descargas al construir multipart desde `FileRef` (SAAR → agente). | `52_428_800` (50MB) |
| `limits.task_retention_ms` | Retención de tareas diferidas en TaskStore. | `604_800_000` (7d) |
| `limits.max_tasks` | Máximo de tareas diferidas almacenadas. | `10_000` |
| `limits.max_task_result_bytes` | Límite de bytes para el resultado almacenado en tareas. | `262_144` |
| `limits.shutdown_timeout_ms` | Tiempo de gracia para SIGTERM→SIGKILL en stop/delete. | `10_000` |
| `limits.sse_keep_alive_interval_ms` | Intervalo de keep-alive SSE (comentarios) para conexiones largas. `0` desactiva. | `15_000` |
| `log_stream.*` | Streaming de logs (batching; best-effort; sin buffers infinitos). | ver defaults |
| `interaction_stream.*` | Streaming de interacción (batching + ack hacia `saar/streams/sink.StreamSink` + timeout; sin buffers infinitos). | ver defaults |
| `network.managed_port_host` | Host inyectado en runners HTTP (managed_port). | `127.0.0.1` |

#### 3.7.1 Port pool (`managed_port`) — semántica v0

- SAAR mantiene un **port pool en memoria** basado en el rango `[limits.port_range_min, limits.port_range_max]`.
- El helper puro es *best-effort* respecto al SO; para garantía real se usa `allocate_checked` con bind-check.
- En agentes `continuous` con `network_mode=managed_port`, el puerto se **reserva durante provisioning** y se expone en `AgentStatusView.assigned_port`.
- **Release (v0):** el puerto reservado se libera en `stop`, `delete`, `rollback` y `terminate` (idempotente).
- **Exhaustión:** si no hay puertos libres, el provisioning falla con un error estable `port_pool_exhausted` y la instancia transita a `Failed` (visible en status). La mitigación es ampliar el rango o ejecutar deletes de instancias antiguas/paradas.
- **Puerto ocupado:** si el bind-check detecta que el puerto está en uso, el provisioning falla con `port_in_use` (fail-fast, sin reintentos).
- **Bind-check fallido:** si el bind-check falla por un error real del sistema, el provisioning falla con `port_bind_failed`.
- **No persistencia (v0):** el pool no se persiste entre reinicios. Aunque hay bind-check, se recomienda que el rango esté dedicado a SAAR.

#### Ejemplo `config.toml`

```toml
[server]
host = "0.0.0.0"
port = 8080

[auth]
api_key = "${SAAR_API_KEY}"

[limits]
call_timeout_ms = 30000
status_timeout_ms = 5000
registry_timeout_ms = 5000
health_check_timeout_ms = 10000
log_buffer_bytes = 1048576
max_stdout_bytes = 10485760
max_runner_event_bytes = 262144
max_request_body_bytes = 1048576
max_http_response_bytes = 10485760
max_file_fetch_bytes = 52428800
task_retention_ms = 604800000
max_tasks = 10000
max_task_result_bytes = 262144
port_range_min = 9000
port_range_max = 9999
shutdown_timeout_ms = 10000
sse_keep_alive_interval_ms = 15000

[log_stream]
batch_byte_size = 4096
flush_interval_ms = 50

[interaction_stream]
batch_byte_size = 4096
flush_interval_ms = 25
push_timeout_ms = 250

[profiles]
sources = [
  {type = "dir", path = "./profiles"}
]
git_cache_dir = "./.saar/cache/git"

[runners]
python_bin = "python3"

[workspaces]
directory = "./workspaces"

[network]
managed_port_host = "127.0.0.1"
```
