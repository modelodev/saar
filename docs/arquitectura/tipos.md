# Tipos y modelos en Gleam

Este documento concentra las definiciones de tipos usadas en SAD. Sigue los principios:
- **Tipos opacos** solo para invariantes reales (IDs, paths seguros, estados con reglas)
- **Tipos transparentes** para "bolsas de datos" sin invariantes
- **Dynamic solo en fronteras** (wire format)
- **Fail-fast**: sin fallbacks silenciosos

Contrato de IDs:
- **InstanceId**: slug ASCII `[A-Za-z0-9_-]`, longitud 1..64; constructor valida formato y retorna `Result(InstanceId, InstanceIdError)`.

**Nota de alcance (importante):** este documento incluye tanto tipos de **dominio/wire** (sin tipos OTP)
como tipos de **mensajería OTP interna** (que sí usan `Subject`/`Pid`). En el repo:
- `sad/types.gleam`: dominio + wire (sin `Subject`/`Pid`/`Monitor`)
- `sad/core/messages.gleam`: mensajes OTP internos (con `Subject`, etc.)
Las secciones marcadas como `FILE: ...` indican el archivo real donde deben implementarse.

## Referencia de implementación (v0)

El cuerpo completo de referencia de `sad/types.gleam` vive en `arquitectura/examples/snippets/types.gleam`.
Este documento mantiene el **contrato** y extractos clave (regla: evitar bloques de código largos; ~40 líneas máx por bloque).


**Nota sobre FFI:** La función `now_ms()` está implementada en `sad/ffi.gleam`.
Ver `bridge.md` §FFI para detalles de la implementación.

## 12. Vistas de instancia (wire)

```gleam
/// Resumen de instancia para listados (cacheado).
pub type InstanceSummary {
  InstanceSummary(
    status: AgentStatusView,
    registered_at: Int,
    status_updated_at: Int,
  )
}
```

**Nota v0:** `status` es cacheado y puede estar levemente desfasado; el endpoint de estado expone la vista live.
`registered_at` y `status_updated_at` están en milliseconds (`now_ms()`).

## 13. Protocolos de mensajes (OTP internos)

Define protocolos internos de actores (solo tipos, sin lógica).
La API pública del actor NO expone `Subject(AgentMsg)` ni constructores: expone un handle opaco `AgentRef` + funciones (`agent`).

## 13.1 AgentMsg - Protocolo del AgentActor

```gleam
// Ubicación: sad/core/agent.gleam
import gleam/erlang/process.{type Subject, type Down}
import sad/streams/sink.{type StreamSink}

/// Protocolo interno de mensajes del AgentActor (no exportado).
type AgentMsg {
  // Comandos públicos (solo vía funciones de sad/core/agent.gleam)
  /// Si `stream_sink` es `Some`, el bridge entrega chunks al `StreamSink` (request-scoped)
  /// y el actor solo recibe `InteractionDone` (no es proxy de chunks).
  Interact(
    AgentRequest,
    stream_sink: Option(StreamSink),
    Subject(Result(InteractionResult, InteractionError)),
  )
  GetStatus(Subject(AgentStatusView))
  GetInfo(Subject(AgentInfoView))
  AttachLogs(Subject(LogEvent))
  /// Arranca una instancia detenida o fallida (stop reversible).
  /// En continuous con `managed_port`, reasigna puerto durante provisioning.
  StartInstance
  /// Detiene la instancia (transita a `Stopped`) sin eliminar artefactos ni workspace.
  StopInstance(StopReason)
  /// Termina el proceso BEAM del actor (delete/shutdown). No es API del gateway.
  Terminate(StopReason)

  // Eventos internos (desde bridge)
  // Resultado de provisioning/arranque (asíncrono, para evitar bloquear init/start_child).
  // Ok: `AgentState` ya en `Ready*` + `assigned_port` (si aplica).
  // Error: motivo safe-to-log; el actor transita a `Failed`.
  ProvisioningDone(Result(#(AgentState, Option(Int)), String))
  InteractionDone(Result(InteractionResult, InteractionError))
  IngestLog(LogEvent)
  WorkerDown(Down)
  ServerDied(exit_code: Int)
}

/// Handle público del agente: referencia opaca al actor.
/// Internamente contiene el Subject(AgentMsg), pero no se expone.
pub opaque type AgentRef {
  AgentRef(subject: Subject(AgentMsg))
}
```

**Nota importante:** `AgentRef` no cruza HTTP (no existe fuera del nodo SAD). SAM opera con `instance_id`;
el gateway resuelve `instance_id → AgentRef` vía `Registry`.

### Invariantes AgentMsg

| Mensaje | Precondición | Postcondición |
|---------|--------------|---------------|
| `Interact` | Actor en Idle | Actor en Busy o error |
| `GetStatus` | Ninguna | Respuesta inmediata |
| `AttachLogs` | Ninguna | Suscriptor anterior reemplazado |
| `StartInstance` | Ninguna | Si estaba `Stopped`/`Failed` inicia arranque; si ya estaba en `Ready*`/`Provisioning` es no-op |
| `StopInstance` | Ninguna | Actor transita a `Stopped` |
| `Terminate` | Ninguna | Actor termina |
| `ProvisioningDone` | Actor en Provisioning | Actor en Ready* o Failed |
| `InteractionDone` | Actor en Busy | Actor en Idle |
| `WorkerDown` | Actor en Busy | Actor en Idle + error |

**Stop vs Terminate (normativa v0):**
- `StopInstance` es el comando que el gateway puede provocar (vía API pública): cancela best-effort provisioning/interacción y deja el actor vivo en `Stopped` para diagnóstico.
- `Terminate` es exclusivamente interno (delete/shutdown/rollback): best-effort stop y luego termina el proceso BEAM del actor.
 - `StartInstance` es el comando que el gateway puede provocar para volver a arrancar una instancia `Stopped`/`Failed` (stop reversible).

### API interna (agent_internal)

Además de la API pública (`sad/core/agent.gleam`), SAD define una API **interna** para inyectar
eventos desde bridge/workers sin exponer constructores de `AgentMsg`.

Ubicación: `sad/core/agent_internal.gleam` (solo para código interno de SAD).

Contrato (funciones expuestas):

```gleam
pub fn provisioning_done(
  agent: AgentRef,
  outcome: Result(#(AgentState, Option(Int)), String),
) -> Nil
pub fn ingest_log(agent: AgentRef, event: LogEvent) -> Nil
pub fn interaction_done(
  agent: AgentRef,
  result: Result(InteractionResult, InteractionError),
) -> Nil
pub fn worker_down(agent: AgentRef, down: Down) -> Nil
pub fn server_died(agent: AgentRef, exit_code: Int) -> Nil
```

## 13.2 RegistryMsg - Protocolo del Registry

```gleam
// Ubicación: sad/core/messages.gleam
import sad/core/agent.{type AgentRef}

/// Clave compuesta para identificar una instancia.
/// Nota v0: `instance_id` es unico globalmente (independiente de `profile_id`).
/// El Registry indexa por `instance_id` y mantiene `profile_id` en la entrada; `InstanceKey`
/// se conserva por compatibilidad del protocolo y listados legacy.
pub type InstanceKey {
  InstanceKey(profile_id: ProfileId, instance_id: InstanceId)
}

/// Protocolo de mensajes del Registry.
pub type RegistryMsg {
  Register(AgentStatusView, AgentRef, Subject(Result(Nil, RegistryError)))
  Unregister(InstanceKey)
  UnregisterByInstanceId(InstanceId)
  Lookup(InstanceKey, Subject(Option(AgentRef)))
  LookupByInstanceId(InstanceId, Subject(Option(AgentRef)))
  ListByProfile(ProfileId, Subject(List(InstanceId)))
  ListAll(Subject(List(InstanceSummary)))
  UpdateStatus(InstanceId, AgentStatusView)
  AgentDown(Down)
}

/// Errores del registry.
pub type RegistryError {
  AlreadyExists
  RegistryFull
}
```

## 13.3 AgentManagerMsg - Protocolo del Manager

Referencia completa (v0): `arquitectura/examples/snippets/core_messages_agent_manager.gleam`.

Extracto (v0):

```gleam
// Ubicación: sad/core/messages.gleam
import sad/core/agent as agent

pub type StartArgs {
  StartArgs(
    /// Snapshot del perfil en el momento de creación (v0).
    /// `POST /sys/reload-profiles` solo afecta a nuevas instancias.
    profile: Profile,
    instance_id: InstanceId,
    params: ResolvedParams,
    workspace: String,
    config: SadConfig,
  )
}
```

**Normativa v0 (`StartArgs`):**
- `profile` MUST ser un snapshot completo (del `ProfilesActor`) en el momento de `StartAgent`; el actor no vuelve a consultar perfiles.
- `params` MUST venir resuelto; el `AgentActor` no resuelve params ni toca secretos fuera de `ResolvedParams`.
- `StartArgs` SHOULD ser autocontenido para permitir que `POST /sys/reload-profiles` no afecte a instancias existentes.

```gleam
pub type AgentManagerMsg {
  StartAgent(StartArgs, Subject(Result(agent.AgentRef, StartError)))
  StopAgent(InstanceId, Subject(Result(Nil, StopError)))
  DeleteAgent(InstanceId, Subject(Result(Nil, DeleteError)))
  DeleteWorkerDone(InstanceId, Result(Nil, DeleteError))
  DeleteWorkerDown(Down)
  ListAgents(Subject(List(InstanceSummary)))
}
```

**Nota v0:** `StopAgent` y `DeleteAgent` usan `InstanceId` (unico globalmente).

## 13.4 ArtifactRegistryMsg - Protocolo del Registro de Artefactos

Referencia completa (v0): `arquitectura/examples/snippets/core_messages_artifact_registry.gleam`.

Extracto (v0):

```gleam
pub opaque type ArtifactId {
  ArtifactId(String)
}

pub type ArtifactRegistryMsg {
  RegisterArtifact(path: WorkspacePath, mime: String, instance_id: InstanceId, reply_to: Subject(ArtifactId))
  LookupArtifact(artifact_id: ArtifactId, reply_to: Subject(Option(ArtifactEntry)))
  PurgeByInstance(instance_id: InstanceId, reply_to: Subject(Int))
}
```

### Invariantes ArtifactRegistry

| Operación | Garantía |
|-----------|----------|
| `RegisterArtifact` | Siempre genera UUID único |
| `LookupArtifact` | Devuelve entry si existe (independiente del estado del agente) |
| `PurgeByInstance` | Elimina todos los artefactos de la instancia (sin fallos; devuelve count) |
| Estado mínimo (v0) | Solo `ArtifactId → #(InstanceId, WorkspacePath, mime)` (sin índices secundarios, sin timestamps) |
| Path validation | `WorkspacePath` ya validado; el gateway además hace lectura **symlink-safe** (defensa en profundidad) |

### Ciclo de vida de artefactos

```
┌─────────────────────────────────────────────────────────────────────┐
│                 CICLO DE VIDA DE ARTEFACTOS                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Interacción genera artefacto                                       │
│      │                                                              │
│      ▼                                                              │
│  ArtifactRegistry.RegisterArtifact(path, mime, instance_id)         │
│      │                                                              │
│      ▼                                                              │
│  artifact_id incluido en InteractionResult                          │
│      │                                                              │
│      │    Cliente puede descargar: GET /artifacts/{id}              │
│      │    (mientras la instancia exista)                            │
│      ▼                                                              │
│  DELETE /agents/{profile}/instances/{id}                            │
│      │                                                              │
│      ▼                                                              │
│  AgentManagerActor.handle_delete_agent()                             │
│      │                                                              │
│      ├──► agent.stop_instance(agent, UserRequested)                 │
│      │                                                              │
│      ├──► workspace.cleanup(config.workspaces_directory, instance_id)│
│      │                                                              │
│      ├──► artifact_registry_api.purge_by_instance(instance_id)      │
│      │                                                              │
│      └──► port_pool.release(instance_id) (si aplica)                │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

**Nota:** El ArtifactRegistry NO monitorea agentes. El cleanup es explícito
en `DeleteAgent` (y por tanto en DELETE de la instancia). Esto garantiza que
los artefactos existen mientras el cliente no haga delete, dándole tiempo para descargarlos.

**Retención (v0):** SAD no implementa TTL/GC automático. Los artefactos viven mientras la instancia exista.
En `DeleteAgent`, SAD hace `purge_by_instance` de forma determinista; el cleanup de filesystem es best-effort
(si falla, la instancia puede permanecer, pero los ArtifactIds dejan de resolverse: rollback de seguridad).

**Operabilidad:** si el cliente no llama a delete, workspaces/artefactos se acumulan. SAD no hace GC automático;
la mitigación es tooling administrativo (fuera del core) que liste instancias `Stopped`/antiguas y ejecute deletes en lote.

## 13.5 ProfilesMsg - Protocolo del ProfilesActor

Referencia completa (v0): `arquitectura/examples/snippets/core_messages_profiles.gleam`.

Extracto (v0):

```gleam
// Ubicación: sad/core/messages.gleam
pub type ProfilesMsg {
  SetProfiles(Dict(ProfileId, Profile), Subject(Int))
  GetProfile(ProfileId, Subject(Option(Profile)))
  ListProfiles(Subject(List(ProfileId)))
}
```

## 13.6 Port pool (`sad/port_pool.gleam`)

El port pool es un helper **puro** (sin procesos OTP) que reserva puertos dentro de un rango dedicado
para agentes `continuous` con `network_mode=managed_port`.

Referencia completa (v0): `arquitectura/examples/snippets/port_pool.gleam`.

Extracto (v0):

```gleam
pub type PortPoolError {
  PoolExhausted
  InvalidRange
  PortInUse
  BindCheckFailed(reason: String)
  NoAvailablePortAfterRetries(attempts: Int)
}

pub type PortCheckError {
  CheckPortInUse
  CheckBindFailed(reason: String)
}

pub fn allocate(pool: PortPool, instance_id: InstanceId) -> Result(#(PortPool, Int), PortPoolError)
pub fn allocate_checked(pool: PortPool, instance_id: InstanceId, check: fn(Int) -> Result(Nil, PortCheckError)) -> Result(#(PortPool, Int), PortPoolError)
pub fn release(pool: PortPool, instance_id: InstanceId) -> PortPool
```

**Nota de disponibilidad (v0):**
- `allocate` es *best-effort* respecto al SO (solo respeta reservas en memoria).
- `allocate_checked` permite inyectar un bind-check real; si todos los candidatos están ocupados retorna `PortInUse` (un solo candidato) o `NoAvailablePortAfterRetries`, y si el check falla retorna `BindCheckFailed`.

## 13.7 PortPoolMsg - Protocolo del PortPoolActor (si `managed_port`)

El port pool es un recurso compartido (reservas únicas por `InstanceId`). En v0 se modela como un actor dedicado
(`PortPoolActor`) que encapsula el helper puro `sad/port_pool.gleam` y actúa como SSOT de reservas.

Referencia completa (v0): `arquitectura/examples/snippets/core_messages_port_pool.gleam`.

Extracto (v0):

```gleam
// Ubicación: sad/core/messages.gleam
import gleam/erlang/process.{type Subject}

pub type PortPoolMsg {
  Allocate(instance_id: InstanceId, reply_to: Subject(Result(Int, PortPoolError)))
  Release(instance_id: InstanceId, reply_to: Subject(Nil))
}
```

**Semántica v0:**
- `PoolExhausted` MUST traducirse a un fallo estable `PORT_POOL_EXHAUSTED` (safe-to-log) durante provisioning.
- `PortInUse` MUST traducirse a un fallo estable `PORT_IN_USE` (safe-to-log) durante provisioning.
- `BindCheckFailed` MUST traducirse a un fallo estable `PORT_BIND_FAILED` (safe-to-log) durante provisioning.
- Si el puerto se ocupa entre el bind-check y el arranque real, el provisioning falla **rápido** con `PORT_IN_USE` (sin reintentos).
- En v0, el puerto reservado se libera en `delete` (y en rollback/terminate), no en `stop`.

## 14. SSE (`sad/sse.gleam`)

Helpers mínimos y estables para formateo SSE, usados por gateway/adapters.
Nota: esto NO vive en `sad/types.gleam` para mantener el dominio libre de tipos OTP.

## 14.1 API SSE

```gleam
import gleam/json.{type Json}

/// Formatea JSON como línea SSE: "data: <json>\n\n"
pub fn line(payload: Json) -> String {
  "data: " <> json.to_string(payload) <> "\n\n"
}

/// Evento con tipo nombrado: "event: <type>\ndata: <json>\n\n"
pub fn named_event(event_type: String, payload: Json) -> String {
  "event: " <> event_type <> "\n" <>
  "data: " <> json.to_string(payload) <> "\n\n"
}

/// Comentario SSE (keep-alive): ": <text>\n\n"
pub fn comment(text: String) -> String {
  ": " <> text <> "\n\n"
}
```

## 14.2 Uso en adapters

```gleam
// En sad/adapters/agui.gleam
import sad/sse.{line}

pub fn to_sse(event: AgUiEvent) -> String {
  event |> to_json |> line
}

// En sad/adapters/a2a.gleam
import sad/sse.{line}

pub fn to_sse(event: A2AStreamEvent) -> String {
  event |> to_json |> line
}
```
