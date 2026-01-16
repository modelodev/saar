# SAAR v3 – Arquitectura

**Sofias' Agent Driver** — Implementación Gleam/BEAM

---

## 1. Propósito

SAAR es un **adaptador universal de agentes**. Resuelve un problema fundamental: cada agente de IA (Aider, Vanna, GPT-Researcher, LightRAG, etc.) tiene su propia forma de ejecutarse y comunicarse. SAAR abstrae esa heterogeneidad y expone una interfaz homogénea.

### Problema

```
Sin SAAR:
                    ┌─────────────┐
                    │   Cliente   │
                    └──────┬──────┘
                           │
       ┌───────────────────┼───────────────────┐
       │                   │                   │
       ▼                   ▼                   ▼
  CLI + stdin         HTTP REST          WebSocket
  (aider)             (vanna)            (custom)
       │                   │                   │
       ▼                   ▼                   ▼
  JSON propio         JSON propio         Protocolo X
```

El cliente debe conocer e implementar la interfaz específica de cada agente.

### Solución

```
Con SAAR:
                    ┌─────────────┐
                    │   Cliente   │
                    └──────┬──────┘
                           │
                 Protocolo A2A / AG-UI / A2UI
                    (interfaz homogénea)
                           │
                           ▼
                    ┌─────────────┐
                    │     SAAR     │
                    └──────┬──────┘
                           │
                    Perfiles declarativos
                    (traducción)
                           │
       ┌───────────────────┼───────────────────┐
       ▼                   ▼                   ▼
     aider              vanna              custom
```

El cliente habla un único protocolo. SAAR traduce.

### Capacidades funcionales

| Capacidad | Descripción |
|-----------|-------------|
| **Abstracción de agentes** | Interactuar con cualquier agente sin conocer su implementación |
| **Perfiles declarativos** | Describir agentes en JSON sin escribir código |
| **Protocolo A2A** | Interoperabilidad con ecosistema de agentes (Google, AutoGen, etc.) |
| **Protocolo AG-UI** | Streaming de respuestas hacia interfaces de usuario |
| **Protocolo A2UI** | UI declarativa por streaming (JSONL) para interfaces agent-driven (render nativo en el cliente) |
| **Gestión de ciclo de vida** | Crear, monitorear y destruir instancias de agentes |
| **Workspaces aislados** | Cada instancia opera en un directorio seguro |

### Tipos de agentes soportados

| Tipo | Ejemplo | Cómo funciona |
|------|---------|---------------|
| **Transient** | aider, gpt-researcher | Proceso efímero por interacción (CLI) |
| **Continuous** | vanna, lightrag | Servidor persistente (HTTP) |

### Usuarios y casos de uso

SAAR es **infraestructura**, no un producto para usuario final. Sus usuarios son:

| Usuario | Qué hace con SAAR |
|---------|------------------|
| **Operadores/DevOps** | Despliegan y gestionan instancias de agentes |
| **Sistemas** | Orquestadores, marketplaces e interfaces que consumen la API |

**Productos que se construyen sobre SAAR:**
- Stores y marketplaces de agentes
- Interfaces conversacionales multi-agente
- Plataformas de orquestación de agentes

**Desarrolladores de agentes** no son usuarios directos de SAAR, pero se benefician de conocer el formato de perfiles para que sus agentes sean fácilmente desplegables por cualquier operador que use SAAR.

**Modelo de amenaza (v0):** aunque SAM/orquestadores sean consumidores principales, SAAR debe asumirse alcanzable por **clientes externos no confiables** (misconfiguración, reverse proxy, exposición accidental). Por eso, la arquitectura exige auth por API key en casi todo el gateway y trata `/artifacts` y `/ui` como superficies sensibles (whitelist de artefactos, paths seguros, proxy HTTP-only, no forward de credenciales). En particular, el proxy `/ui` **no es un open proxy**: el destino se deriva solo del estado del agente, se rechaza traversal/WS y no se forwardean credenciales.

**Flujos principales:**
1. **Provisión de perfiles** — Describir agentes en JSON
2. **Gestión de instancias** — Crear, monitorear y eliminar agentes
3. **Interacción** — Ejecutar capabilities de agentes

---

## 2. Documentos

| Documento | Contenido |
|-----------|-----------|
| [tipos.md](./tipos.md) | SSOT de tipos: dominio + contratos internos (mensajes) |
| [actores.md](./actores.md) | Core OTP: FSM, supervisores, registry |
| [bridge.md](./bridge.md) | IO: ports, HTTP client, decoders, FFI |
| [gateway.md](./gateway.md) | HTTP API: endpoints, auth, entrypoint |
| [protocolos.md](./protocolos.md) | Wire formats: A2A, AG-UI, runner contract |
| [protocolos_runner.md](./protocolos_runner.md) | Contrato detallado de runners + wrapper |
| [integracion.md](./integracion.md) | Cómo integrar agentes (perfil+runner+adapters) |
| [config.md](./config.md) | Perfiles, parámetros, workspaces |
| [operaciones.md](./operaciones.md) | Deps, ADRs, CLI, riesgos |
| [tests.md](./tests.md) | Estrategia de testing |
| [examples/config](./examples/config) | Ejemplo de `config.toml` |
| [examples/runners](./examples/runners) | Runners genéricos y guía de stop |
| [examples/profiles](./examples/profiles) | Perfiles de ejemplo |
| [examples/wrapper_pid_namespace.md](./examples/wrapper_pid_namespace.md) | Wrapper rootless (referencia) |

---

## 2.1 SSOT de ejecucion y decisiones

- Plan vigente: `docs/plan/README.md`
- Decisiones cerradas: `docs/plan/decisions.md`
- Config keys/defaults: `docs/plan/limits.toml` (tabla generada en `docs/plan/limits.md`)

### 2.1 Checklist de implementación (v0)

- `tipos.md`: tipos y mensajes (SSOT) sin ramas “compat/alternativas”.
- `actores.md`: `AgentActor` como control-plane; evento terminal único `InteractionDone(...)`; `Stop` ≠ `Delete`.
- `actores.md`: topología OTP (`RootSupervisor` RestForOne; `RegistryActor` antes del subtree dependiente; `AgentManagerActor` antes que `AgentFactorySupervisor`; agentes como children `Temporary` del factory supervisor).
- Regla DI: crear `Name`s una vez en startup y pasarlos; obtener `Subject`s por nombre solo en el root y pasar `Subject`s/`Bridge` por `Deps` (sin “lookups” dispersos por el sistema).
- `bridge.md`: ports con `open_port` + `use_stdio`; STDOUT único canal JSONL; `stderr` fuera de contrato.
- `bridge.md`: streaming data-plane **solo** worker → `saar/streams/sink.StreamSink` con batching (`InteractionStreamConfig`) y degradación a discard (sin buffers infinitos).
- `gateway.md`: `saar/streams/sink.StreamSink` por request streaming (SSE writer) + ack/timeout; disconnect no cancela ejecución.
- `gateway.md`: SSE de logs (instancia) usa ring buffer + takeover; logs best-effort (drop/coalesce permitido).
- `gateway.md`: artefactos solo por UUID; `WorkspacePath` valida segmentos (no `..`); lectura de ficheros symlink-safe.
- `protocolos_runner.md`: runners emiten eventos JSONL (`t="log"|"chunk"|"result"`); wrapper nunca escribe bytes libres en STDOUT.

## 3. Arquitectura

```
┌─────────────────────────────────────────────────────────────────────┐
│                           Clientes                                   │
│              (orquestadores, UIs, otros agentes)                     │
└───────────────────────────────┬─────────────────────────────────────┘
                                │ HTTP (A2A / AG-UI / API nativa)
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                              SAAR                                     │
│                     (adaptador de agentes)                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                  │
│  │   Gateway   │  │    Core     │  │   Bridge    │                  │
│  │   (HTTP)    │──│   (OTP)     │──│   (IO)      │                  │
│  └─────────────┘  └─────────────┘  └─────────────┘                  │
└───────────────────────────────┬─────────────────────────────────────┘
                                │ Ports / HTTP
        ┌───────────────────────┼───────────────────────┐
        ▼                       ▼                       ▼
   ┌─────────┐            ┌─────────┐            ┌─────────┐
   │ Python  │            │  HTTP   │            │  Bash   │
   │ Runner  │            │ Server  │            │ Script  │
   └─────────┘            └─────────┘            └─────────┘
```

## 4. Componentes principales

### Perfiles JSON
Describen el agente: metadata, parámetros, runner, capabilities.

### Core Gleam (OTP)
- **AgentActor**: FSM por instancia con protocolo de mensajes unificado
- **ProfilesActor**: SSOT de perfiles en memoria (ProfileId → Profile) para reload sin reiniciar SAAR
- **AgentManagerActor**: actor “manager” que crea agentes vía `AgentFactorySupervisor` (children `Temporary`, sin auto-restart)
- **Registry**: mapea `instance_id` → `RegistryEntry` (PID + `profile_id` + `InstanceSummary` cacheado)

### Bridge
- Spawna workers para ejecutar runners (ports)
- Cliente HTTP para agentes continuous
- Acumula stdout y parsea respuestas
- Envía mensajes tipados al Actor
- Asigna puertos vía port pool (`managed_port`) y propaga host/port al runner

### Gateway HTTP
- `/sys/...` para SAM/orquestadores
- `/agents/...` para API nativa (interact/info)
- `/instances/:instance_id/...` para API A2A por instancia
- `/artifacts/...` para servir archivos

### Workspaces
- Directorios aislados por instancia
- Limpieza determinista en shutdown

## 5. Principios de diseño

### Mínimo Dynamic
El sistema de tipos elimina `Dynamic` donde es posible:
- `InputPayload` tipado: `PayloadChat`, `PayloadFiles`, `PayloadMixed`
- `InputSchema` cerrado: `SchemaChat`, `SchemaFiles`, `SchemaChatExtended`

### Estados ilegales irrepresentables
- `Parameter` como ADT: `FixedParam`, `ConfigParam`, `SecretParam`, `InitParam`
- `SecretParam` no puede tener default (validado en decoder)
- `WorkspacePath` opaco previene path traversal

### Separación wire/interno
| Tipo Wire | Tipo Interno | Transformación |
|-----------|--------------|----------------|
| `AgentRequestWire` | `AgentInteractionRequest` | Gateway normaliza |
| `inputs: Dynamic` | `payload: InputPayload` | Decoder según schema |
| `SadInput` | JSON wire | Bridge serializa |

### API pública del actor (sin mensajes directos)
```gleam
	pub opaque type AgentRef
	
	pub fn interact(agent: AgentRef, request: AgentRequest) -> Result(InteractionResult, InteractionError)
	pub fn status(agent: AgentRef) -> AgentStatusView
	pub fn attach_logs(agent: AgentRef, subscriber: Subject(LogEvent)) -> Nil
	pub fn stop(agent: AgentRef, reason: StopReason) -> Nil
	```

**Nota:** `AgentRef` es un handle **en memoria** (válido solo dentro del nodo SAAR). No cruza HTTP ni puede ser conocido por SAM.
SAM identifica instancias por `instance_id`; el gateway resuelve `instance_id → AgentRef` vía registry.

## 6. Estados del agente

```gleam
// Estado observable (wire/diagnóstico). Ubicación: `saar/types.gleam`
pub type AgentPhase {
  Created
  Provisioning
  ReadyTransient
  ReadyContinuous
  Stopped
  Failed
}

pub type AgentRunMode {
  RunIdle
  RunBusy
}

pub type AgentStatusView {
  AgentStatusView(
    profile_id: ProfileId,
    instance_id: InstanceId,
    lifecycle: Lifecycle,
    phase: AgentPhase,
    mode: AgentRunMode,
    assigned_port: Option(Int),
    failure_reason: Option(String),
  )
}
```

**Invariantes garantizados por el tipo:**
- `Stopped` existe y es distinto de `Delete`: stop ≠ delete
- No hay secretos/params/resursos BEAM en el wire (solo vista serializable)
- Los detalles runtime viven en `AgentState` + `AgentRuntimeState` (core) y no se exponen

## 7. Estructura de módulos

Referencia completa (v0): `arquitectura/examples/snippets/readme_module_tree.txt`.

Extracto (v0):

```text
src/
├── saar.gleam
└── saar/
    ├── sys.gleam
    ├── types.gleam
    ├── workspace.gleam
    ├── params.gleam
    ├── core/
    │   ├── messages.gleam
    │   ├── agent.gleam
    │   ├── registry.gleam
    │   ├── artifact_registry.gleam
    │   ├── profiles.gleam
    │   ├── profiles_api.gleam
    │   └── agent_manager.gleam
    ├── bridge/
    │   ├── bridge.gleam
    │   ├── port_process.gleam
    │   ├── runner.gleam
    │   └── client.gleam
    └── gateway/
        ├── api.gleam
        └── proxy.gleam
```

## 7.1 Regla de modularización (canónica)

- `saar/types.gleam` es **dominio + wire** y no importa `gleam/erlang/*` ni `gleam/otp/*` (sin `Subject`, `Pid`, `Monitor`, `Selector`, `Port`).
- `saar/core/messages.gleam` concentra **mensajería OTP** (Subjects, ReplyChannels, handles, monitors).
- `saar/core/*` contiene estado y actores/supervisión (control-plane).
- `saar/bridge/*` contiene IO pesado (ports, HTTP).
- `saar/gateway/*` contiene router HTTP y handlers (incluye `ui_proxy.gleam` separado).
- `saar/adapters/*` contiene mapeos wire (A2A, AG-UI, A2UI).
- `saar/streams/*` contiene sink/batching/backpressure.

## 8. Decisiones clave vs Ruby

| Aspecto | Ruby 3.4 | Gleam v3.x |
|---------|----------|------------|
| Perfiles | DSL Ruby | JSON tipado |
| Drivers | Clases Ruby | Scripts runner |
| Estado | `stateful/stateless` | Sin distinción |
| Rehidratación | `from_details` | Responsabilidad de SAM |
| Artefactos | Redis cache | URLs efímeras |
| Parámetros | En driver | En `params.gleam` |

## 9. Timeouts

| Operación | Default (v0) | Configurable |
|-----------|-------------|--------------|
| Interacción (transient + continuous) | `default_saar_config().call_timeout_ms` | Sí (y se puede sobrescribir por capability limits) |
| Health check (continuous) | `default_saar_config().health_check_timeout_ms` | Sí |
| Shutdown (stop/delete) | `default_saar_config().shutdown_timeout_ms` | Sí |
