# Bridge (interpolador, runner y cliente HTTP)

El bridge encapsula IO y contratos externos (`SAD_INPUT_JSON`, ports, HTTP). 
El `AgentActor` solo ve tipos de dominio y el protocolo unificado de mensajes.

**Principio clave:** El actor nunca hace IO. El bridge traduce eventos de bajo nivel 
(port_data, port_exit, HTTP responses) al protocolo unificado antes de enviar al actor.

**Timeouts:** En el bridge/gateway, los timeouts vienen de `SadConfig` (y límites por capability); los wrappers internos reciben `timeout_ms` explícito para evitar literales en el flujo real.

**Parámetros:** El bridge recibe `ResolvedParams` del actor (ya resueltos por `params.gleam`).
Nunca resuelve parámetros; solo los usa para interpolación y construcción de `SadInput`.

## 0. API Bridge (inyectable)

Para facilitar TDD del core y evitar acoplamiento a módulos concretos (`runner.gleam`, `client.gleam`),
el actor usa un **record de funciones** inyectado al arrancar el agente.

Referencia completa (v0): `arquitectura/examples/snippets/bridge_api.gleam`.

Extracto (v0):

```gleam
pub type BridgeCtx {
  BridgeCtx(profile: Profile, instance_id: InstanceId, params: ResolvedParams, workspace: String, assigned_port: Option(Int), config: SadConfig, artifact_registry: Subject(ArtifactRegistryMsg))
}

pub type Bridge {
  Bridge(start_provisioning: fn(BridgeCtx, AgentRef) -> Pid, start_interaction: fn(BridgeCtx, AgentRequest, AgentRef, Int, Bool, Option(StreamSink)) -> Pid, cancel_interaction: fn(InteractionHandle) -> Nil, stop_server: fn(AgentResource) -> Nil)
}
```

En tests unitarios del actor, se inyecta un `Bridge` fake que solo emite
`ProvisioningDone/InteractionDone` sin abrir ports ni hacer HTTP real.

## 1. Imports

El bridge importa tipos de `tipos.md`:

```gleam
import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}
import gleam/json.{type Json}
import gleam/list
import gleam/int
import gleam/erlang/process.{type Subject, type Pid}

import sad/core/agent.{type AgentRef}
import sad/core/agent_internal
import sad/core/messages.{type InteractionHandle, interaction_handle, interaction_handle_pid}

import sad/types.{
  // Configuración + contexto
  type SadConfig,
  type InteractionStreamConfig,
  type ResolvedParams,
  type RequestContext,
  type TraceId, trace_id_to_string,

  // Identificadores
  type ProfileId, profile_id_to_string,
  type InstanceId, instance_id_to_string,

  // Input + wire runner
  type InputPayload,
  type SadInput, SadInput,
  type RunnerResponse, type RunnerStatus, StatusSuccess, StatusError,

  // Resultados + artefactos
  type InteractionResult, InteractionResult,
  type InteractionError, InteractionError,
  type PublicArtifact, PublicArtifact,
  type ErrorKind, AgentError, InfraError, BadRequest,

  // Logging + streaming genérico
  type LogEvent, log_event,
  type StreamEvent,
  stream_started, content_chunk, stream_finished, stream_error,
}
```

**Nota:** El bridge NO importa `Parameter` ni `ParamResolutionError` porque no resuelve
parámetros. Recibe `ResolvedParams` del actor, que a su vez los recibió ya resueltos
de `sys.gleam` vía `params.resolve()`.

## 2. Serialización (`sad/bridge/serialization.gleam`)

Funciones para convertir tipos internos a JSON wire format.
Reemplaza los tipos `*Wire` redundantes con funciones explícitas.

Referencia completa (v0): `arquitectura/examples/snippets/bridge_serialization.gleam`.

Extracto (v0):

```gleam
pub fn sad_input_meta_to_json(meta: SadInputMeta) -> Json {
  ...
}

pub fn request_context_to_json(ctx: RequestContext) -> Json {
  ...
}
```

## 3. Interpolador (`sad/bridge/interpolator.gleam`)

### 3.1 Contexto de interpolación

```gleam
/// Contexto para resolver plantillas {{namespace.key}}.
/// Todos los campos son tipados, no Dynamic.
/// Los params ya vienen resueltos de params.resolve().
pub type InterpContext {
  InterpContext(
    /// Parámetros resueltos del perfil (ya resueltos por params.gleam).
    /// Contiene ResolvedValue que distingue normales de secretos.
    params: ResolvedParams,
    /// Payload de la interacción
    input: InputPayload,
    /// Contexto de trazabilidad
    context: RequestContext,
    /// Helpers derivados (solo para schemas estándar)
    helpers: Option(SadHelpers),
    /// Host del runner (para continuous)
    runner_host: Option(String),
    /// Puerto del runner (para continuous)
    runner_port: Option(Int),
  )
}

/// Construye contexto desde los datos de una interacción.
/// Los params ya vienen resueltos; no hay resolución aquí.
pub fn build_context(
  params: ResolvedParams,
  input: InputPayload,
  context: RequestContext,
  runner_host: Option(String),
  runner_port: Option(Int),
) -> InterpContext {
  InterpContext(
    params: params,
    input: input,
    context: context,
    helpers: Some(derive_helpers(input)),
    runner_host: runner_host,
    runner_port: runner_port,
  )
}
```

### 3.2 Errores de interpolación

```gleam
/// Errores de interpolación.
pub type InterpolationError {
  /// Namespace desconocido (ej: {{bad.key}})
  UnknownNamespace(namespace: String, key: String)
  /// Key no encontrada en el namespace (ej: {{params.missing}})
  UnknownKey(namespace: String, key: String)
  /// Intentar interpolar un valor no escalar en un string
  ValueNotScalar(key: String)
}

pub fn interpolation_error_to_string(err: InterpolationError) -> String {
  case err {
    UnknownNamespace(ns, key) ->
      "Interpolation failed: Unknown namespace '{{" <> ns <> "." <> key <> "}}'"
    UnknownKey(ns, key) ->
      "Interpolation failed: Unknown key '{{" <> ns <> "." <> key <> "}}'"
    ValueNotScalar(key) ->
      "Interpolation failed: Value for '" <> key <> "' is not scalar"
  }
}
```

### 3.3 API de interpolación

**Nota:** Todas las funciones son **strict**. No hay modo laxo.

Referencia completa (v0): `arquitectura/examples/snippets/bridge_interpolation_api.gleam`.

Extracto (v0):

```gleam
pub fn interpolate_string(template: String, ctx: InterpContext) -> Result(String, InterpolationError) {
  ...
}

pub fn interpolate_dict(templates: Dict(String, String), ctx: InterpContext) -> Result(Dict(String, String), InterpolationError) {
  ...
}
```

### 3.4 Resolución de namespaces

Referencia completa (v0): `arquitectura/examples/snippets/bridge_interpolation_resolution.gleam`.

Extracto (v0):

```gleam
fn resolve_placeholder(namespace: String, key: String, ctx: InterpContext) -> Result(String, InterpolationError) {
  ...
}
```

### 3.5 Resumen de namespaces

| Namespace | Keys soportadas | Fuente |
|-----------|-----------------|--------|
| `params.*` | Cualquier key de `ResolvedParams` | `ctx.params` |
| `helpers.last_user_content` | Solo esta key | `ctx.helpers` |
| `context.trace_id` | Solo esta key | `ctx.context` |
| `runner.host` | Solo en modo Continuous | `ctx.runner_host` |
| `runner.port` | Solo en modo Continuous | `ctx.runner_port` |
| `input.*` | Solo `extra_params` (escalares) | `ctx.input` |

**No soportado:**
- `env.*` (variables de entorno en templates)
- Acceso a `input.messages` o `input.files` (usar `helpers`)
- Sintaxis anidada `{{a.b.c}}`
- Filtros/defaults `{{a.b | default:x}}`
- Keys con caracteres fuera de `[A-Za-z0-9_-]`

## 4. Runner (`sad/bridge/runner.gleam`)

### 4.1 Tipos

```gleam
/// Handle para un servidor continuous.
/// v0: el core almacena un `AgentResource` (opaco) definido en `sad/core/agent.gleam`,
/// que envuelve el `Port` de Erlang y evita que capas externas manipulen el recurso.
```

**Nota sobre Provisioning:** La respuesta de provisioning (`ProvisionResponse`) está documentada
en `protocolos_runner.md`. El bridge parsea esta respuesta pero el tipo canónico se define allí
para mantener SSOT del contrato runner.

### 4.1.1 Provisioning (worker)

El core no ejecuta provisioning: el `Bridge` lo arranca como un worker y luego notifica al actor.

```gleam
import gleam/erlang/process
import sad/core/agent_internal
import sad/bridge/bridge.{type BridgeCtx}

/// Arranca provisioning en un worker BEAM y notifica al actor con `ProvisioningDone(...)`.
pub fn start_provisioning(ctx: BridgeCtx, agent: AgentRef) -> Pid {
  // Worker BEAM de IO: usar unlinked para que fallos externos no tumben al actor.
  process.spawn_unlinked(fn() {
    let outcome = provision_and_start(ctx)
    agent_internal.provisioning_done(agent, outcome)
  })
}
```

### 4.2 Construcción de SadInput

```gleam
import sad/bridge/serialization.{sad_input_to_json}

/// Construye el input interno rico.
/// Los params ya vienen resueltos; aquí solo se empaquetan.
/// NOTA: Los secretos en params serán serializados para el runner.
pub fn build_input(
  profile_id: ProfileId,
  instance_id: Option(InstanceId),
  lifecycle: Lifecycle,
  params: ResolvedParams,  // Ya resueltos, incluye SecretVal
  input: InputPayload,
  context: RequestContext,
  runner: Runner,
) -> SadInput {
  SadInput(
    meta: SadInputMeta(
      spec_version: "3.0",
      profile_id: profile_id,
      instance_id: instance_id,
      mode: lifecycle,
    ),
    params: params,
    input: input,
    context: context,
    helpers: Some(derive_helpers(input)),
    runner_def: runner,
  )
}
```

### 4.3 Provisioning

```gleam
/// Ejecuta provisioning (sincrónico).
/// Los params ya vienen resueltos.
pub fn provision(
  runner: Runner,
  input: SadInput,
  workspace: String,
) -> Result(ProvisionResponse, String) {
  let control_line =
    json.object([
      #("t", json.string("input")),
      #("payload", sad_input_to_json(input)),
    ])
    |> json.to_string
  
  // Ejecutar runner --provision
  let result = execute_runner_sync(
    runner,
    ["--provision"],
    control_line <> "\n",
    workspace,
  )
  
  case result {
    Ok(output) -> parse_provision_response(output)
    Error(msg) -> Error("Provision failed: " <> msg)
  }
}
```

### 4.4 Interacción (protocolo unificado con streaming)

El bridge spawna un worker que ejecuta el runner y envía mensajes tipados al actor.
El worker captura timestamp y trace_id para cada línea de log.
Si `streaming` es true, emite eventos genéricos (que los adapters traducen a AG-UI, A2A, etc.).

**Mejora futura (no v0):** agrupar logs en ventanas cortas y enviar batches (`IngestLogs(List(LogEvent))`) para reducir presión de mailbox en el `AgentActor`.

Referencia completa (v0): `arquitectura/examples/snippets/bridge_runner_transient.gleam`.

Extracto (v0):

```gleam
pub fn start_interaction(ctx: BridgeCtx, req: AgentRequest, agent: AgentRef, timeout_ms: Int, streaming: Bool, stream_sink: Option(StreamSink)) -> Pid {
  ...
}
```

**`StreamSink` vive bajo `sad/streams/`.** El bridge lo usa únicamente como data-plane
(batches con ack y timeout). El gateway crea un `StreamSink` por request streaming (SSE writer).

**Definición canónica (v0):** un *batch* es `List(StreamEvent)` (eventos tipados), **no** líneas SSE ni strings.
El `StreamSink` es el único responsable de serializar esos eventos al wire SSE y de aplicar backpressure (ack).

**Implementación recomendada (v0):** el gateway implementa el writer SSE con `mist.server_sent_events(...)` y envía eventos con
`mist.send_event(...)`. El bridge permanece agnóstico del servidor HTTP y solo empuja batches **con ack** (safe-call).

Referencia completa (v0): `arquitectura/examples/snippets/streams_sink_safe_call.gleam` (usa `sad/otp/safe_call.call_within`).
Implementación del loop SSE (Mist) como sink: `arquitectura/examples/snippets/gateway_sse_stream_sink_mist.gleam`.

Extracto (v0):

```gleam
pub type StreamSink = Subject(StreamSinkMsg)

pub fn push_batch(sink: StreamSink, events: List(StreamEvent), timeout_ms: Int) -> Result(Nil, CallError) {
  ...
}
```


**Fail-fast (v0) — contrato JSONL del runner:** la capa `sad/bridge/port_process.gleam` valida cada línea recibida:
- JSON válido bajo límites (`max_stdout_bytes`, límite por línea/evento)
- `t` conocido (`log`/`chunk`/`result`/`provision_result`)
- forma mínima por evento
Ante violación: terminar inmediatamente el port/wrapper y devolver `ContractViolation` (no intentar “recuperar”).


### 4.5 Servidor continuous

Referencia completa (v0): `arquitectura/examples/snippets/bridge_runner_continuous_server.gleam`.

Extracto (v0):

```gleam
pub fn start_server(runner: Runner, input: SadInput, host: String, port: Int, workspace: String, instance_id: InstanceId, agent: AgentRef) -> Result(AgentResource, String) {
  ...
}
```

**Nota sobre monitoreo de servidores continuous:**

No se usa `process.monitor` para el servidor porque el Port de Erlang ya provee 
notificación de muerte vía `PortExit`. El bridge traduce este evento a `ServerDied`
que el actor procesa para transitar a estado `Failed`.

## 5. Cliente HTTP (`sad/bridge/client.gleam`)

### 5.0 Dependencias y tipos HTTP

SAD usa `httpp` como cliente HTTP (sync + streaming SSE). Los tipos de esta sección encapsulan
la interacción con el cliente para mantener el bridge agnóstico de la implementación.

#### Dependencia

```toml
# gleam.toml
[dependencies]
httpp = "~> 1.8"
gleam_http = "~> 4.0"
```

**Nota:** Ver `operaciones.md` para la lista completa de dependencias y sus versiones.

#### Tipos HTTP internos

Referencia completa (v0): `arquitectura/examples/snippets/bridge_http_client_types.gleam`.

Extracto (v0):

```gleam
pub type HttpResponse {
  HttpResponse(status: Int, headers: List(#(String, String)), body: String)
}

pub fn request(method: Method, url: String, headers: Dict(String, String), body: Option(Json), timeout_ms: Int) -> Result(HttpResponse, HttpError) {
  ...
}
```

#### Tipos SSE (Server-Sent Events)

Referencia completa (v0): `arquitectura/examples/snippets/bridge_sse_types.gleam`.

Extracto (v0):

```gleam
pub opaque type SseConnection {
  ...
}
```

### 5.0 Derivación de Host/Port

El host y puerto del runner se derivan del estado cuando se necesitan, no se almacenan como campos separados:

```gleam
/// Deriva host/port del estado del agente.
/// Idiomático: preferir derivación sobre almacenamiento de datos derivados.
pub fn get_runner_network(
  ctx: BridgeCtx,
) -> #(Option(String), Option(Int)) {
  case ctx.assigned_port {
    None -> #(None, None)
    Some(port) -> #(Some(ctx.config.managed_port_host), Some(port))
  }
}

/// Construye contexto de interpolación con host/port derivados.
/// Los params ya vienen resueltos en ctx.params.
pub fn build_interp_context(
  ctx: BridgeCtx,
  input: InputPayload,
  context: RequestContext,
) -> InterpContext {
  let #(host, port) = get_runner_network(ctx)
  
  build_context(
    ctx.params,
    input,
    context,
    host,
    port,
  )
}
```

## 5.1 Port pool (`managed_port`) — contrato mínimo

SAD asigna puertos para agentes `continuous` con `network_mode=managed_port` usando:
- un helper puro `sad/port_pool.gleam` (lógica de allocate/release),
- un `PortPoolActor` (OTP) como SSOT de reservas (InstanceId → port), construido desde `SadConfig.port_range_min/max`.

**Contrato v0 (simple y testeable):**
- `allocate(instance_id)` devuelve un puerto libre dentro del rango, o `Error(PoolExhausted)`.
- `release(instance_id)` libera el puerto reservado (idempotente si no existe).
- El bridge debe pedir `allocate` **antes** de arrancar el servidor (port/wrapper) y, si falla, emitir `ProvisioningDone(Error("PORT_POOL_EXHAUSTED: ..."))`.
- El release ocurre al completar `stop` y en `delete` (y en rollback/terminate/failure). Si la instancia se vuelve a arrancar (`start`), se reasigna puerto durante provisioning (puede cambiar).

Referencia (API): `arquitectura/examples/snippets/port_pool_api_public.gleam`.

Esto mantiene el core BEAM simple: sin probing de puertos del SO, sin persistencia, sin GC automático.

**Nota:** `assigned_port` se almacena en `BridgeCtx` (derivado del estado del actor) solo para agentes continuous, asignado durante el provisioning.

### 5.1 Health check

Referencia completa (v0): `arquitectura/examples/snippets/bridge_http_health_check.gleam`.

Extracto (v0):

```gleam
pub fn health_check(interface: Interface, config: SadConfig, trace_id: TraceId) -> Result(Nil, InteractionError) {
  ...
}
```

### 5.2 Interacción HTTP (con soporte de streaming)

**Objetivo SSE (v0):** preservar la experiencia de streaming sin “entender” protocolos específicos. El bridge trata SSE como transporte:
lee el stream, aplica límites/backpressure/cancelación, y reenvía incrementalmente hacia el `StreamSink`/cliente.

Referencia completa (v0): `arquitectura/examples/snippets/bridge_http_streaming.gleam`.

Extracto (v0):

```gleam
pub fn start_interaction(ctx: BridgeCtx, req: AgentRequest, agent: AgentRef, timeout_ms: Int, streaming: Bool, stream_sink: Option(StreamSink)) -> Pid {
  ...
}
```

## 6. Contrato de mensajes bridge → actor

El bridge emite **únicamente** estos mensajes al actor:

| Mensaje | Cuándo | Origen |
|---------|--------|--------|
| `ProvisioningDone(Result(...))` | Fin de provisioning (Ready* o Failed) | Worker de provisioning |
| `InteractionDone(Result(...))` | **Fin de interacción (siempre)**, con resultado completo (incluye artefactos) | Runner/HTTP worker (streaming=true/false) |
| `IngestLog(LogEvent)` | Evento de log con metadata (idealmente batched/coalesced) | Runner/HTTP worker |
| `ServerDied(exit_code)` | Servidor continuous murió | Server log loop |

**Nota:** `StreamEvent` incluye `type_`, `timestamp` y `payload` para interoperar con AG-UI.

**Mapeo a SSE (gateway):**
- `IngestLog(LogEvent)` → SSE de logs de instancia (`GET /sys/agents/:instance_id/logs/stream`): ring buffer + live.
- En streaming, el flujo canónico de datos es worker → `sad/streams/sink.StreamSink` (gateway, 1 por request) con ack (ver §7.2).
- Son flujos distintos: logs (ciclo de vida de instancia) vs streaming de interacción (ciclo de vida de request).

**Invariante canónica:** el actor **nunca** debe finalizar una interacción solo por recibir `StreamFinished`/`StreamError`.
El único evento terminal de la interacción es `InteractionDone(...)` (para evitar estados imposibles y pérdida de artefactos).

## 7. Streaming y backpressure (v0)

SAD separa explícitamente dos flujos:

- **Logs (instancia):** observabilidad best-effort (drop/coalesce permitido).
- **Streaming de interacción:** datos de respuesta (AG-UI/A2A) ligados al lifecycle del request.

Regla de simplicidad: el `AgentActor` es **control-plane** (estado/artefactos) y no debe ser proxy de alta frecuencia.

### 7.1 Flujo canónico (capability `streaming: true`)

En el camino canónico, el bridge **no** envía chunks al actor.
Los chunks van directamente a un `sad/streams/sink.StreamSink` creado por el gateway para esa request.

```
┌─────────────┐     ┌────────────────┐     ┌────────────────┐     ┌──────────────┐
│   Runner    │     │ Bridge worker  │     │ StreamSink     │     │ Cliente SSE  │
└──────┬──────┘     └──────┬─────────┘     └──────┬─────────┘     └──────┬───────┘
       │                   │                        │                        │
       │ stdout: chunk     │ push_batch(events)     │ write to socket         │
       │──────────────────>│───────────────────────►│────────────────────────►│
       │ stdout: chunk     │ push_batch(events)     │ write to socket         │
       │──────────────────>│───────────────────────►│────────────────────────►│
       │ stdout: result    │                        │                        │
       │──────────────────>│                        │                        │
       │                   │ InteractionDone(result)│                        │
       │                   │───────────────────────►│                        │
       │                   │ (Actor actualiza SSOT: │                        │
       │                   │  estado/artefactos)    │                        │
       │                   │ finish(result)         │ write terminal + close  │
       │                   │───────────────────────►│────────────────────────►│
```

**Propiedades:**
- `InteractionDone(...)` se envía **siempre** al actor (streaming=true/false) y es el único terminal para el estado (incluye artefactos).
- El stream al cliente se termina cuando el `AgentActor` llama `StreamSink.finish(result)` tras recibir `InteractionDone(...)`.
- Logs y stream no comparten canal lógico: `IngestLog` (actor) vs `StreamSink` (request).

### 7.2 Backpressure: contrato mínimo (sin `bounded_stream`)

Para mantener simplicidad y seguir BEAM-friendly, v0 usa un contrato mínimo:

- **Batching:** el worker agrupa `List(StreamEvent)` hasta `InteractionStreamConfig.batch_byte_size` o `InteractionStreamConfig.flush_interval_ms`.
- **Ack (request):** `StreamSink.push_batch(batch)` confirma cuando el batch está aceptado/escrito. Eso limita el ritmo hacia el socket.
- **Disconnect:** si el cliente se desconecta, el `StreamSink` muere y `push_batch` falla; el worker pasa a **discard mode** (deja de empujar batches) y continúa hasta producir `InteractionDone(...)`.
- **Timeout:** si `push_batch` no completa en `InteractionStreamConfig.push_timeout_ms`, el worker degrada a **discard mode** y continúa hasta `InteractionDone(...)`.

**Política explícita (v0):** desconexión del cliente SSE o timeout de `push_batch` **no cancela** la ejecución.
Solo afecta a la entrega (streaming) y se degrada a discard; la interacción continúa hasta `InteractionDone(...)`.

Este contrato evita buffers infinitos sin introducir resume/replay ni acoplar el core al gateway.

 

## 8. Monitoreo y Tolerancia a Fallos

### 8.1 Relación Actor ↔ Worker

```
┌─────────────────┐         ┌─────────────────┐
│   AgentActor    │         │  Bridge Worker  │
│                 │         │                 │
│  mode: Busy     │◄───────►│  (runner/http)  │
│  handle: {pid,  │ monitor │                 │
│           mon}  │         │                 │
└─────────────────┘         └─────────────────┘
        │                           │
        │                           │
        ▼                           ▼
   WorkerDown ◄──────────────── process dies
```

### 8.2 Relación Actor ↔ Servidor Continuous

```
┌─────────────────┐         ┌─────────────────┐
│   AgentActor    │         │  Server Process │
│                 │         │                 │
│  lifecycle:     │         │  (uvx server)   │
│  Continuous     │         │                 │
│                 │         │                 │
└─────────────────┘         └─────────────────┘
        │                           │
        │                           │
        ▼                           ▼
   ServerDied ◄──────────────── PortExit(code)
```

### 8.3 Escenarios de Fallo

| Escenario | Detección | Acción |
|-----------|-----------|--------|
| Worker termina normalmente (no streaming) | `InteractionDone` | Actor procesa resultado |
| Worker termina normalmente (streaming) | `InteractionDone` | Actor procesa resultado y cierra el stream |
| Worker crashea | `WorkerDown` | Actor responde error, vuelve a Idle |
| Runner devuelve error (no streaming) | `InteractionDone(Error)` | Actor propaga error al cliente |
| Runner devuelve error (streaming) | `InteractionDone(Error)` | Actor propaga error y cierra el stream |
| Servidor continuous muere | `ServerDied(code)` | Actor transita a Failed |
| Timeout de runner (transient) | Worker no termina | Cliente recibe timeout; el worker detiene el runner (cierra port/stop) |
| Timeout de runner (continuous) | Worker no termina | Cliente recibe timeout; el servidor queda vivo |

### 8.4 Spawn vs Link

El bridge usa `process.spawn_unlinked` (unlinked) para los workers: prioriza fail-safe (un crash del worker no tumba al actor).

**Normativa v0 (anti “zombie workers”):**
- El actor monitoriza al worker (ya se hace) para detectar fallos y limpiar estado.
- El worker MUST monitorizar al actor **al inicio** (antes de abrir ports, iniciar HTTP streaming o cualquier IO):
  - si el actor ya murió, el monitor dispara inmediatamente y el worker debe terminar sin arrancar recursos.
  - si el actor muere durante la ejecución, el worker debe auto-terminarse.
- El worker MUST ser el **owner** de los recursos externos (Port/HTTP stream) para que, al morir el worker, se cierren.
  - En runners (Port): cerrar el Port implica terminar el wrapper/runner (el wrapper debe aplicar stop al proceso del runner al perder stdin).
  - En HTTP streaming: el worker deja de leer/escribir y termina; no hay proceso OS que pueda quedar huérfano.

**Nota:** en `gleam_erlang`, `process.spawn` crea procesos **linkados**; usar `spawn_unlinked` evita que un crash del worker propague exits al actor.

Esto evita propagación de exits indeseada (que un `kill` del worker tumbe al actor) y previene workers huérfanos incluso bajo carga o crashes abruptos.

## 9. Decisiones de diseño

| Decisión | Justificación |
|----------|---------------|
| Protocolo unificado | Actor no conoce si es port o HTTP |
| Streaming condicional | Flag `streaming: Bool` en capability determina comportamiento |
| Eventos genéricos + adapters | Core agnóstico del protocolo, adapters traducen a AG-UI/A2A |
| `StreamStarted` explícito | Adapters (AG-UI, A2A) lo necesitan para iniciar stream |
| `InteractionDone` finaliza | Un único evento terminal evita pérdida de artefactos |
| Helpers tipados | `Option(SadHelpers)` en lugar de `Dict(String, Dynamic)` |
| Modo estricto para rutas | Falla temprano si falta placeholder |
| `InteractionResult` interno | Separación clara de wire format |
| Worker por interacción | Aislamiento de fallos, cancelación simple |
| spawn_unlinked para workers | Evita propagación de exits; actor solo recibe eventos |
| Monitor en actor | Detecta crash sin morir |
| Port para servidor | Notificación de muerte sin monitor explícito |
| Derivar host/port | Single source of truth, evita sincronización |
| Funciones de serialización | Reemplaza tipos Wire redundantes, un solo lugar para lógica |
| Timeouts de SadConfig | Nunca literales hardcodeados |
| LogEvent con metadata | ts_ms, trace_id, instance_id para observabilidad |
| Params ya resueltos | Bridge no resuelve; usa ResolvedParams del actor |

## 10. Resumen de Tipos Wire Eliminados

| Tipo eliminado | Función de reemplazo | Ubicación |
|----------------|---------------------|-----------|
| `SadInputMetaWire` | `sad_input_meta_to_json()` | `bridge/serialization.gleam` |
| `SadInputWire` | `sad_input_to_json()` | `bridge/serialization.gleam` |

## 11. Uso de Timeouts

| Operación | Fuente del timeout |
|-----------|-------------------|
| Health check | `config.health_check_timeout_ms` |
| Shutdown servidor | `config.shutdown_timeout_ms` |
| HTTP requests | Delegado al caller (agent usa `resolve_call_timeout`) |

**Regla:** El bridge no decide timeouts de interacción; eso lo hace `agent` usando `SadConfig` y `CapabilityLimits`.
**Semántica:** Cuando expira el timeout de interacción, en `transient` se detiene el runner (stop/EOF via port); en `continuous` solo falla la llamada y el servidor sigue vivo.

## 12. Flujo de parámetros (resumen)

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   sys.gleam     │     │   AgentActor    │     │     Bridge      │
│                 │     │                 │     │                 │
│  params.resolve │────►│ ResolvedParams  │────►│ ResolvedParams  │
│  (único punto)  │     │ (en AgentState) │     │ (para interp.)  │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                       │                       │
        │                       │                       │
   Parameter +              Solo ve              Solo ve
   config/env/init       ResolvedValue         ResolvedValue
```

**El bridge nunca ve `Parameter`**. Solo recibe `ResolvedParams` (que es `Dict(String, ResolvedValue)`)
donde `ResolvedValue` puede ser `NormalValue(ConfigValue)` o `SecretVal(SecretValue)`.

El bridge usa:
- `resolved_value_to_env()` para valores que van a env vars o comandos
- `resolved_value_inspect()` para logs (secretos aparecen como `***REDACTED***`)

El bridge los usa para:
1. Construir `SadInput` para enviar al runner
2. Interpolar templates en `env_map`, `args`, `base_url`, etc.

---

## 13. FFI (`sad/ffi.gleam`)

Centraliza la interoperabilidad con Erlang que **no está cubierta** por librerías hex.pm.

### 13.1 Principio

> **Mínima FFI necesaria.** Usar librerías cuando existan.

| Necesidad | Solución | FFI requerida |
|-----------|----------|---------------|
| UUIDs | `youid` | No |
| HTTP requests | `httpp/send` | No |
| HTTP streaming (SSE) | `httpp/sse` | No |
| Timestamps | `erlang:system_time/1` | **Sí** |
| Ports (spawn) | `erlang:open_port/2` (shim Erlang mínimo) | **Sí** |
| Signals (kill) | `os:cmd("kill")` | **No** (se delega al wrapper) |

**Nota:** `gleam_erlang/port` solo exporta el **tipo** `Port`, no funciones para manipularlo.

### 13.1.1 Abstracción `port_process`

Para que el resto del bridge y el core sean testeables y no “se enteren” de Erlang, toda interacción con ports debe pasar por un único módulo frontera:

- `sad/bridge/port_process.gleam`: API de alto nivel para arrancar y controlar el proceso externo (runner/wrapper).

Implementación (v0): **FFI mínima** (`sad/ffi.gleam` + `sad_ffi.erl`) para `open_port`/send/close.

### 13.2 API FFI

```gleam
// sad/ffi.gleam

/// Timestamp actual en milliseconds since epoch.
pub fn now_ms() -> Int

/// Abre un port hacia un proceso externo.
pub fn open_port(opts: PortOpts) -> PortResult

/// Envía datos por stdin al port.
pub fn port_send(port: Port, data: String) -> Nil

/// Cierra el port.
pub fn port_close(port: Port) -> Nil
```

### 13.3 Módulo Erlang (`sad_ffi.erl`)

```erlang
-module(sad_ffi).
-export([open_port/5, port_send/2, port_close/1]).

open_port(Command, Args, Env, Cd, MaxRunnerEventBytes) ->
    %% Contrato runner: STDOUT es JSONL (1 evento por línea). Usar `line` para recibir líneas completas.
    %% STDERR queda fuera de contrato (diagnóstico local); SAD no depende de capturarlo.
    %% `line` impone un límite por evento; si el runner excede el máximo o el port entrega fragmentos,
    %% port_process debe tratarlo como violación de contrato (InfraError) con mensaje claro.
    %% MaxRunnerEventBytes viene de SadConfig.limits.max_runner_event_bytes (default 262144).
    Opts = [{args, Args}, {env, Env}, {cd, Cd}, binary, exit_status, use_stdio, {line, MaxRunnerEventBytes}],
    try
        Port = erlang:open_port({spawn_executable, Command}, Opts),
        {port_ok, Port}
    catch _:Reason -> {port_error, format_error(Reason)}
    end.
```

---

## 14. Decoders (`sad/decoders.gleam`)

Parsers JSON para perfiles, requests y responses.

### 14.1 Principios

- **Fail-fast**: Ante datos inválidos, devolver `Error` descriptivo
- **Sin defaults silenciosos**: No esconder errores con valores por defecto
- **Solo parsing**: Los decoders parsean, no resuelven parámetros

### 14.2 Decoders principales

```gleam
/// Perfil completo de agente.
pub fn profile_decoder() -> Decoder(Profile)

/// Request wire format del cliente.
pub fn agent_request_wire_decoder() -> Decoder(AgentRequestWire)

/// Response del runner.
pub fn runner_response_decoder() -> Decoder(RunnerResponse)

/// Método HTTP (case insensitive).
pub fn http_method_decoder() -> Decoder(http.Method)
```

### 14.3 Validaciones en parsing

| Campo | Validación |
|-------|------------|
| `lifecycle` | Solo `"transient"` o `"continuous"` |
| `source` (param) | Solo `"fixed"`, `"config"`, `"secret"`, `"init"` |
| `secret` + `default` | Error: secretos no pueden tener default |
| `schema` | Solo `"std:chat"`, `"std:files"`, o pattern `"extended:*"` |
| `http.Method` | Solo `GET`, `POST`, `PUT`, `DELETE` (case insensitive) |

### 14.4 Normalización wire → interno

```gleam
/// Transforma request wire a interno, validando payload.
pub fn normalize_request(
  wire: AgentRequestWire,
  profile: Profile,
) -> Result(AgentInteractionRequest, AgentRequestError)
```

Pasos:
1. Buscar capability por ID
2. Validar payload según `input_schema`
3. Generar `trace_id` si no viene
4. Construir `AgentInteractionRequest`

### 14.5 Decodificación de payloads

```gleam
fn decode_payload(
  schema: InputSchema,
  inputs: Dynamic,
) -> Result(InputPayload, String) {
  case schema {
    SchemaChat -> decode_chat_payload(inputs)
    SchemaFiles -> decode_files_payload(inputs)
    SchemaChatExtended(fields) -> decode_extended_payload(inputs, fields)
  }
}
```

Para `SchemaChatExtended`, los `extra_fields` se mezclan en la raíz de `input`:

```json
{
  "messages": [...],
  "report_type": "detailed",
  "tone": "formal"
}
```
