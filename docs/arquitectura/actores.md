# Guía de actores SAD v3 (Gleam/BEAM)

Diseño "inside-out": primero `AgentActor`, luego registro y supervisor. 
Este documento describe la implementación OTP, referenciando los tipos definidos en `tipos.md`.

**Principios:**
- Tipos fuertes, estados ilegales irrepresentables
- Efectos en bordes (`bridge`), actor puro
- `ActorMode` como ADT explícito (no flags `Option`)
- Selector dinámico para monitoreo de workers
- Si se customiza un selector, incluir siempre el `default_subject`
- El actor **nunca resuelve parámetros**; recibe `ResolvedParams` ya resueltos

**Nomenclatura:** `AgentState` es el ADT interno del agente (incluye `ResolvedParams` y recursos BEAM como `Port` vía `AgentResource`); el record `AgentRuntimeState` es el estado runtime completo del actor. La API expone `AgentStatusView`/`AgentInfoView` (wire/diagnóstico) con `phase` + `mode` (`AgentRunMode`), sin secretos ni handles OTP.

## 0. Glosario (estado interno vs wire)

SAD usa **dos** representaciones de estado: una interna (con recursos BEAM) y otra wire (serializable y segura).

| Concepto | Tipo | Dónde vive | Para qué sirve |
|----------|------|------------|----------------|
| Estado interno del agente | `AgentState` (opaco) | `sad/core/agent.gleam` | FSM real; puede incluir `ResolvedParams` y recursos BEAM (`Port`, handles) |
| Estado runtime del actor | `AgentRuntimeState` (record) | `sad/core/agent.gleam` | Estado completo del proceso OTP (incluye selector, buffers, `ActorMode`) |
| Concurrencia de interacción | `ActorMode { Idle, Busy(InFlight) }` | `sad/core/agent.gleam` | Garantiza “una interacción a la vez” y hace los estados ilegales irrepresentables |
| Fase publicable | `AgentPhase` | `sad/types.gleam` | Vista estable para HTTP: Created/Provisioning/Ready*/Stopped/Failed (sin recursos) |
| Modo publicable | `AgentRunMode` | `sad/types.gleam` | Derivado de `ActorMode` (`RunIdle`/`RunBusy`), sin detalles internos |
| Vista de estado | `AgentStatusView` | `sad/types.gleam` | Lo que serializa el gateway: fase+modo+assigned_port+failure_reason (safe-to-log) |

## 1. Topología OTP

```
RootSupervisor (RestForOne, Permanent)
├── RegistryActor (Permanent)
│   - SSOT de instancias activas (InstanceId → AgentRef)
│   - Si crashea, **no intentamos rehidratar** el índice en v0
│   - Por diseño, su caída provoca (RestForOne) la terminación del subtree dependiente (ProfilesActor + AgentManagerActor + AgentFactorySupervisor + agentes + HttpServer): evita “agentes fantasma”
├── ArtifactRegistry (Permanent)
│   - Whitelist en memoria para servir `/artifacts/:artifact_id` (ArtifactId → #(InstanceId, WorkspacePath, mime))
│   - No monitorea agentes (cleanup explícito)
├── PortPoolActor (Permanent, si `managed_port`)
│   - SSOT de reservas de puertos (InstanceId → port)
│   - Wrap del helper puro `sad/port_pool.gleam`
├── ProfilesActor (Permanent)
│   - SSOT en memoria de perfiles cargados (ProfileId → Profile)
│   - Permite `/sys/reload-profiles` sin reiniciar SAD
│   - El IO de leer perfiles desde disco ocurre en el borde; aquí solo se actualiza estado puro (SetProfiles)
├── AgentManagerActor (Permanent)
│   - Actor “manager” de instancias (no es un supervisor OTP).
│   - Crea agentes bajo demanda vía `AgentFactorySupervisor` y coordina register/stop/delete.
│   - No es SSOT de perfiles (eso vive en ProfilesActor).
├── AgentFactorySupervisor (Permanent)
│   - `factory_supervisor` nombrado para crear `AgentActor` dinámicamente
│   - Children con `restart_strategy=Temporary` (sin auto-restart)
└── HttpServer (Permanent)
    - Gateway HTTP (SSE).
    - Se arranca al final para apagarse primero (dejar de aceptar conexiones antes de detener el core).
```

**Motivación de `ProfilesActor` (decisión v0):**
- Reiniciar SAD para “recargar perfiles” implica matar el árbol OTP, y por diseño eso termina procesos externos (ports/wrapper/runners). Evitamos introducir esa necesidad.
- Mantener perfiles en un actor dedicado permite recargar en caliente sin IO en el core (IO solo en el borde) y sin “statefulness difuso” en el manager.
- Política simple: el reload solo afecta a instancias nuevas; las existentes mantienen su snapshot.

### 1.0 Normativa v0 (SSOT + snapshots)

- `ProfilesActor` es el **SSOT** de perfiles en memoria. **No hace IO**; solo recibe/expone estado puro (`SetProfiles`, `GetProfile`, `ListProfiles`).
- `RegistryActor` es el **SSOT** de instancias activas. `AgentManagerActor` no mantiene un índice local ni requiere rehidratación.
- `StartArgs.profile` es un **snapshot** del perfil en el momento de creación. `POST /sys/reload-profiles` **solo** afecta a instancias nuevas.
- `AgentFactorySupervisor` crea `AgentActor` como children dinámicos con `restart_strategy=Temporary`: SAD **no** auto-reinicia agentes; si un agente cae, SAM decide si recrearlo.

### 1.1 Estrategias y Justificación

| Supervisor | Estrategia | Justificación |
|------------|------------|---------------|
| Root | RestForOne | Si cae Registry o ArtifactRegistry, reinicia el subtree dependiente (`ProfilesActor` + `AgentManagerActor` + `AgentFactorySupervisor` + agentes + `HttpServer`); si cae `AgentManagerActor`, reinicia su subtree dependiente (`AgentFactorySupervisor` + agentes + `HttpServer`) |

Hijos declarados en ese orden (Registry -> ArtifactRegistry -> PortPoolActor -> ProfilesActor -> AgentManagerActor -> AgentFactorySupervisor -> HttpServer) para que RestForOne reinicie dependencias sin cascadas innecesarias y para evitar “agentes huérfanos”.

**Invariante (consistencia):** si el `RegistryActor` pierde estado (crash+restart), SAD no permite que queden agentes vivos “invisibles” para el índice. La estrategia elegida (RestForOne con Registry antes del subtree dependiente: `ProfilesActor` + `AgentManagerActor` + `AgentFactorySupervisor` + agentes + `HttpServer`) garantiza que la caída del Registry tumba ese subtree. La reconciliación/recreación es responsabilidad de SAM.
Además, al declarar `AgentManagerActor` antes del `AgentFactorySupervisor`, si el manager crashea entre `start_child` y `registry.register`, el `RestForOne` tumba el factory (y por tanto los agentes) y no puede quedar un proceso “vivo pero no registrado”.

### 1.2 Política de Reinicio

| Actor | Política | Razón |
|-------|----------|-------|
| Registry | Permanent | Crítico para el sistema |
| ArtifactRegistry | Permanent | Sirve `/artifacts` y purga en delete |
| ProfilesActor | Permanent | SSOT de perfiles en memoria |
| AgentFactorySupervisor | Permanent | Crea agentes dinámicamente (children `Temporary`) |
| AgentManagerActor | Permanent | Debe estar siempre disponible |
| HttpServer | Permanent | Debe estar siempre disponible |
| AgentActor | N/A | En v0 no se reinician automáticamente agentes; SAM decide recreación |

### 1.3 Tolerancia a Fallos

```gleam
// En RootSupervisor (más conservador)
root_sup.restart_tolerance(intensity: 5, period: 60)
```

Root limita bucles de reinicio del árbol base. En v0 no hay auto-restart por agente (solo el supervisor raíz reinicia su subtree).

Módulos:

| Módulo | Responsabilidad |
|--------|-----------------|
| `sad/types.gleam` | Tipos de dominio (ver `tipos.md`) |
| `sad/core/messages.gleam` | Mensajes OTP internos compartidos (Registry/ArtifactRegistry/Supervisor, etc.) |
| `sad/params.gleam` | Resolución de parámetros (ver `config.md` §2) |
| `sad/core/agent.gleam` | `AgentActor` + API pública (`AgentRef`) |
| `sad/core/agent_internal.gleam` | API interna (bridge → actor) |
| `sad/core/registry.gleam` | Índice de instancias |
| `sad/core/registry_api.gleam` | API pública para el registry |
| `sad/core/profiles.gleam` | SSOT de perfiles (ProfilesActor) |
| `sad/core/profiles_api.gleam` | API tipada para ProfilesActor |
| `sad/core/agent_manager.gleam` | Actor “manager” de instancias (start vía factory supervisor) |
| `sad/gateway/http_server.gleam` | Servidor HTTP (mist) supervisado |
| `sad/bridge/runner.gleam` | Ports a `generic_uvx`/`generic_uvx_server` |
| `sad/bridge/client.gleam` | HTTP para continuous (httpp) |

## 2. Imports y tipos del actor

El actor importa tipos de **dominio/wire** de `tipos.md`. Los tipos runtime (OTP/recursos) viven en `sad/core/agent.gleam`.

```gleam
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject, type Selector, type Monitor, type Pid}
import gleam/list
import gleam/deque.{type Deque}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/otp/actor
import sad/types.{
  // Identificadores
  type ProfileId, type InstanceId, type TraceId,
  
  // Perfil
  type Profile, type ProfileMeta, type Lifecycle,
  type Runner, type Interface,

  // Parámetros resueltos (incluye secretos; no serializable directamente)
  type ResolvedParams,

  // Vista wire/diagnóstico (serializable; sin OTP/secrets)
  type AgentPhase, type AgentRunMode, type AgentStatusView, type AgentInfoView,
  
  // Resultados
  type InteractionResult,
  type InteractionError,
  type ResponseData,
  type ErrorKind, AgentError, InfraError, BadRequest,
  
  // Logging
  type LogSource,
  type LogEvent,
  
  // Streaming (tipos genéricos)
  type StreamEvent, ContentChunk, StreamStarted, StreamFinished, StreamError,
  stream_started, content_chunk, stream_finished, stream_error,
  
  // Input
  type InputPayload, type RequestContext,
}
```

**Nota:** El actor NO importa `Parameter` ni `ParamResolutionError` porque nunca
resuelve parámetros. Eso ocurre en `sys.gleam` antes de crear el actor.

## 3. Mensajes del actor

El `AgentActor` tiene un protocolo interno de mensajes, pero **no es API pública**.
La API pública expone un `AgentRef` opaco (ver §17) y funciones (`interact/status/stop/...`).
Los eventos internos (logs/fin) se inyectan vía `sad/core/agent_internal.gleam` desde bridge/workers.

**Regla de arquitectura:** ningún módulo del gateway ni SAM construye ni envía `AgentMsg`.
El gateway solo llama a funciones sobre `AgentRef` (y, hacia fuera, habla HTTP con SAM).

**Resumen (conceptual) de comandos públicos:**

| Comando externo | Descripción |
|-----------------|-------------|
| `interact(agent, req)` | Ejecutar interacción (solo en Idle) |
| `status(agent)` | Consultar estado |
| `info(agent)` | Consultar info completa |
| `attach_logs(agent, subscriber)` | Suscribirse a logs (takeover) |
| `stop_instance(agent, reason)` | Detener instancia (sin delete) |

**Mapeo a SSE (gateway):**
- `AttachLogs` alimenta el SSE de logs de instancia: `GET /sys/agents/:instance_id/logs/stream` (ring buffer + live).
- El SSE de interacción (capability `streaming: true`) se entrega por request vía `sad/streams/sink.StreamSink` (gateway). El actor no es proxy de chunks.
- En v0, que el cliente SSE se desconecte **no** implica cancelación de la ejecución; solo deja de entregarse el stream al cliente.

### Separación público vs interno (canónica)

Para evitar que capas externas (gateway/SAM/adapters) puedan construir accidentalmente eventos internos del actor (p.ej. `WorkerDown`, `ServerDied`, `InteractionDone`), separar el protocolo en dos niveles:

- **Comandos públicos** (lo que el gateway puede pedir **vía la API pública**): `Interact`, `GetStatus`, `GetInfo`, `AttachLogs`, `StopInstance`.
- **Eventos internos** (solo emitidos por bridge/workers): `ProvisioningDone`, `IngestLog`, `InteractionDone`, `WorkerDown`, `ServerDied`.

Patrón idiomático: exponer un `AgentRef` opaco (en `sad/core/agent.gleam`) y funciones públicas para comandos, mientras que el bridge/workers usan `sad/core/agent_internal.gleam` para emitir eventos internos.

**Contrato de frontera (canónico):**
- `sad/core/agent.gleam` (público) expone `type AgentRef` + funciones: `interact/status/info/attach_logs/stop_instance`.
- `sad/core/agent_internal.gleam` (interno) expone funciones *solo para eventos internos*:
  - `provisioning_done(agent: AgentRef, outcome: Result(#(AgentState, Option(Int)), String))`
  - `ingest_log(agent: AgentRef, event: LogEvent)`
  - `interaction_done(agent: AgentRef, result: Result(InteractionResult, InteractionError))`
  - `worker_down(agent: AgentRef, down: Down)`
  - `server_died(agent: AgentRef, exit_code: Int)`
  - `terminate(agent: AgentRef, reason: StopReason)` (solo supervisor: delete/shutdown)

Así, `AgentMsg` puede permanecer no exportado y nadie fuera del core puede construirlo.

| Evento interno | Descripción |
|----------------|-------------|
| `ProvisioningDone(outcome)` | Provisioning terminado (Ready* o Failed) |
| `InteractionDone(result)` | Resultado final |
| `IngestLog(event)` | Log del runner |
| `WorkerDown(down)` | Worker murió |
| `ServerDied(exit_code)` | Servidor continuous murió |

## 4. Estado del actor

Referencia completa (v0): `arquitectura/examples/snippets/agent_runtime_state.gleam`.

Extracto (v0):

```gleam
pub type LogBuffer {
  LogBuffer(lines: Deque(LogEvent), total_bytes: Int)
}

pub type AgentRuntimeState {
  AgentRuntimeState(
    profile: Profile,
    instance_id: InstanceId,
    state: AgentState,
    mode: ActorMode,
    selector: Selector(AgentMsg),
  )
}
```

**Invariantes garantizados por el sistema de tipos:**

| Invariante | Cómo se garantiza |
|------------|-------------------|
| Continuous siempre tiene resource | `ReadyContinuous(params, resource)` - resource no es Option |
| Transient nunca tiene resource | `ReadyTransient(params)` - no hay campo resource |
| No hay `InteractionDone` sin `InFlight` | `ActorMode = Busy(in_flight)` lo hace estructural |
| No hay doble `Interact` | `mode = Idle` requerido para aceptar |
| Worker crash detectado | Monitor en `InteractionHandle` + `WorkerDown` en selector |
| Parámetros siempre resueltos | Actor recibe `ResolvedParams`, no `Parameter` |
| Estado unificado | `AgentState` ADT: Created → Provisioning → ReadyTransient/ReadyContinuous → Stopped → Failed |

## 5. Child spec e inicialización

`StartArgs` está definido en `tipos.md` §13.3 (SSOT de tipos).

**Nota:** `AgentRef` es un handle opaco definido en `sad/core/agent.gleam` (wrapper de `Subject(AgentMsg)`), para que ningún módulo externo pueda construir/enviar mensajes internos del actor.

Referencia completa (v0): `arquitectura/examples/snippets/agent_start_link_init_state.gleam`.

Extracto (v0):

```gleam
pub type AgentDeps {
  AgentDeps(
    artifact_registry: Subject(ArtifactRegistryMsg),
    port_pool: Subject(PortPoolMsg),
    registry: Subject(RegistryMsg),
    bridge: Bridge,
  )
}

pub fn start_link(args: StartArgs, deps: AgentDeps, init_timeout_ms: Int) -> actor.StartResult(AgentRef) {
  ...
}
```

**Nota:** `registry` se usa para emitir `UpdateStatus` y mantener el summary cacheado.

### 5.1 Comportamiento ante fallo de inicialización

Si `init_state` devuelve `Error`:

1. `AgentActor.start_link(...)` devuelve `Error`
2. `AgentManagerActor` responde `StartError` al caller
3. No hay auto-restart del agente en v0 (recreación la decide SAM)

**Nota:** En v0, `init_state` debe ser rápido y casi infalible. Los fallos reales de provisioning
se comunican después vía `ProvisioningDone` y transitan el estado a `Ready*` o `Failed`
sin tumbar al supervisor ni bloquear a `AgentManagerActor`.

## 6. Bucle de mensajes

```gleam
fn handle_message(
  state: AgentRuntimeState,
  msg: AgentMsg,
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  case msg {
    // Comandos externos
    Interact(req, stream_sink, reply_to) -> handle_interact(state, req, stream_sink, reply_to)
    GetStatus(reply_to) -> handle_get_status(state, reply_to)
    GetInfo(reply_to) -> handle_get_info(state, reply_to)
    AttachLogs(subscriber) -> handle_attach_logs(state, subscriber)
    StartInstance -> handle_start_instance(state)
    StopInstance(reason) -> handle_stop_instance(state, reason)
    Terminate(reason) -> handle_terminate(state, reason)

    // Eventos del bridge
    ProvisioningDone(outcome) -> handle_provisioning_done(state, outcome)
    InteractionDone(result) -> handle_done(state, result)
    IngestLog(event) -> handle_ingest_log(state, event)
    
    // Monitoreo de workers y servidores
    WorkerDown(down) -> handle_worker_down(state, down)
    ServerDied(exit_code) -> handle_server_died(state, exit_code)
  }
}
```

## 7. Handler: Interact

Usa pattern matching sobre `ActorMode` para garantizar que solo se acepta en `Idle`:

Referencia completa (v0): `arquitectura/examples/snippets/agent_interact_handler.gleam`.

Extracto (v0):

```gleam
fn handle_interact(
  state: AgentRuntimeState,
  req: AgentRequest,
  stream_sink: Option(StreamSink),
  reply_to: Subject(Result(InteractionResult, InteractionError)),
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  ...
}
```

## 8. Handler: InteractionDone

Para cualquier capability (con o sin streaming), el resultado final llega aquí:

```gleam
fn handle_done(
  state: AgentRuntimeState,
  result: Result(InteractionResult, InteractionError),
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  case state.mode {
    // Estado inválido: recibimos Done sin estar Busy
    // Esto no debería pasar, pero lo manejamos gracefully
    Idle -> {
      // Log warning y continuar
      actor.continue(state)
    }
    
    // Estado esperado: responder y volver a Idle
    Busy(in_flight) -> {
      finalize_interaction(state, in_flight, result)
    }
  }
}
```

## 9. Handler: WorkerDown

Maneja el caso donde el worker del bridge muere inesperadamente:

Referencia completa (v0): `arquitectura/examples/snippets/agent_handler_worker_down.gleam`.

Extracto (v0):

```gleam
fn handle_worker_down(state: AgentRuntimeState, down: process.Down) -> actor.Next(AgentRuntimeState, AgentMsg) {
  ...
}
```

## 11. Handler: ServerDied

Maneja el caso donde el servidor continuous muere inesperadamente:

Referencia completa (v0): `arquitectura/examples/snippets/agent_handler_server_died.gleam`.

Extracto (v0):

```gleam
fn handle_server_died(state: AgentRuntimeState, exit_code: Int) -> actor.Next(AgentRuntimeState, AgentMsg) {
  ...
}
```

**Comportamiento:**
- Si hay interacción en curso, responde error al cliente
- Transita el agente a estado `Failed`
- El agente queda inoperativo hasta que se reinicie manualmente o el supervisor lo recree

## 12. Handler: StopInstance

Referencia completa (v0): `arquitectura/examples/snippets/agent_handler_stop_terminate.gleam`.

Extracto (v0):

```gleam
fn handle_stop_instance(state: AgentRuntimeState, reason: StopReason) -> actor.Next(AgentRuntimeState, AgentMsg) {
  ...
}
```

**Normativa v0 (stop/cancel):**
- `StopInstance` es el mecanismo “público” para abortar ejecución desde el gateway (no existe endpoint de cancelación dedicado).
- Si el agente está en `Busy` (interacción en curso), `StopInstance` MUST intentar abortar el trabajo in-flight:
  - señalar al worker/owner (port/HTTP stream) para que termine,
  - provocar que el actor reciba `InteractionDone(Error(...))` con un error que el cliente pueda interpretar como “cancelled”.
- Si el agente está en `Provisioning`, `StopInstance` MUST abortar provisioning best-effort y transitar a `Stopped`.
- El estado wire no expone `stopping`: el cliente observa el resultado vía `phase=stopped` cuando el stop completó.
- `StopInstance` **no** elimina workspace ni artefactos.
- En v0, `stop` es reversible: `StartInstance` vuelve a arrancar una instancia `Stopped`/`Failed`.
- En `continuous` con `managed_port`, el puerto reservado MUST liberarse al completar `StopInstance` (y en `Failed/Terminate`) y se reasigna durante `StartInstance` (puede cambiar). `assigned_port` es diagnóstico/hint, no identidad estable.

## 12.2 Handler: StartInstance

`StartInstance` permite reactivar una instancia en `Stopped` o reintentar arranque desde `Failed` (sin recrearla en el registry).

**Normativa v0 (start):**
- Idempotente: si el agente está `Provisioning`/`Ready*`, no hace nada.
- Si está `Stopped`/`Failed`, transita a `Provisioning` y arranca de nuevo:
  - transient: vuelve a `ReadyTransient` sin server,
  - continuous: solicita `managed_port` y arranca server; si falla (PoolExhausted), termina en `Failed`.

## 12.1 Handler: Terminate

```gleam
fn handle_terminate(
  state: AgentRuntimeState,
  reason: StopReason,
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  // Terminate: best-effort stop de interacción/servidor y luego terminar el actor.
  let _ = handle_stop_instance(state, reason)
  actor.stop()
}
```

`Terminate` se usa solo desde supervisor (delete/shutdown). El gateway nunca lo llama directamente.
`Terminate` también se usa para rollback best-effort (p.ej. si el manager crea un agente pero falla el `registry.register`).

## 13. Handlers auxiliares

Referencia completa (v0): `arquitectura/examples/snippets/agent_views.gleam`.

Extracto (v0):

```gleam
fn to_status_view(state: AgentRuntimeState) -> types.AgentStatusView {
  ...
}
```

## 14. Gestión del buffer de logs

El buffer mantiene los logs más recientes, eliminando los antiguos cuando se excede el límite:

```gleam
/// Añade un log al buffer, eliminando los más antiguos si excede el límite.
/// Las líneas vienen ordenadas [oldest, ..., newest].
/// O(1) amortizado gracias a deque.
fn append_log(
  buffer: LogBuffer,
  line: LogEvent,
  max_bytes: Int,
) -> LogBuffer {
  let new_lines = deque.push_back(buffer.lines, line)
  // Nota: usamos size aproximado del contenido textual para truncado.
  let new_total = buffer.total_bytes + string.byte_size(line.line)

  case new_total > max_bytes {
    False -> LogBuffer(new_lines, new_total)
    True -> truncate_oldest(new_lines, new_total, max_bytes)
  }
}

/// Elimina líneas antiguas hasta que el buffer quepa en max_bytes.
/// Las líneas vienen ordenadas [oldest, ..., newest].
/// Elimina desde el frente (oldest) en O(1) amortizado.
fn truncate_oldest(
  lines: Deque(LogEvent),
  current_bytes: Int,
  max_bytes: Int,
) -> LogBuffer {
  case current_bytes > max_bytes {
    True -> {
      case deque.pop_front(lines) {
        Ok(#(removed_line, rest)) ->
          truncate_oldest(rest, current_bytes - string.byte_size(removed_line.line), max_bytes)
        Error(_) ->
          // No debería ocurrir si current_bytes > max_bytes, pero mantenemos la invariante.
          LogBuffer(lines, 0)
      }
    }
    False -> LogBuffer(lines, current_bytes)
  }
}
```

Al servir logs (por ejemplo, en `AttachLogs`), convertir con `deque.to_list(buffer.lines)`.

**Regla v0:** `AttachLogs` mantiene un solo subscriber activo; una nueva conexión reemplaza la anterior.

**Características del algoritmo:**
- **Operaciones O(1) amortizado** con `deque` (`push_back`/`pop_front`)
- **Política drop-oldest**: se conservan los logs más recientes
- El límite se configura en `config.toml` con `log_buffer_bytes`
- En v0, SAD no persiste logs a disco (si se requiere histórico, delegar a capas superiores).

**Mejora futura (no v0):** agrupar logs en el bridge y enviar `IngestLogs(List(LogEvent))` en lugar de un mensaje por línea para reducir presión del mailbox del `AgentActor`.

## 15. Registry

El Registry expone una API pública (`registry_api`) y mantiene su protocolo de mensajes como detalle interno.
Los tipos conceptuales están en `tipos.md` §13.2.

**Estado interno del Registry:**

```gleam
import gleam/erlang/process.{type Pid}
import sad/core/agent_internal
import sad/types.{type InstanceId, type ProfileId, type AgentStatusView, type InstanceSummary}

pub type RegistryState {
  RegistryState(
    /// Indice primario: instance_id -> entry.
    by_instance: Dict(InstanceId, RegistryEntry),
    /// Indice secundario: pid -> instance_id (limpieza O(1) en AgentDown).
    by_pid: Dict(Pid, InstanceId),
    /// Selector dinámico para monitores de agentes.
    selector: Selector(RegistryMsg),
  )
}

/// Entrada en el registry con metadatos adicionales.
pub type RegistryEntry {
  RegistryEntry(
    instance_id: InstanceId,
    profile_id: ProfileId,
    summary: InstanceSummary,
    agent: AgentRef,
    pid: Pid,
    monitor: Monitor,
  )
}
```

**Nota v0:** `summary` es el cache de estado usado por `/sys/agents` (evita N+1). Se actualiza con `UpdateStatus`.
El `AgentActor` debe emitir `UpdateStatus` en cada transición de fase/modo relevante.

### 15.1 Flujo de Registro

El registro de un agente sigue este flujo:

```
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ AgentManagerActor │  │ AgentFactorySupervisor │     │    Registry     │     │   AgentActor    │
└────────┬────────┘     └────────┬─────────────┘     └────────┬────────┘     └────────┬────────┘
         │                       │                       │                       │
         │ factory.start_child(args)                      │                       │
         │──────────────────────>│                       │                       │
         │                       │ agent.start_link(...) │                       │
         │                       │──────────────────────────────────────────────>│
         │                       │                       │                       │
         │ Ok(agent_ref)         │                       │                       │
         │<──────────────────────│                       │                       │
         │ Register(status, agent_ref)                  │                       │
         │──────────────────────────────────────────────>│                       │
         │                       │                       │  monitor(agent_pid)   │
         │                       │                       │───────┐               │
         │                       │                       │<──────┘               │
         │                       │                       │                       │
         │                       │   Ok(Nil)             │                       │
         │<──────────────────────────────────────────────│                       │
         │                       │                       │                       │
```

**Pasos:**

1. `AgentManagerActor` recibe orden de crear instancia
2. `AgentManagerActor` pide al `AgentFactorySupervisor` crear el actor (`factory_supervisor.start_child(...)`)
3. `AgentManagerActor` registra atómicamente en el Registry (`registry_api.register`)
4. Registry verifica unicidad, crea monitor y almacena
5. Registry actualiza su selector para escuchar el monitor
6. Registry responde `Ok(Nil)` al `AgentManagerActor`
7. Si `Register` falla (p.ej. `AlreadyExists`), el manager hace rollback: termina el agente recién arrancado (cleanup) y responde error.

### 15.1.1 Handler de Register con Selector Dinámico

```gleam
fn handle_register(
  state: RegistryState,
  status: AgentStatusView,
  agent: AgentRef,
  reply_to: Subject(Result(Nil, RegistryError)),
) -> actor.Next(RegistryState, RegistryMsg) {
  // Verificar unicidad global por instance_id
  let AgentStatusView(profile_id, iid, _lifecycle, _phase, _mode, _port, _reason) = status
  case dict.has_key(state.by_instance, iid) {
    True -> {
      process.send(reply_to, Error(AlreadyExists))
      actor.continue(state)
    }
    False -> {
      let agent_pid = agent_internal.pid(agent)
      let monitor = process.monitor(agent_pid)
      
      let new_selector = state.selector
        |> process.select_specific_monitor(monitor, AgentDown)
      
      let now = now_ms()
      let summary = InstanceSummary(
        status: status,
        registered_at: now,
        status_updated_at: now,
      )
      let entry = RegistryEntry(
        instance_id: iid,
        profile_id: profile_id,
        summary: summary,
        agent: agent,
        pid: agent_pid,
        monitor: monitor,
      )
      
      let new_by_instance = dict.insert(state.by_instance, iid, entry)
      let new_by_pid = dict.insert(state.by_pid, agent_pid, iid)
      let new_state = RegistryState(
        by_instance: new_by_instance,
        by_pid: new_by_pid,
        selector: new_selector,
      )
      
      process.send(reply_to, Ok(Nil))
      
      actor.continue(new_state)
      |> actor.with_selector(new_selector)
    }
  }
}
```

### 15.2 Limpieza Automática

El Registry monitorea todos los agentes registrados. Cuando un agente muere:

```gleam
fn handle_agent_down(
  state: RegistryState,
  down: process.Down,
) -> actor.Next(RegistryState, RegistryMsg) {
  // Extraer PID del Down
  let down_pid = case down {
    process.ProcessDown(pid: pid, ..) -> pid
    _ -> process.self()  // Fallback, no debería ocurrir
  }
  
  // Buscar instance_id en indice pid -> instance_id
  case dict.get(state.by_pid, down_pid) {
    Some(iid) -> {
      case dict.get(state.by_instance, iid) {
        Some(entry) -> {
          // Limpiar monitor
          process.demonitor_process(entry.monitor)
          
          // Actualizar selector para dejar de escuchar el monitor
          let new_selector = state.selector
            |> process.deselect_specific_monitor(entry.monitor)
          
          // Eliminar entrada
          let new_by_instance = dict.delete(state.by_instance, iid)
          let new_by_pid = dict.delete(state.by_pid, down_pid)
          let new_state = RegistryState(
            by_instance: new_by_instance,
            by_pid: new_by_pid,
            selector: new_selector,
          )
          
          actor.continue(new_state)
          |> actor.with_selector(new_selector)
        }
        None -> actor.continue(state)
      }
    }
    None -> actor.continue(state)
  }
}
```

### 15.3 Registry vs Named Subjects

SAD usa un Registry custom en lugar de `process.Name` por:

1. **Unicidad por instance_id:** indice directo `InstanceId -> RegistryEntry` y limpieza O(1) con `Pid -> InstanceId`
2. **Listado por perfil:** necesitamos listar todas las instancias de un perfil
3. **Metadatos:** el registry almacena resumen cacheado de estado + monitor
4. **Cleanup automático:** monitoreo integrado para limpieza
5. **Control explícito:** podemos rechazar registros duplicados

Si se quisieran cachear `Subject`s en otro actor, hay que versionarlos (p.ej. generation del agente) o revalidarlos tras `AgentDown`; de lo contrario se pueden usar PIDs obsoletos tras un restart. SAD prefiere re-resolver vía registry en cada interacción.

### 15.4 Queries del Registry

```gleam
/// Busca un agente por clave.
fn handle_lookup(
  state: RegistryState,
  key: InstanceKey,
  reply_to: Subject(Option(AgentRef)),
) -> actor.Next(RegistryState, RegistryMsg) {
  let InstanceKey(profile_id, iid) = key
  let result = case dict.get(state.by_instance, iid) {
    Some(entry) ->
      case entry.profile_id == profile_id {
        True -> Some(entry.agent)
        False -> None
      }
    None -> None
  }
  
  process.send(reply_to, result)
  actor.continue(state)
}

/// Busca un agente por instance_id (indice directo).
fn handle_lookup_by_instance_id(
  state: RegistryState,
  instance_id: InstanceId,
  reply_to: Subject(Option(AgentRef)),
) -> actor.Next(RegistryState, RegistryMsg) {
  let result = dict.get(state.by_instance, instance_id)
    |> option.map(fn(entry) { entry.agent })

  process.send(reply_to, result)
  actor.continue(state)
}

/// Lista todas las instancias de un perfil.
fn handle_list_by_profile(
  state: RegistryState,
  profile_id: ProfileId,
  reply_to: Subject(List(InstanceId)),
) -> actor.Next(RegistryState, RegistryMsg) {
  let instances = state.by_instance
    |> dict.values
    |> list.filter_map(fn(entry) {
      case entry.profile_id == profile_id {
        True -> Some(entry.instance_id)
        False -> None
      }
    })
  
  process.send(reply_to, instances)
  actor.continue(state)
}

/// Lista resúmenes de todas las instancias.
fn handle_list_all(
  state: RegistryState,
  reply_to: Subject(List(InstanceSummary)),
) -> actor.Next(RegistryState, RegistryMsg) {
  let summaries =
    state.by_instance
    |> dict.values
    |> list.map(fn(entry) { entry.summary })
  
  process.send(reply_to, summaries)
  actor.continue(state)
}

/// Actualiza el status cacheado de una instancia (sin IO).
fn handle_update_status(
  state: RegistryState,
  instance_id: InstanceId,
  status: AgentStatusView,
) -> actor.Next(RegistryState, RegistryMsg) {
  case dict.get(state.by_instance, instance_id) {
    None -> actor.continue(state)
    Some(entry) -> {
      let updated = InstanceSummary(
        status: status,
        registered_at: entry.summary.registered_at,
        status_updated_at: now_ms(),
      )
      let new_entry = RegistryEntry(..entry, summary: updated)
      let new_by_instance = dict.insert(state.by_instance, instance_id, new_entry)
      actor.continue(RegistryState(..state, by_instance: new_by_instance))
    }
  }
}
```

**Nota v0:** `ListByProfile` es O(n) (filtra `dict.values`). Si se vuelve un hot path, agregar un `profile_index: Dict(ProfileId, Set(InstanceId))`.

### 15.5 API Pública del Registry

Para encapsular el protocolo de mensajes del Registry:

Referencia completa (v0): `arquitectura/examples/snippets/registry_api_public.gleam`.

Extracto (v0):

```gleam
pub fn register(registry: Subject(RegistryMsg), status: AgentStatusView, agent: AgentRef, timeout_ms: Int) -> Result(Nil, ApiCallError(RegistryError)) {
  ...
}

pub fn lookup(registry: Subject(RegistryMsg), key: InstanceKey, timeout_ms: Int) -> Result(Option(AgentRef), CallError) {
  ...
}

pub fn lookup_by_instance_id(registry: Subject(RegistryMsg), instance_id: InstanceId, timeout_ms: Int) -> Result(Option(AgentRef), CallError) {
  ...
}

pub fn unregister_by_instance_id(registry: Subject(RegistryMsg), instance_id: InstanceId) -> Nil {
  ...
}

pub fn list_all(registry: Subject(RegistryMsg), timeout_ms: Int) -> Result(List(InstanceSummary), CallError) {
  ...
}

pub fn update_status(registry: Subject(RegistryMsg), instance_id: InstanceId, status: AgentStatusView) -> Nil {
  ...
}
```

**Beneficios:**
- Timeouts explícitos y centralizados
- Funciones de conveniencia (`lookup_by_ids`, `count`)
- Consistente con `agent.gleam`
- Facilita testing y mocking

## 16. Supervisores

### 16.0 Visión general

SAD usa una jerarquía de supervisores OTP estándar:

```
┌───────────────────────────────────────────────────────────────────────────┐
│                          RootSupervisor                                    │
│                       (RestForOne, Permanent)                             │
│                                                                           │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐  ┌──────────────────┐  ┌──────────────────┐  ┌───────────────┐ │
│  │ RegistryActor  │  │ ArtifactReg    │  │ ProfilesActor  │  │ AgentManagerActor │  │ AgentFactorySup   │  │   HttpServer   │ │
│  │  (Permanent)   │  │  (Permanent)   │  │  (Permanent)   │  │  (Permanent)      │  │  (Permanent)      │  │  (Permanent)   │ │
│  │                │  │                │  │                │  │                   │  │  ┌─────────┐       │  │               │ │
│  │ - Índice inst. │  │ - Mapeo ID→    │  │ - SSOT perfiles│  │ - CRUD instancias │  │  │ Agent 1 │       │  │ - Sockets     │ │
│  │ - Monitores    │  │   artefactos   │  │                │  │ - Register/stop   │  │  │ (link)  │       │  │ - SSE         │ │
│  │   agentes      │  │ - Sin monitoreo│  │                │  │                   │  │  └─────────┘       │  │               │ │
│  └────────────────┘  └────────────────┘  └────────────────┘  └──────────────────┘  │  ┌─────────┐       │  └───────────────┘ │
│                                                                                      │  │ Agent 2 │       │                     │
│                                                                                      │  │ (link)  │       │                     │
│                                                                                      │  └─────────┘       │                     │
│                                                                                      └──────────────────┘                     │
└───────────────────────────────────────────────────────────────────────────┘
```

**Nota (shutdown):** `HttpServer` es hijo del `RootSupervisor` y se arranca al final para que, al apagar,
se termine primero (reverse order): deja de aceptar conexiones antes de detener el core.

**Nota:** El ArtifactRegistry NO monitorea agentes. El purge de artefactos y cleanup del
workspace ocurren explícitamente cuando el `AgentManagerActor` procesa `DeleteAgent`
(no en `StopAgent`), para mantener la semántica: stop ≠ delete.

**Decisión v0 (simplicidad + seguridad):**
- Se mantiene `ArtifactRegistryActor` (no hay `ArtifactId` firmado/HMAC).
- Estado mínimo: solo `ArtifactId → #(InstanceId, WorkspacePath, mime)`; sin timestamps, sin índices secundarios.
- Sin lógica: CRUD + `purge_by_instance`. El gateway nunca acepta rutas del cliente y sirve solo por whitelist.

### 16.0.1 Apuntes Gleam/OTP (patrones validados)

Estos puntos están validados en práctica por ejemplos actuales de Gleam OTP (p.ej. `vpribish/small_supervisor`), y se adoptan en SAD v0:

- **Los `Name` no son strings:** `process.new_name("x")` devuelve un valor único; hay que crear los `Name` una sola vez en startup y **pasar el valor** por el árbol. Dos `new_name("x")` no son el mismo nombre.
- **Actores nombrados + discovery por nombre:** preferir `actor.named(name)` y obtener subjects con `process.named_subject(name)`; para factory supervisors usar `factory_supervisor.get_by_name(name)`.
- **`main` no hace trabajo:** arrancar el árbol OTP y quedarse bloqueado (`process.sleep_forever()`). Si `main` termina, el sistema se apaga.
- **Llamadas fail-fast vs borde:** `actor.call` puede tumbar al caller si el callee muere/timeout; en el borde HTTP se usa `call_within` (ver §17.1).
- **Loops:** para loops infinitos, usar recursión en tail-call o un actor dedicado; si el loop debe arrancar “al boot”, dispararlo desde el `run`/initialiser del child spec (self-send de un mensaje `Start`).

### 16.1 Root Supervisor (`sad/core/supervisor.gleam`)

Referencia completa (v0): `arquitectura/examples/snippets/root_supervisor.gleam`.

Extracto (v0):

```gleam
pub opaque type SupervisorRef {
  SupervisorRef(
    supervisor: Supervisor,
    registry: Subject(RegistryMsg),
    artifact_registry: Subject(ArtifactRegistryMsg),
    profiles: Subject(ProfilesMsg),
    agent_manager: Subject(AgentManagerMsg),
  )
}

pub fn start(app_state: AppState, names: RootNames) -> actor.StartResult(SupervisorRef) {
  ...
}
```

Al arrancar desde `main` o tareas de mantenimiento, hacer `let assert Ok(_sup) = supervisor.start(app_state, names)` para crash-ear rápido si falla la topología (nombres registrados, init inválido). Cualquier arranque fuera del árbol debe también pattern-matchear el `Result` y registrar el motivo.

### 16.2 Agent Manager (`sad/core/agent_manager.gleam`)

El `AgentManagerActor` es un actor “manager” que crea/gestiona instancias bajo demanda delegando
la creación de procesos BEAM al `AgentFactorySupervisor` (`gleam/otp/factory_supervisor`).

Los tipos de mensajes (`AgentManagerMsg`, `StartError`, `StopError`) están definidos en
`tipos.md` §13.3 para mantener SSOT de tipos.

#### Decisión v0: usar `AgentFactorySupervisor` (factory supervisor)

En SAD v0 se elige:
- Un `RootSupervisor` estático (`RestForOne`) con un `AgentFactorySupervisor` nombrado.
- Un `AgentManagerActor` que **no linkea manualmente** agentes ni hace `trap_exit`; el `RegistryActor`
  monitorea agentes y es el SSOT de instancias activas.
- Agentes bajo el factory supervisor con `restart_strategy=Temporary` (sin auto-restart): si un agente cae, SAM decide recrearlo.

**Nota v0:** setear explícitamente `restart_strategy=Temporary` en el child spec del factory supervisor; el default de `factory_supervisor` es `Transient` y reinicia en fallos anormales.

**Por qué (valor vs complejidad):**
- En nuestro modelo, “un agente” corresponde principalmente a **1 proceso de sistema operativo** (y su subtree),
  cuyo ciclo de vida lo gestiona el **wrapper** (SIGTERM→SIGKILL). Esto no exige un sub-árbol BEAM por agente.
- El objetivo crítico (“no procesos huérfanos” y “`RestForOne` tumba el subtree de agentes”) se consigue con OTP idiomático:
  al reiniciar el subtree, el factory supervisor se termina y con él todos sus children.
- Reduce superficie de bugs: sin `link`/`trap_exit` manual y sin tracking local de children en el manager.

**Qué garantiza esta decisión:**
- Si cae `RegistryActor` y `RestForOne` reinicia el subtree, no quedan agentes “vivos pero invisibles” (mueren con el factory supervisor).
- La caída de un agente no tumba al manager (no están linkados entre sí) y el `RegistryActor` elimina su entry por monitor.
- `StartAgent` es seguro sin rehidratación: el SSOT de instancias está en `RegistryActor`, no en el manager.

**Nota (rehidratación):** se volvería necesaria si el manager tuviera estado propio indispensable (p.ej. políticas per-instancia,
colas, rate limits o children “deseados” que deben sobrevivir a un restart). En v0 evitamos ese diseño: el manager es lo más stateless posible.

**Cuándo revisarlo:**
- Necesitamos **políticas de restart por agente** (backoff, transient/permanent, shutdown por child) dentro del BEAM.
- Un “agente” pasa a ser un **sub-árbol BEAM** (varios procesos) y queremos supervisarlo como unidad OTP.
- Queremos **introspección/operación** robusta basada en `which_children` (p.ej. reconciliación tras restart) y/o que
  agentes sobrevivan al reinicio del manager gracias a persistencia/rehidratación del Registry/SAM.

Referencia completa (v0): `arquitectura/examples/snippets/agent_manager.gleam`.

Extracto (v0):

```gleam
pub type ManagerDeps {
  ManagerDeps(
    registry: Subject(RegistryMsg),
    artifact_registry: Subject(ArtifactRegistryMsg),
    bridge: Bridge,
    agent_factory: factory_supervisor.Supervisor(StartArgs, agent.AgentRef),
  )
}

pub fn start(app_state: AppState, deps: ManagerDeps, name: Name(AgentManagerMsg)) -> actor.StartResult(Subject(AgentManagerMsg)) {
  ...
}
```

### 16.3 API del AgentManagerActor

```gleam
// sad/core/agent_manager_api.gleam

import gleam/erlang/process.{type Subject}
import sad/otp/safe_call
import sad/otp/safe_call.{type CallError, type ApiCallError}

/// Crea una nueva instancia de agente.
pub fn start_agent(
  manager: Subject(AgentManagerMsg),
  args: StartArgs,
  timeout_ms: Int,
) -> Result(AgentRef, ApiCallError(StartError)) {
  safe_call.call_result_within(manager, timeout_ms, fn(reply_to) { StartAgent(args, reply_to) })
}

/// Detiene una instancia de agente.
pub fn stop_agent(
  manager: Subject(AgentManagerMsg),
  instance_id: InstanceId,
  timeout_ms: Int,
) -> Result(Nil, ApiCallError(StopError)) {
  safe_call.call_result_within(manager, timeout_ms, fn(reply_to) { StopAgent(instance_id, reply_to) })
}

/// Elimina una instancia de agente (stop + cleanup).
pub fn delete_agent(
  manager: Subject(AgentManagerMsg),
  instance_id: InstanceId,
  timeout_ms: Int,
) -> Result(Nil, ApiCallError(DeleteError)) {
  safe_call.call_result_within(manager, timeout_ms, fn(reply_to) { DeleteAgent(instance_id, reply_to) })
}

/// Lista todas las instancias activas.
pub fn list_agents(
  manager: Subject(AgentManagerMsg),
  timeout_ms: Int,
) -> Result(List(InstanceSummary), CallError) {
  safe_call.call_within(manager, timeout_ms, fn(reply_to) { ListAgents(reply_to) })
}
```

**Nota v0:** `DeleteAgent` espera a `Stopped` antes de limpiar workspace. Si el worker de delete muere, responde `DeleteWorkerCrashed`.

### 16.4 Políticas de Reinicio

| Actor | Política | Razón |
|-------|----------|-------|
| `RootSupervisor` | N/A | Es el proceso raíz |
| `RegistryActor` | `Permanent` | Crítico para el sistema, siempre debe existir |
| `ArtifactRegistry` | `Permanent` | Sirve `/artifacts` y purga en delete |
| `ProfilesActor` | `Permanent` | SSOT de perfiles en memoria (reload sin reinicio) |
| `AgentFactorySupervisor` | `Permanent` | Crea agentes bajo demanda; children `Temporary` (sin restart) |
| `AgentManagerActor` | `Permanent` | Debe estar disponible para crear/gestionar instancias |
| `AgentActor` | N/A | En v0 no hay auto-restart de agentes; si un agente cae, SAM debe recrearlo |
### 16.5 Shutdown Ordenado

```gleam
/// Shutdown limpio de todos los agentes.
pub fn shutdown_all(supervisor: SupervisorRef, timeout: Int) -> Nil {
  let agents =
    case agent_manager_api.list_agents(supervisor.agent_manager, timeout) {
      Ok(summaries) -> summaries
      Error(_) -> []
    }
  
  // Terminar a todos en paralelo
  list.each(agents, fn(summary) {
    let instance_id = summary.status.instance_id
    case registry_api.lookup_by_instance_id(supervisor.registry, instance_id, timeout) {
      Ok(Some(agent)) -> agent.terminate(agent, NodeShuttingDown)
      _ -> Nil
    }
  })
  
  // Esperar a que terminen (con timeout)
  let instance_ids = list.map(agents, fn(summary) { summary.status.instance_id })
  wait_for_agents_to_stop(instance_ids, supervisor.registry, timeout)
}

fn wait_for_agents_to_stop(
  instance_ids: List(InstanceId),
  registry: Subject(RegistryMsg),
  remaining_ms: Int,
) -> Nil {
  case remaining_ms <= 0 {
    True -> Nil  // Timeout, continuar con shutdown forzado
    False -> {
      let still_alive = list.filter(instance_ids, fn(iid) {
        case registry_api.lookup_by_instance_id(registry, iid, remaining_ms) {
          Ok(Some(_)) -> True
          _ -> False
        }
      })
      case still_alive {
        [] -> Nil  // Todos terminaron
        _ -> {
          process.sleep(100)
          wait_for_agents_to_stop(still_alive, registry, remaining_ms - 100)
        }
      }
    }
  }
}
```

### 16.6 Flujo de Creación Completo

```
┌─────────────────┐     ┌──────────────────────┐     ┌──────────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│     Gateway     │     │  AgentManagerActor   │     │ AgentFactorySupervisor │     │   AgentActor    │     │    Registry     │
└────────┬────────┘     └────────┬────────┘     └────────┬─────────────┘     └────────┬────────┘     └────────┬────────┘
         │                       │                       │                       │                       │
         │  StartAgent(args)     │                       │                       │                       │
         │──────────────────────>│                       │                       │                       │
         │                       │ factory.start_child(args)                      │                       │
         │                       │──────────────────────>│                       │                       │
         │                       │                       │ agent.start_link(...) │                       │
         │                       │                       │──────────────────────>│                       │
         │                       │                       │                       │  init_state           │
         │                       │                       │                       │───────┐               │
         │                       │                       │                       │<──────┘               │
         │                       │  Ok(agent_ref)        │                       │                       │
         │                       │<──────────────────────│                       │                       │
         │                       │  Register(status, agent_ref)                  │                       │
         │                       │──────────────────────────────────────────────────────────────────────>│
         │                       │                       │                       │                       │  monitor(pid)
         │                       │                       │                       │                       │───────┐
         │                       │                       │                       │                       │<──────┘
         │                       │  Ok(Nil)             │                       │                       │
         │                       │<──────────────────────────────────────────────────────────────────────│
         │  Ok(agent_ref)        │                       │                       │                       │
         │<──────────────────────│                       │                       │                       │
```

## 17. API Pública del Actor

Para encapsular el protocolo de mensajes y facilitar el uso del actor, se provee
un módulo de API pública (`sad/core/agent.gleam`) que expone un `AgentRef` opaco.
El protocolo `AgentMsg` y sus constructores no se exportan: así el compilador impide
que Gateway/SAM (o cualquier otro módulo) pueda enviar mensajes internos (`WorkerDown`,
`IngestLog`, etc.) directamente.

```gleam
import gleam/erlang/process.{type Subject}
import sad/core/agent.{type AgentRef}
import sad/otp/safe_call.{type CallError}
import sad/types.{
  type AgentRequest, type InteractionResult, type InteractionError,
  type AgentStatusView, type AgentInfoView, type LogEvent, type StreamEvent,
  type StopReason,
}

pub fn interact(agent: AgentRef, request: AgentRequest) -> Result(InteractionResult, InteractionError)
pub fn status(agent: AgentRef, timeout_ms: Int) -> Result(AgentStatusView, CallError)
pub fn info(agent: AgentRef, timeout_ms: Int) -> Result(AgentInfoView, CallError)
pub fn attach_logs(agent: AgentRef, subscriber: Subject(LogEvent)) -> Nil
pub fn start_instance(agent: AgentRef) -> Nil
pub fn stop_instance(agent: AgentRef, reason: StopReason) -> Nil
```

**Beneficios:**
- Encapsula el protocolo de mensajes
- Facilita testing (mock del Subject)
- Sigue el patrón idiomático de Gleam/OTP
- Centraliza timeouts

### 17.1 Política de llamadas (call vs call_within)

- `process.call`/`actor.call`: fail-fast (pueden panic en timeout/down). Útil **solo** entre procesos supervisados dentro del árbol OTP (queremos crash + restart).
- `sad/otp/safe_call.call_within` (reply_subject + monitor + selector_receive): **patrón único** para bordes (gateway, SSE writers, workers efímeros). Devuelve `Result(_, CallError)` y permite mapear `Disconnected → 503` y `TimedOut → 504` sin tumbar el proceso HTTP.
- Regla v0: ningún handler HTTP (mist) debe depender de `actor.call` directa (riesgo de respuesta incompleta); en su lugar, el gateway usa `call_within` y construye Problem Details.
- Timeouts se centralizan en `SadConfig` (p.ej. `call_timeout_ms`, `sink_call_timeout_ms`) para evitar bloqueos prolongados.

Referencia (v0): `arquitectura/examples/snippets/otp_safe_call.gleam`.

## 18. Testing de Actores

Ver `tests.md` §3.7-3.10 para la lista completa de tests de actores.

### 18.1 Principios

1. **Testear el protocolo, no la implementación**: Enviar mensajes y verificar respuestas
2. **Usar subjects reales**: No mockear el actor, crear instancias reales
3. **Aislar efectos**: El bridge se puede mockear para tests unitarios
4. **Tests de integración**: Usar el bridge real para tests E2E

### 18.2 Ejemplo ilustrativo

```gleam
	import gleeunit/should
	import gleam/erlang/process
	import sad/core/agent
	import sad/core/agent_internal
	import sad/bridge/bridge.{Bridge}

pub fn interact_when_idle_test() {
  // Arrange: crear agente con bridge fake (sin IO real)
  let mock_response = Ok(InteractionResult(
    data: ResponseData(content: Some("Hello"), metadata: dict.new()),
    artifacts: [],
    trace_id: trace_id("test-123"),
  ))
  
  let args = test_args_with_resolved_params()
	  let bridge = Bridge(
	    start_provisioning: fn(_ctx, _agent) { process.spawn_unlinked(fn() { Nil }) },
	    start_interaction: fn(_ctx, _req, agent_ref, _timeout_ms, _streaming, _sink) {
	      process.spawn_unlinked(fn() { agent_internal.interaction_done(agent_ref, mock_response) })
	    },
	    cancel_interaction: fn(_handle) { Nil },
	    stop_server: fn(_resource) { Nil },
	  )
  let deps = AgentDeps(
    test_artifact_registry_subject(),
    test_port_pool_subject(),
    test_registry_subject(),
    bridge,
  )
  let assert Ok(actor.Started(_pid, agent)) = agent.start_link(args, deps, 10_000)
  
	  // Act
	  let request = test_request()
	  let result = agent.interact(agent, request)
  
  // Assert
  result |> should.be_ok
  let assert Ok(ir) = result
  ir.data.content |> should.equal(Some("Hello"))
  
	  // Cleanup (terminar proceso en test)
	  agent.terminate(agent, SupervisorCleanup)
	}
```

## 19. Puntos de emisión de SystemLogKind

Para habilitar métricas desde logs estructurados, emitir `system_log()` en estos puntos:

**Decisión v0:** SAD no integra `:telemetry` directamente. `SystemLogKind` es la interfaz estable:
SAM/ops pueden transformar logs → métricas/telemetry/Prometheus sin tocar el core.

### 19.1 Mapa de emisión

| Evento | Dónde emitir | Labels recomendados |
|--------|--------------|---------------------|
| `AgentStarted` | `init_state()` tras crear estado | `profile`, `lifecycle` |
| `AgentStopped` | `handle_stop_instance()` al transitar a `Stopped` | `profile`, `reason` |
| `ProvisioningStarted` | Worker de provisioning (spawn en initialiser) antes de `provision_and_start()` | `profile` |
| `ProvisioningFinished` | Worker de provisioning tras éxito (antes de `ProvisioningDone(Ok)`) | `profile`, `duration_ms` |
| `ProvisioningFailed` | Worker de provisioning tras error (antes de `ProvisioningDone(Error)`) | `profile`, `error` |
| `InteractionStarted` | `start_interaction()` | `profile`, `capability` |
| `InteractionFinished` | `finalize_interaction()` con `Ok` | `profile`, `capability`, `duration_ms` |
| `InteractionFailed` | `finalize_interaction()` con `Error` | `profile`, `capability`, `error_kind` |
| `HealthCheckFailed` | `bridge/client.health_check()` rama error | `profile`, `status_code` |
| `ServerDied` | `handle_server_died()` | `profile`, `exit_code` |

### 19.2 Ejemplo de implementación

Referencia completa (v0): `arquitectura/examples/snippets/system_log_emission_example.gleam`.

Extracto (v0):

```gleam
// En init_state():
let _ = system_log(AgentStarted, labels, None, instance_id)

// En start_interaction():
let _ = system_log(InteractionStarted, labels, Some(req.trace_id), instance_id)
```

### 19.3 Uso para métricas

Con logs estructurados en formato `kind=<kind> <labels>`, las métricas se derivan con:

```bash
# Promtail/Fluentd: contar eventos por tipo
grep "kind=interaction_finished" /var/log/sad.log | wc -l

# Calcular latencia P99 de interacciones
grep "kind=interaction_finished" /var/log/sad.log \
  | jq -r '.duration_ms' \
  | percentile 99
```

## 20. Coherencia con tipos.md

| Concepto | tipos.md | actores.md |
|----------|----------|------------|
| Modo del actor | `ActorMode { Idle, Busy(InFlight) }` | Usado en `AgentRuntimeState.mode` |
| Estado del agente (runtime) | `AgentState` (opaco: Created/Provisioning/ReadyTransient/ReadyContinuous/Stopped/Failed) | Campo `state` en `AgentRuntimeState` |
| Funciones de estado | `is_created()`, `is_provisioning()`, `is_ready()`, `is_failed()`, `get_resource()`, `get_params()` | Usadas para introspección del estado |
| Vista de estado (wire) | `AgentStatusView`, `AgentInfoView` + `AgentPhase` + `AgentRunMode` | Serializado por gateway; no incluye params ni recursos BEAM |
| Resultado de interacción | `InteractionResult`, `InteractionError` | Usado en `AgentMsg.InteractionDone` |
| Request | `AgentRequest` | Importado de tipos.md |
| Logs | `LogEvent`, `LogSource` | Importados de tipos.md |
| Streaming | `StreamEvent` (genérico: `ContentChunk`, `StreamStarted`, etc.) | Importados de tipos.md, usados por gateway/adapters |
| Handle de interacción | `InteractionHandle` (opaco con pid + monitor) | Usado para monitoreo de workers |
| Selector | `Selector(AgentMsg)` | Campo dinámico en `AgentRuntimeState` |
| Parámetros resueltos | `ResolvedParams` | Recibido en `StartArgs`, nunca resuelto por el actor |
| Errores de resolución | `ParamResolutionError` | NO importado (el actor no resuelve) |
