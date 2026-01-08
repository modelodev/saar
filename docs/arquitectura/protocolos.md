# Protocolos Wire

Formatos de comunicación entre SAD y sistemas externos.

## Índice

0. [Adaptadores](#0-adaptadores) — Principios (A2A/AG-UI/A2UI)
1. [Runner Contract](#1-runner-contract) — SAD ↔ scripts
2. [A2A Protocol](#2-a2a-protocol) — Interoperabilidad entre agentes
3. [AG-UI Protocol](#3-ag-ui-protocol) — Streaming a frontends
4. [Perfil JSON](#4-perfil-json) — Definición de agentes

---

## 0. Adaptadores

En SAD, **A2A**, **AG-UI** y **A2UI** se implementan como *adaptadores de protocolo* (wire ↔ core):

- Traducen requests/responses/streams al modelo interno (`AgentRequest`, `InteractionResult`, `StreamEvent`).
- No ejecutan provisioning, no resuelven parámetros, no deciden lifecycle, no cancelan por desconexión.
- El **SSE de logs** (`GET /sys/agents/:instance_id/logs/stream`) es un flujo distinto; A2A/AG-UI solo afectan al **streaming de interacción**.

**Principio (v0):** cortar una conexión SSE (AG-UI, A2A o A2UI) **no** cancela ni detiene al agente; solo detiene la entrega al cliente. La ejecución sigue hasta completarse o timeout, salvo orden superior explícita.

**Normativa v0 (cierre SSE):**
- En streaming de interacción (AG-UI/A2A), SAD MUST emitir un **evento terminal explícito** (éxito o error) y luego **cerrar la conexión** SSE.
- En A2UI “puro” (JSONL de mensajes A2UI), el protocolo no define un evento terminal. SAD considera terminal el **cierre de la conexión**; si se requiere un terminal explícito y error tipado, usar A2UI via A2A (ver §2.13) donde el envelope `task_status` sí lo expresa.
- Los clientes MUST tolerar líneas SSE de comentario (`: ...`) usadas como keep-alive.

### 0.3 A2UI (Agent to UI) — UI declarativa por streaming

SAD v0 decide soportar **A2UI**: https://a2ui.org/introduction/what-is-a2ui/

**Qué es:** un protocolo de UI declarativa donde el agente envía un stream JSONL de mensajes como `surfaceUpdate`/`dataModelUpdate`/`beginRendering`/`deleteSurface`. El cliente renderiza con su catálogo de componentes (nativo), sin ejecutar código arbitrario del agente.

**Cómo encaja en SAD:** se implementa como adapter wire (igual que A2A/AG-UI). SAD no “interpreta” componentes; solo transporta mensajes A2UI de forma segura (SSE/JSONL) y deja la renderización al cliente.

**Transporte en SAD (v0):**
- **Vía A2A (recomendado):** A2UI como `DataPart` con `mimeType="application/json+a2ui"` + activación por `X-A2A-Extensions` (ver §2.13). Beneficio: lifecycle/errores tipados vía `task_status`.
- **Vía endpoint nativo (`/agents/.../interact`):** streaming SSE donde cada `data:` es un mensaje A2UI (sin envelope A2A). Selección por header SAD-specific (ver `gateway.md` §5.2). Beneficio: no requiere A2A; trade-off: el final/errores se observan por cierre de conexión.

### 0.1 Errores (RFC 7807) — tabla canónica

SAD usa RFC 7807 (Problem Details) tanto en endpoints nativos como A2A. La estructura base:

```json
{
  "type": "https://sad/errors/invalid-request",
  "status": 400,
  "title": "Bad Request",
  "detail": "Missing required field: capability",
  "instance": "/agents/inst-123/interact",
  "extensions": {
    "kind": "bad_request",
    "trace_id": "trace-abc123"
  }
}
```

Tabla canónica `ErrorKind → Problem Details`:

| ErrorKind core | HTTP | `title` | `type` (nativo) | `type` (A2A) |
|---------------|------|---------|------------------|--------------|
| `BadRequest` | 400 | `Bad Request` | `https://sad/errors/invalid-request` | `https://a2a-protocol.org/errors/invalid-request` |
| `AgentError` | 422 | `Unprocessable Entity` | `https://sad/errors/upstream-error` | `https://a2a-protocol.org/errors/upstream-error` |
| `InfraError` | 500 | `Internal Server Error` | `https://sad/errors/infra-error` | `https://a2a-protocol.org/errors/infra-error` |

**Reglas:**
- `extensions.kind` usa snake_case: `bad_request`, `agent_error`, `infra_error`.
- `extensions.trace_id` siempre presente.
- Nunca incluir secretos ni rutas del filesystem en `detail`.
- Si el agente está Busy, SAD responde con `AgentError` (422) y `detail: "Agent is busy"` en nativo y A2A.

### 0.2 Respuesta síncrona (nativo `POST /agents/:instance_id/interact`) — exacta

Cuando la capability tiene `streaming: false`, el endpoint nativo devuelve JSON (no SSE).

```json
{
  "status": "success",
  "data": {
    "content": "Respuesta final.",
    "metadata": {}
  },
  "artifacts": [
    {
      "name": "report.pdf",
      "url": "/artifacts/01J...",
      "mime": "application/pdf"
    }
  ],
  "trace_id": "trace-abc123"
}
```

**Mapeo desde `InteractionResult`:**
- `InteractionResult.trace_id` → `trace_id`
- `InteractionResult.data.content` → `data.content`
- `InteractionResult.data.metadata` → `data.metadata`
- `InteractionResult.artifacts[]` → `artifacts[]` (URLs públicas de SAD, no paths)

## 1. Runner Contract

Contrato obligatorio para scripts runner que interactúen con SAD.

### 1.1 Modos de invocación

| Modo | Invocación | STDIN | STDOUT (capturado por SAD) |
|------|------------|-------|--------|
| Provision | `./runner --provision` | `SAD_INPUT_JSON` | Stream de eventos JSONL; final `t="provision_result"` |
| Execution (transient) | `./runner` | `SAD_INPUT_JSON` | Stream de eventos JSONL; final `t="result"` |
| Start (continuous) | `./runner` | `SAD_INPUT_JSON` | Stream de eventos JSONL (normalmente `t="log"`). No hay `t="result"` salvo salida del proceso |
| Stop | En el core, SAD cierra stdin/envía la línea `{"t":"stop"}` (terminada en `\n`) al wrapper y espera `shutdown_timeout_ms`; el wrapper aplica SIGTERM→timeout→SIGKILL al runner | - | - |
| Status (continuous) | Health-check HTTP definido en perfil | - | - |

**Nota wrapper (stdin de control):** SAD escribe al wrapper líneas JSONL de control. La primera es `{"t":"input","payload":<SAD_INPUT_JSON>}` y el wrapper reenvía `payload` al runner y cierra su stdin. Las líneas siguientes pueden ser `{"t":"stop"}` (o futuras). **Sin compatibilidad v0:** no se acepta el formato previo de input “implícito” (JSON único sin `t`).

### 1.2 Reglas

1. **JSON in / JSON out (por eventos)** — STDIN del runner recibe `SAD_INPUT_JSON` (reenviado por el wrapper); STDOUT es un stream JSONL de eventos tipados (incluye `result`)
2. **No depender de STDERR** — STDERR está fuera de contrato; SAD no asume captura ni separación
3. **Exit codes** — `0` para success, `1` para error
4. **Idempotencia** — `--provision` puede ejecutarse múltiples veces
5. **Stop** — Wrapper debe salir tras `stop`/EOF propagando SIGTERM→SIGKILL a la subtree; SAD no envía señales directas.
6. **Artifacts first-class** — Paths validados (`WorkspacePath`) → UUID público
7. **Streaming y logs** — Eventos por STDOUT (JSONL); sin buffers infinitos
8. **Interpolación** — SAD resuelve plantillas `{{...}}` antes de invocar runners; el runner recibe `args/env_map` ya resueltos.

### 1.3 SAD_INPUT_JSON

```json
{
  "meta": {
    "profile_id": "aider",
    "instance_id": "inst-123",
    "trace_id": "trace-abc"
  },
  "params": {
    "model": "gpt-4",
    "api_key": "sk-..."
  },
  "input": {
    "messages": [{"role": "user", "content": "Hello"}]
  },
  "context": {
    "capability_id": "chat",
    "trace_id": "trace-abc"
  },
  "helpers": {
    "last_user_content": "Hello",
    "last_user_files": []
  },
  "runner_def": {
    "type": "generic_uvx",
    "tool_config": {"package": "aider-chat", "command": "aider"}
  }
}
```

**Nota:** `runner.host`/`runner.port` **no** se incluyen en `SAD_INPUT_JSON`. Se inyectan via env (`SAD_HOST`/`SAD_PORT`)
y por interpolacion strict en `args/env_map` cuando aplica `managed_port`.

### 1.4 RunnerResponse

`RunnerResponse` es el payload del resultado final. En el stream JSONL se emite como un objeto que añade el discriminante `t`:

```json
{"t":"result","status":"success","data":{...},"artifacts":[],"error":null}
```

Schema del payload (`RunnerResponse`):

```json
{
  "status": "success",
  "data": {
    "messages": [{"role": "assistant", "content": "Hi!"}]
  },
  "artifacts": [
    {"name": "report.pdf", "path": "outputs/report.pdf", "mime": "application/pdf"}
  ],
  "error": null
}
```

### 1.5 Schemas de entrada

| Schema | Formato input | Helpers |
|--------|---------------|---------|
| `std:chat` | `{"messages": [...]}` | `last_user_content` |
| `std:files` | `{"files": [...]}` | `last_user_files` |
| extended | Chat + campos extra | `last_user_content` |

**Wire format en perfiles** (3 formas equivalentes):

```json
// 1. String shorthand (más simple)
"input_schema": "std:chat"

// 2. Objeto con $ref (más explícito)
"input_schema": {"$ref": "std:chat"}

// 3. Extended con campos extra
"input_schema": {
  "base": "std:chat",
  "extra_fields": {
    "mode": {"type": "string", "enum": ["a", "b"], "default": "a"}
  }
}
```

### 1.6 Tipos de error

```gleam
pub type ErrorKind {
  AgentError    // Error del agente/modelo
  InfraError    // Error de infraestructura
  BadRequest    // Input inválido
}
```

### 1.7 Stop / Status / Events

- **Stop:** SAD envía orden de stop (mensaje/EOF) al wrapper; el wrapper aplica SIGTERM y, si tras `shutdown_timeout_ms` sigue vivo, SIGKILL a la subtree. Los runners solo deben manejar las señales.
- **Status (continuous):** opcional health-check HTTP configurado en el perfil (`health_check`). Si falla, SAD considera el server caído y limpia estado tras stop.
- **Eventos/Logs (STDOUT JSONL):** SAD consume la salida capturada como un único canal (`open_port` no separa stdout/stderr con `use_stdio`). Para `streaming: true`, el runner emite eventos `t="chunk"` incrementales por STDOUT, además de `t="log"` opcionales. El resultado final siempre llega como `t="result"` (con forma `RunnerResponse`). El gateway los reemite por SSE vía un `sad/streams/sink.StreamSink` por request (batching + límites; sin buffers infinitos).

### 1.8 Streaming HTTP (continuous) — Contrato SSE (v0)

Cuando una capability HTTP (`HttpCapability.streaming: true`) se invoca en un agente continuous, SAD abre una conexión SSE
contra el agente. El contrato v0 es único y mínimo:

- **Objetivo (v0):** preservar la experiencia de streaming. Si el agente emite eventos durante una interacción larga, SAD los reenvía al cliente progresivamente.
- **Principio (v0):** SSE es **transporte**. SAD no “entiende” protocolos específicos (OpenAI, etc.); solo aplica framing, backpressure, límites y cancelación (y, cuando aplica, un envelope mínimo estable) para retransmitir el stream de forma segura.

- El agente responde con `Content-Type: text/event-stream`.
- En v0, una capability con `streaming: true` usa el **mismo request** definido por la capability HTTP (método + headers + body). Para chat streaming lo normal es `POST` con body JSON y respuesta `text/event-stream`. Si el método es `GET`, el body debe ser `None`.
- Cada evento SSE incluye `data: <json>` donde `<json>` es **un objeto** con la misma forma que el contrato de runners:
  - `{"t":"log","message":"...","level":"info"}` (opcional)
  - `{"t":"chunk","delta":"..."}` (opcional)
  - `{"t":"result", ...RunnerResponse...}` (obligatorio; exactamente uno)
- SAD parsea `data` como JSON y reusa el mismo decoder de eventos que en `STDOUT JSONL`.
- Fin de interacción: el agente debe emitir `t="result"` y cerrar la conexión; SAD finaliza la interacción con `InteractionDone(...)`.
- Si la conexión se cierra sin `t="result"`, SAD devuelve `InfraError` (fail-fast).

---

## 2. A2A Protocol

Protocolo [Agent2Agent](https://a2a-protocol.org) para interoperabilidad entre agentes.

### 2.1 Arquitectura

```
Frontend (A2A puro) → SAD Gateway → a2a.gleam → Core SAD → Runner
```

SAD expone una **facade A2A**: traduce internamente a su modelo propio.

### 2.1.1 Robustez de parsing (v0)

- **Forward-compatible:** campos JSON desconocidos se ignoran (no rompen parsing).
- **Parts desconocidos:** se ignoran (el mensaje sigue procesándose con los parts soportados).
- **Features explícitamente no soportadas:** si llega un `part` reconocido pero en forma no soportada (p.ej. `file.bytes`), se devuelve `400 BadRequest` para evitar pérdida silenciosa de datos.

### 2.2 Agent Card

El Agent Card se genera desde el `Profile` **y la instancia** (`instance_id`), sin tipo intermedio:

```gleam
// sad/a2a.gleam
pub fn agent_card_from_instance(profile: Profile, instance_id: InstanceId, base_url: String) -> Json
```

**Wire format A2A** (servido en `/instances/:instance_id/.well-known/agent-card.json`):

```json
{
  "name": "aider",
  "description": "AI pair programmer",
  "url": "http://localhost:8080/instances/inst-123/a2a",
  "version": "1.0.0",
  "protocolVersion": "1.0",
  "capabilities": {
    "streaming": true,
    "pushNotifications": false
  },
  "skills": [
    {
      "id": "chat",
      "name": "Chat",
      "description": "General conversation"
    }
  ]
}
```

**Mapeo Profile → Agent Card:**

| Profile | Agent Card |
|---------|------------|
| `meta.name` (o `meta.id` si ausente) | `name` |
| `meta.description` | `description` |
| `base_url + "/instances/<instance_id>/a2a"` | `url` |
| `"1.0.0"` (constante, SAD no versiona agentes) | `version` |
| `"1.0"` (constante) | `protocolVersion` |
| capabilities de interface | `capabilities.streaming` |
| `false` (SAD no soporta push) | `capabilities.pushNotifications` |
| capabilities como lista | `skills` |

### 2.3 Message Format

**Nota:** A2A v1.0 usa el nombre del campo como discriminador de Part, no un campo `type`.

```json
{
  "message": {
    "messageId": "msg-123",
    "role": "user",
    "parts": [
      {"text": "Hello"},
      {"file": {"uri": "https://example.com/doc.pdf", "mediaType": "application/pdf", "name": "doc.pdf"}}
    ]
  },
  "context": {
    "contextId": "conv-789"
  }
}
```

### 2.3.1 Roles (v0)

SAD acepta `role` en:

- `user`
- `assistant`

Otros roles (p.ej. `system`, `tool`) se rechazan como `400 BadRequest` (v0).

### 2.3.2 TextPart (v0)

Si un mensaje contiene múltiples `TextPart`, SAD los concatena en orden para producir un único `ChatMessage(content=...)`. Esto preserva la semántica del mensaje y simplifica el core.

### 2.3.3 FilePart (v0)

SAD soporta solo `file.uri` (no soporta `file.bytes` en v0).
 
- Si llega `file.bytes`: `400 BadRequest` indicando que debe usarse `file.uri`.
- `file.mediaType` es opcional; si falta se usa `"application/octet-stream"` como valor por defecto.

**Wire:** en A2A, SAD interpreta:
- `file.uri` como URL
- `file.mediaType` como mime (opcional)
- `file.name` como nombre (opcional; si falta se puede derivar del URI)

#### Aclaración: `file.bytes` (A2A) vs `multipart` (HTTP)

- `file.bytes` es **una representación inline** dentro del payload A2A. SAD v0 **no** la acepta.
- `multipart` en SAD se refiere a **SAD construyendo una request HTTP** hacia un agente `http` (ver §4.5). No implica aceptar bytes inline en A2A.

Si un cliente tiene un fichero local (sin URL pública), el flujo canónico es:
subirlo a un storage accesible por SAD/runner y enviar `file.uri`.

### 2.4 Mapeo A2A → SAD

| A2A | SAD | Notas |
|-----|-----|-------|
| `Message.parts[TextPart]` | `PayloadChat.messages` | |
| `Message.parts[FilePart]` | `PayloadFiles.files` | |
| `Message.parts` (mixed) | `PayloadMixed` | |
| `context.contextId` | Pass-through | Si ausente, SAD genera uuid.v7 |

### 2.5 Mapeo SAD → A2A (Respuesta)

| SAD | A2A | Notas |
|-----|-----|-------|
| `trace_id` | `taskId` | Requerido para streaming |
| `context.contextId` | `contextId` | Devuelto tal cual o generado |

**Nota:** SAD implementa A2A en modo Message con Task lifecycle simulado:
- Al recibir request: `state: "working"`
- Al terminar: `state: "completed"`

No hay persistencia de estado de Task; el adapter simula el lifecycle.

### 2.6 Endpoints

| Método | Path | Descripción |
|--------|------|-------------|
| `GET` | `/instances/:instance_id/.well-known/agent-card.json` | Agent Card |
| `POST` | `/instances/:instance_id/a2a/message:send` | Mensaje síncrono |
| `POST` | `/instances/:instance_id/a2a/message:stream` | Mensaje streaming |

### 2.7 Streaming SSE

```
event: task_status
data: {"taskId": "trace-abc-123", "contextId": "conv-789", "status": {"state": "working"}}

event: message
data: {"role": "assistant", "parts": [{"text": "Hi there!"}]}

event: task_status
data: {"taskId": "trace-abc-123", "contextId": "conv-789", "status": {"state": "completed"}}
```

**Flujo:**
1. Cliente envía mensaje (puede incluir `contextId` o no)
2. SAD genera `trace_id` → se usa como `taskId` en respuesta
3. Si `contextId` ausente, SAD genera uno nuevo y lo devuelve
4. Cliente recibe ambos IDs para correlación y agrupación

**Nota:** Este SSE es **streaming de interacción** (respuesta), no el SSE de logs de instancia (`/sys/.../logs/stream`).

#### 2.7.2 Payloads de éxito (A2A SSE) — exactos

Eventos mínimos que SAD garantiza en v0:

**(1) Inicio**

```text
event: task_status
data: {
  "taskId": "trace-abc-123",
  "contextId": "conv-789",
  "status": { "state": "working" }
}
```

**(2) Mensaje incremental**

```text
event: message
data: {
  "role": "assistant",
  "parts": [{ "text": "partial chunk" }]
}
```

**(3) Fin**

```text
event: task_status
data: {
  "taskId": "trace-abc-123",
  "contextId": "conv-789",
  "status": { "state": "completed" },
  "artifacts": [
    {
      "name": "report.pdf",
      "uri": "http://sad.local/artifacts/01J...",
      "mediaType": "application/pdf"
    }
  ]
}
```

Reglas:
- `taskId == trace_id` (correlación).
- `contextId` es pass-through o generado.
- `message.parts` en v0 por defecto solo incluye `{ "text": "..." }` (sin tool calls ni multimedia). Para A2UI, ver §2.13.
- `artifacts` es 0..N y se incluye en el evento final si existen.

#### 2.7.3 Payload de error (A2A SSE) — exacto

En caso de error durante streaming, SAD emite un `task_status` final con `state="failed"` y un objeto `error` mínimo.

```text
event: task_status
data: {
  "taskId": "trace-abc-123",
  "contextId": "conv-789",
  "status": {
    "state": "failed",
    "error": {
      "kind": "agent_error",
      "message": "Upstream rejected request",
      "trace_id": "trace-abc-123"
    }
  }
}
```

Reglas:
- `error.kind` ∈ {`bad_request`, `agent_error`, `infra_error`} (derivado de `ErrorKind` del core).
- `error.message` es safe-to-log (sin secretos ni rutas del filesystem).
- `error.trace_id` siempre coincide con `taskId`.

### 2.8 Invariantes de streaming (A2A)

- `task_status(state="working")` se emite una vez al inicio.
- Se emiten 0..N eventos `message` (orden preservado).
- Se emite exactamente un final:
  - `task_status(state="completed")`, o
  - `task_status(state="failed")`.

### 2.9 IDs y trazabilidad (A2A)

| Core | A2A | Regla |
|------|-----|-------|
| `trace_id` | `taskId` | Siempre presente; SAD lo genera si falta en request |
| `context.extra.context_id` (o generado) | `contextId` | Pass-through si viene; si no, SAD genera |

### 2.10 Mapeo de errores (A2A)

En endpoints no-streaming, SAD responde con RFC 7807:

| ErrorKind core | HTTP | `type` sugerido |
|---------------|------|-----------------|
| `BadRequest` | 400 | `https://a2a-protocol.org/errors/invalid-request` |
| `AgentError` | 422 | `https://a2a-protocol.org/errors/upstream-error` |
| `InfraError` | 500 | `https://a2a-protocol.org/errors/infra-error` |

En streaming, los errores se expresan como `task_status(state="failed")` (y el stream termina). El payload puede incluir `error.kind`, `error.message` y `trace_id` (sin secretos).

Cancelación por `stop/delete` se expresa como `task_status(state="failed")` con `error.kind="agent_error"` y `error.message="cancelled"`.

### 2.11 Backpressure (A2A SSE)

La entrega SSE aplica batching y límites para evitar OOM.
Esto es transparente para el cliente A2A: SAD puede agrupar chunks, pero **no** reordena eventos.

### 2.12 Respuesta síncrona (A2A `message:send`) — exacta

`POST /instances/:instance_id/a2a/message:send` devuelve un objeto `result` con:
- `id` (igual a `trace_id` de SAD),
- `contextId` (pass-through o generado),
- `status.state`,
- `message` final del assistant,
- `artifacts` (si existen).

```json
{
  "result": {
    "id": "trace-abc-789",
    "contextId": "conv-456",
    "status": { "state": "completed" },
    "message": {
      "role": "assistant",
      "parts": [{ "text": "Respuesta final." }]
    },
    "artifacts": [
      {
        "name": "report.pdf",
        "uri": "http://sad.local/artifacts/01J...",
        "mediaType": "application/pdf"
      }
    ]
  }
}
```

**Mapeo desde `InteractionResult`:**
- `InteractionResult.trace_id` → `result.id`
- `contextId` → `result.contextId`
- `InteractionResult.data.content` → `result.message.parts[TextPart]`
- `InteractionResult.artifacts[]` → `result.artifacts[]` como `uri` (URL pública de SAD) + `name` + `mediaType`

---

### 2.13 Extensión A2UI (v0.8) — soporte “aware”

SAD v0 soporta A2UI como **wire/adapter** (no como motor de UI).

- Qué es A2UI: `https://a2ui.org/introduction/what-is-a2ui/`
- URI de extensión A2UI sobre A2A: `https://a2ui.org/a2a-extension/a2ui/v0.8`

**Objetivo v0:** permitir que una capa superior opere UI agent-driven transportando mensajes A2UI via A2A, manteniendo a SAD agnóstico del catálogo y del render.

#### Activación (A2A)

El cliente activa A2UI mediante el mecanismo estándar de extensiones A2A:
- Header HTTP `X-A2A-Extensions: https://a2ui.org/a2a-extension/a2ui/v0.8`

Si no se activa, SAD opera en modo A2A “texto” (TextPart) como en §2.7/§2.12.

#### Encoding (A2A `DataPart`)

Los mensajes A2UI viajan como un `DataPart` A2A con:
- `metadata.mimeType = "application/json+a2ui"`
- `data = <objeto A2UI>` (exactamente una de: `beginRendering`, `surfaceUpdate`, `dataModelUpdate`, `deleteSurface`)

SAD **no** interpreta componentes, estilos, bindings ni descarga catálogos; solo transporta y aplica límites.

#### Respuesta streaming (A2A SSE + A2UI)

En `POST /instances/:instance_id/a2a/message:stream` con extensión activada, el SSE sigue siendo A2A (`task_status`/`message`), pero `message.parts` contiene `DataPart` A2UI:

```text
event: message
data: {
  "role": "assistant",
  "parts": [
    {
      "data": { "surfaceUpdate": { "...": "..." } },
      "metadata": { "mimeType": "application/json+a2ui" }
    }
  ]
}
```

El renderer consume cada `DataPart.data` como una línea JSONL A2UI.

#### Eventos de UI (client → agent)

Los eventos `userAction` (y `error`) se envían como `DataPart` con `mimeType="application/json+a2ui"` en `POST /instances/:instance_id/a2a/message:send` (o `message:stream` si se requiere streaming de respuesta).

**Nota (modelo v0):** SAD no mantiene estado de “surface/session”. La correlación se hace con `contextId` y los IDs de A2UI (`surfaceId`, component ids). Una capa superior puede implementar la interacción enviando sucesivas requests A2A con `userAction` y recibiendo nuevas actualizaciones A2UI.

#### Validación mínima (v0)

SAD valida únicamente:
- `metadata.mimeType == "application/json+a2ui"`.
- `data` es un objeto JSON con **exactamente una** key top-level, y esa key ∈ {`beginRendering`, `surfaceUpdate`, `dataModelUpdate`, `deleteSurface`}.

El resto (catálogo, propiedades, tipos) es responsabilidad del agente y del renderer.

## 3. AG-UI Protocol

Protocolo [AG-UI](https://github.com/ag-ui-protocol/ag-ui) para streaming a frontends.

### 3.1 Alcance de implementación

**SAD v0 implementa solo streaming de texto.** AG-UI define más eventos que no soportamos aún:

| Evento AG-UI | SAD v0 | Notas |
|--------------|--------|-------|
| `RUN_STARTED` | ✅ | |
| `RUN_FINISHED` | ✅ | |
| `RUN_ERROR` | ✅ | |
| `TEXT_MESSAGE_START` | ✅ | |
| `TEXT_MESSAGE_CONTENT` | ✅ | |
| `TEXT_MESSAGE_END` | ✅ | |
| `TOOL_CALL_START` | ❌ | Futuro |
| `TOOL_CALL_END` | ❌ | Futuro |
| `STATE_SNAPSHOT` | ❌ | Futuro |
| `STATE_DELTA` | ❌ | Futuro |
| `MESSAGES_SNAPSHOT` | ❌ | Futuro |
| `RAW` | ❌ | Futuro |

### 3.2 Arquitectura

```
Core SAD (StreamEvent) → agui.gleam → Gateway SSE → Frontend
```

El adapter `agui.gleam` traduce los 4 eventos genéricos de SAD a los 6 eventos AG-UI soportados.

### 3.3 Mapeo SAD → AG-UI

| SAD StreamEvent | AG-UI Events |
|-----------------|--------------|
| `StreamStarted` | `RUN_STARTED` |
| `ContentChunk` (fase `BeforeFirstChunk`) | `TEXT_MESSAGE_START` + `TEXT_MESSAGE_CONTENT` |
| `ContentChunk` (fase `InMessage`) | `TEXT_MESSAGE_CONTENT` |
| `StreamFinished` | `TEXT_MESSAGE_END` + `RUN_FINISHED` |
| `StreamError` | `RUN_ERROR` |

**Nota:** El `message_id` lo genera el adapter AG-UI (ver `StreamPhase` en tipos.md).

### 3.4 Formato SSE

```
data: {"type": "RUN_STARTED", "threadId": "trace-abc", "runId": "trace-abc"}

data: {"type": "TEXT_MESSAGE_START", "messageId": "msg-1", "role": "assistant"}

data: {"type": "TEXT_MESSAGE_CONTENT", "messageId": "msg-1", "delta": "Hello"}

data: {"type": "TEXT_MESSAGE_CONTENT", "messageId": "msg-1", "delta": " world"}

data: {"type": "TEXT_MESSAGE_END", "messageId": "msg-1"}

data: {"type": "RUN_FINISHED", "threadId": "trace-abc", "runId": "trace-abc"}
```

#### 3.4.1 Payloads de éxito (AG-UI SSE) — exactos

Eventos mínimos que SAD garantiza en v0:

**(1) Inicio**

```text
data: { "type": "RUN_STARTED", "threadId": "trace-abc", "runId": "trace-abc" }
```

**(2) Mensaje de texto (un mensaje)**

```text
data: { "type": "TEXT_MESSAGE_START", "messageId": "msg-1", "role": "assistant" }
data: { "type": "TEXT_MESSAGE_CONTENT", "messageId": "msg-1", "delta": "partial chunk" }
data: { "type": "TEXT_MESSAGE_END", "messageId": "msg-1" }
```

**(3) Fin**

```text
data: {
  "type": "RUN_FINISHED",
  "threadId": "trace-abc",
  "runId": "trace-abc",
  "artifacts": [
    { "name": "report.pdf", "url": "/artifacts/01J...", "mime": "application/pdf" }
  ]
}
```

Reglas:
- `runId == threadId == trace_id`.
- `messageId` lo genera el adapter cuando empieza el primer chunk (ver `StreamPhase`).

#### 3.4.2 Payload de error (AG-UI SSE) — exacto

En caso de error durante streaming, SAD emite exactamente un `RUN_ERROR` y termina el stream.

```text
data: {
  "type": "RUN_ERROR",
  "threadId": "trace-abc",
  "runId": "trace-abc",
  "error": {
    "kind": "infra_error",
    "message": "Runner exited with code 1",
    "trace_id": "trace-abc"
  }
}
```

Reglas:
- `error.kind` ∈ {`bad_request`, `agent_error`, `infra_error`}.
- `error.message` es safe-to-log (sin secretos ni rutas del filesystem).
- `error.trace_id` siempre coincide con `runId`/`threadId`.

### 3.5 Múltiples mensajes por interacción

Una interacción puede generar múltiples mensajes (ej: respuesta + follow-up):

```
RUN_STARTED
TEXT_MESSAGE_START {messageId: "msg-1"}
TEXT_MESSAGE_CONTENT {messageId: "msg-1", delta: "Primera respuesta"}
TEXT_MESSAGE_END {messageId: "msg-1"}
TEXT_MESSAGE_START {messageId: "msg-2"}
TEXT_MESSAGE_CONTENT {messageId: "msg-2", delta: "Y además..."}
TEXT_MESSAGE_END {messageId: "msg-2"}
RUN_FINISHED
```

El adapter usa `StreamPhase` para trackear transiciones entre mensajes.

### 3.6 Invariantes de streaming (AG-UI)

- `RUN_STARTED` se emite una vez por interacción.
- `TEXT_MESSAGE_START`/`TEXT_MESSAGE_END` aparecen en pares por `messageId`.
- El cierre es exactamente uno:
  - `RUN_FINISHED`, o
  - `RUN_ERROR`.

### 3.7 IDs y trazabilidad (AG-UI)

| Core | AG-UI | Regla |
|------|-------|-------|
| `trace_id` | `runId` y `threadId` | Igualar ambos a `trace_id` (v0) |
| `StreamPhase.message_id` | `messageId` | Generado por el adapter si el stream no lo modela explícitamente |

### 3.8 Mapeo de errores (AG-UI)

- Errores no-streaming se devuelven como respuesta HTTP del endpoint nativo.
- Errores mid-stream se emiten como `RUN_ERROR` y el stream termina.
- Los `ErrorKind` del core se serializan como `error.kind` + `error.message` (+ `trace_id`) en el payload AG-UI (sin exponer rutas ni secretos).
- Cancelación por `stop/delete` se expresa como `RUN_ERROR` con `error.kind="agent_error"` y `error.message="cancelled"` (y el stream termina).

### 3.9 Backpressure (AG-UI SSE)

La entrega SSE aplica batching y límites para evitar OOM, manteniendo orden.

---

## 4. Perfil JSON

Definición declarativa de agentes.

Ver también `integracion.md` para el contrato completo de integración (perfil+runner+adapters).

**Reglas generales:**
- `interface.protocol` ∈ {`runner`, `http`}; `http` usa solo `managed_port` (host/port asignados por SAD y pasados via env).
- `input_schema` cerrado: `std:chat`, `std:files` o chat extendido con `extra_fields` tipados.
- `limits` por capability sobrescriben `SadConfig`.
- `response` usa JSON Pointers (`text_pointer`, `artifacts_pointer`).
- `ui_hint` es Json opaco; SAD no lo interpreta.
- Ver también `protocolos_runner.md` para el contrato de ejecución/provisioning/stop de runners.

### 4.1 Estructura

```json
{
  "meta": {
    "id": "aider",
    "description": "AI pair programmer",
    "lifecycle": "transient"
  },
  "parameters": {
    "model": {"source": "init", "key": "model", "type": "string", "default": "gpt-4"},
    "api_key": {"source": "secret", "key": "OPENAI_API_KEY", "type": "string"}
  },
  "runner": {
    "type": "generic_uvx",
    "tool_config": {"package": "aider-chat", "command": "aider"}
  },
  "interface": {
    "protocol": "runner",
    "capabilities": {
      "chat": {
        "input_schema": {"$ref": "std:chat"},
        "streaming": false
      }
    }
  }
}
```

**Reglas adicionales:**
- `interface.protocol=http` usa solo `managed_port` (no `static_port`); SAD asigna host/port y los inyecta via env.
- `input_schema` es cerrado: `std:chat`, `std:files` o `chat` extendido con `extra_fields` tipados.
- `limits` por capability (timeouts, etc.) sobrescriben `SadConfig`.
- `response` usa JSON Pointers (`text_pointer`, `artifacts_pointer`).
- `ui_hint` es Json opaco; SAD no lo interpreta.

### 4.1 Entrega de ficheros (solo runners CLI)

En capabilities `runner` que usan `std:files`, SAD trabaja con `FileRef.url` (equivalente a A2A `file.uri`).
El contrato v0 es simple:

- SAD **no descarga ni materializa** ficheros antes de invocar el runner.
- El runner recibe siempre **URLs** y, si necesita rutas locales, descarga/copia dentro del workspace.

Racional: materialización segura (download/copy, límites de tamaño, naming, cleanup, credenciales) añade complejidad
que es más apropiada en capas superiores (SAM/storage) o en el propio runner.

### 4.2 Sources de parámetros

| Source | Origen | Default permitido |
|--------|--------|-------------------|
| `fixed` | Valor embebido | Sí (es el valor) |
| `config` | `config.toml` | Sí |
| `secret` | Variable de entorno | **No** |
| `init` | `init_params` del request | Sí |

### 4.3 Lifecycles

| Lifecycle | Descripción |
|-----------|-------------|
| `transient` | Proceso efímero por interacción |
| `continuous` | Servidor HTTP persistente |

### 4.4 Límites por capability

```json
"interface": {
  "protocol": "runner",
  "capabilities": {
    "generate_report": {
      "input_schema": {"$ref": "std:chat"},
      "limits": {
        "call_timeout_ms": 300000
      }
    }
  }
}
```

### 4.5 Body HTTP (JSON / multipart)

SAD soporta dos modos de request body para capabilities HTTP:

- `json`: template Json con:
  - strings con `{{namespace.key}}` (strict, solo escalares), y
  - inserciones estructuradas `{"$from": "/json/pointer"}` (strict, RFC 6901) contra `SAD_INPUT_JSON` (útil para arrays/objetos).
- `multipart`: campos string interpolados + ficheros tomados del input vía `source_pointer`.

**Aclaración:** este `multipart` es **SAD → agente** (SAD construye la request HTTP al agente).
Los ficheros se originan en `InputPayload` como `FileRef` (URLs, no bytes inline). Para construir `multipart`, SAD debe poder leer/stream-ear el contenido desde esa URL (p.ej. URL pública o pre-firmada).

**Límites (v0):**
- SAD rechaza requests entrantes cuyo body exceda `SadConfig.max_request_body_bytes` (413).
- Al construir multipart desde `FileRef` (URL), SAD debe stream-ear la descarga y cortar si excede `SadConfig.max_file_fetch_bytes` (evita OOM/ficheros gigantes).

Ejemplo (pasar lista completa de mensajes):

```json
"body": {
  "type": "json",
  "template": {
    "messages": { "$from": "/input/messages" }
  }
}
```

Ejemplo (subir un fichero por multipart):

```json
"body": {
  "type": "multipart",
  "fields": {},
  "files": [
    { "field": "file", "source_pointer": "/input/files/0" }
  ]
}
```
