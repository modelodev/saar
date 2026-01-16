# Gateway HTTP (`saar/gateway/*.gleam`)

El gateway es la frontera HTTP de SAAR. Expone dos APIs y servicios de proxy.

## 1. Estructura de módulos

```text
saar/gateway/
├── api.gleam      # /sys (orquestador) + /agents (nativo) + /instances/:instance_id/a2a (A2A)
├── problem.gleam  # RFC7807: dominio → Problem → HTTP response
├── proxy.gleam    # /artifacts (archivos)
└── ui_proxy.gleam # /agents/:instance_id/ui/* (proxy UI HTTP-only)
```

## 2. Autenticación

SAAR v0 implementa **API Key simple** (Bearer Token).

```http
Authorization: Bearer <api_key>
```

**Decisión v0:** todos los endpoints requieren API key **excepto** `GET /health` y `GET /health/ready`.
El Agent Card (`/instances/:instance_id/.well-known/agent-card.json`) es **privado por defecto** (requiere API key).

**Modelo de amenaza (v0):** SAAR puede ser consumido por clientes externos no confiables (además de SAM/orquestadores). Por eso:
- La auth es obligatoria casi en todo.
- `/artifacts` y `/ui` se tratan como superficies sensibles: no se exponen rutas, no se forwardean credenciales, y se aplican validaciones estrictas.

**Decisiones v0 (API):**
- SAAR no agrega headers CORS en **ningún** endpoint; si se requieren, se gestionan fuera (reverse proxy/gateway upstream).
- No hay rutas versionadas (no `/v1`); el versionado/compatibilidad se gestiona fuera de SAAR.

La API key se configura en `config.toml`:

```toml
[auth]
api_key = "${SAAR_API_KEY}"  # Interpolación de env var
```

## 3. Formato de errores

| API | Formato |
|-----|---------|
| Nativa (`/sys`, `/agents/:instance_id/interact`) | RFC 7807 (Problem Details) |
| A2A (`/instances/:instance_id/a2a/*`) | RFC 7807 (Problem Details) |

**Tabla canónica:** ver `protocolos.md` §0.1.

**Implementación (canónica):** todo error HTTP se construye a través de `saar/gateway/problem.gleam`
(mapping desde `ErrorKind`/errores de dominio) para evitar duplicaciones y asegurar consistencia.

## 3.3 Safe-call en el borde HTTP (norma v0)

En Gleam/OTP, `actor.call`/`process.call` son **fail-fast**: si el callee muere o no responde en timeout, el proceso llamador puede terminar. Eso es aceptable *dentro* del árbol OTP (todo está supervisado), pero en el borde HTTP puede tumbar el handler y dejar respuestas incompletas.

**Regla v0:** en procesos de request/stream del gateway (Mist), usar únicamente `saar/otp/safe_call.call_within` para cualquier operación síncrona contra actores (manager/agent/profiles/registry/sinks). El gateway convierte:
- `CallError.Disconnected` → 503 (servicio temporalmente no disponible)
- `CallError.TimedOut` → 504 (timeout)

Referencia (v0): `arquitectura/examples/snippets/otp_safe_call.gleam`.

## 3.4 Graceful shutdown (drain)

Durante shutdown (por SIGTERM o por `saar serve -k`), el gateway entra en modo *drain*:

- Nuevas requests se rechazan con 503 (Problem Details) y `extensions.code = "shutting_down"`.
- Requests in-flight continúan best-effort hasta `limits.shutdown_timeout_ms`.

Implementación canónica:

- `saar/gateway/shutdown.gleam` mantiene `draining` + contador `inflight` y dispara el flujo de parada global.
- `saar/gateway/http_server.gleam` consulta a `GatewayShutdown` al inicio de cada request; si está en drain responde 503.

---

## SSE en SAAR (2 usos distintos)

SAAR expone Server-Sent Events (SSE) en **dos** flujos distintos. Es importante no mezclarlos:

| Tipo | Endpoint | Qué transmite | Lifecycle | Notas |
|------|----------|---------------|-----------|-------|
| **SSE de logs (instancia)** | `GET /sys/agents/:instance_id/logs/stream` | `LogEvent` (runner/system logs) | Mientras exista la instancia | Tiene ring buffer + takeover |
| **SSE de interacción (nativa)** | `POST /agents/:instance_id/interact` (si `streaming: true`) | Eventos de respuesta (`StreamEvent` → AG-UI) | Dura lo que dure esa interacción | No es ring buffer de logs |
| **SSE de interacción (A2A)** | `POST /instances/:instance_id/a2a/message:stream` | Eventos A2A (task_status/message) | Dura lo que dure esa interacción | Es streaming de interacción, no logs |

**Principio (v0):** cortar SSE (en cualquiera de los flujos) **no** toma decisiones sobre el agente; solo detiene la entrega al cliente. La ejecución sigue hasta completar o timeout, salvo orden superior explícita.

**Límites OOM (v0):** cualquier endpoint que lea body (JSON) debe hacerlo con `mist.read_body(req, config.max_request_body_bytes)` y devolver 413 si excede el límite; nunca parsear bodies sin un límite explícito.

**Backpressure (v0):** ambos SSE usan límites para evitar OOM, pero con políticas distintas:
- Logs: se permite `drop/coalesce` bajo presión (observabilidad best-effort).
- Interacción: se usa un `saar/streams/sink.StreamSink` por request; el bridge envía batches **con ack** (safe-call) y el socket marca el ritmo. Si el cliente se desconecta, SAAR corta el streaming (discard) y la interacción continúa hasta `InteractionDone`.

**Objetivo SSE (v0):** preservar la experiencia de streaming. Si un agente entrega una interacción larga por SSE, SAAR debe poder retransmitirla al cliente poco a poco, evitando degradar a una respuesta en bloque al final.
SSE se trata como **transporte**: SAAR no “entiende” protocolos específicos (OpenAI, etc.); solo gestiona framing, backpressure, límites y cancelación (y, cuando aplica, un envelope mínimo estable) para reenviar el stream de forma segura.

**`saar/streams/sink.StreamSink` (interacción):** protocolo pequeño (type + msgs + `push_batch/finish`) implementado por el gateway como **el loop SSE de Mist por request** (`mist.server_sent_events(...)`).

Regla v0: el sink de interacción **no** es “send-only”. Debe ser una operación tipo call (ack) para imponer backpressure real:
- `push_batch(events)` MUST esperar ack del loop SSE (o timeout/disconnect) antes de que el worker siga leyendo.
- `finish(result)` MUST emitir el evento terminal (AG-UI/A2A) y cerrar SSE; en A2UI “puro” el final se observa por cierre del stream.

**Anti‑patrón (no v0):** `StreamSink.push = process.send(sse_subject, Msg(event))` + “mailbox watermark”. `process.send` no aplica backpressure; bajo cliente lento el mailbox crece hasta OOM. El watermark solo permite “cortar/degradar”, pero no frena al producer ni preserva “no drop”.

Referencia (v0): `arquitectura/examples/snippets/gateway_sse_stream_sink_mist.gleam`.

**Implementación recomendada (v0, Mist):** el gateway implementa el `StreamSink` sobre `mist.server_sent_events(...)` (loop por request),
usando `mist.send_event(...)` para escribir a socket con framing SSE correcto, keep-alives controlados por el loop,
y cierre ordenado terminando el loop SSE.

**Cierre SSE (normativa v0):**
- No existe un “cierre SSE estándar”: el cierre se logra **enviando un evento terminal explícito** y luego **cerrando la conexión** (terminando el loop/handler).
- `StreamSink.finish(...)` MUST:
  1) emitir el evento terminal correspondiente (éxito o error, incluyendo `trace_id`),
  2) hacer best-effort flush,
  3) terminar el proceso/loop del SSE para cerrar el socket.
- En streams largos donde puede haber periodos sin eventos (especialmente logs), SHOULD enviar keep-alives SSE como comentarios (`: keep-alive\n\n`) cada `sse_keep_alive_interval_ms` (o un valor fijo conservador) para evitar timeouts de proxies.

En endpoints streaming, el gateway crea este `StreamSink` (1 por request) y lo pasa al `AgentActor` al iniciar la interacción
(`AgentMsg.Interact(req, Some(stream_sink), reply_to)`), para que el bridge pueda empujar batches sin pasar por el actor.

### 3.1 RFC 7807 (nativo)

```json
{
  "type": "https://saar/errors/invalid-request",
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

### 3.2 RFC 7807 (A2A)

```json
{
  "type": "https://a2a-protocol.org/errors/invalid-request",
  "status": 400,
  "title": "Bad Request",
  "detail": "Missing required field: message.parts"
}
```

---

## 4. API `/sys` (Orquestador)

Endpoints para SAM y herramientas de gestión.

### 4.0 Decisión v0: sync vs async

Para mantener simplicidad (sin background jobs ni estados adicionales), SAAR v0 sigue este criterio:

- **Síncrono (respuesta al terminar):** cuando el trabajo es **interno** y se espera **rápido/determinista**
  (p.ej. cleanup de workspace/registry/artefactos en `/delete`).
- **Asíncrono (aceptación rápida):** cuando el resultado depende de un **componente externo** o puede tardar de forma
  impredecible (p.ej. provisioning en `/sys/agents`), o cuando la terminación real depende del wrapper/runner (`/stop`).

### 4.1 Crear instancia

```http
POST /sys/agents
Content-Type: application/json
Authorization: Bearer <api_key>

{
  "profile_id": "vanna",
  "instance_id": "vanna-prod-1",
  "init_params": {
    "database_url": "postgres://...",
    "model": "gpt-4"
  }
}
```

**Notas:**
- `instance_id` lo genera el cliente (SAM), no SAAR
- Formato `instance_id`: slug ASCII `[A-Za-z0-9_-]`, longitud 1..64
- `init_params` son `Dict(String, ConfigValue)` (solo escalares)
- instance_id invalido => 400 (bad_request)
- El perfil se resuelve contra el `ProfilesActor` (en memoria, sin IO). El IO de cargar perfiles desde disco ocurre en `/sys/reload-profiles` o durante el arranque.

**Respuesta exitosa (201):**

```json
{
  "instance_id": "vanna-prod-1",
  "profile_id": "vanna",
  "a2a_base_url": "https://saar.example/instances/vanna-prod-1/",
  "status": {
    "state": "provisioning",
    "timestamp": "2025-01-15T10:00:00Z"
  }
}
```

**Semántica:** `201` indica que la instancia (actor) se creó correctamente y SAAR inició el provisioning de forma asíncrona.
El provisioning puede tardar; consultar `GET /sys/agents/:instance_id/status` (o `GET /sys/agents`) para ver transición a `ready` o `failed`.
Un ejemplo típico de fallo asíncrono es `port_pool_exhausted` (continuous con `managed_port` sin puertos libres), que se observa como `phase=failed` + `failure_reason` en status. Otros fallos posibles de provisioning son `port_in_use` (puerto ya ocupado en el SO) y `port_bind_failed` (bind-check fallido).

**Errores:**
- `400` - Parámetros inválidos o faltantes (incluye lista de errores)
- `404` - Profile no encontrado
- `409` - Instance ID ya existe

### 4.2 Listar instancias

```http
GET /sys/agents
GET /sys/agents?profile_id=vanna
GET /sys/agents?live=true
Authorization: Bearer <api_key>
```

**Respuesta (200):**

```json
{
  "agents": [
    {
      "instance_id": "vanna-prod-1",
      "profile_id": "vanna",
      "a2a_base_url": "https://saar.example/instances/vanna-prod-1/",
      "lifecycle": "continuous",
      "phase": "ready_continuous",
      "mode": "run_idle",
      "assigned_port": 9001,
      "failure_reason": null,
      "registered_at": 1736935200000,
      "status_updated_at": 1736935212345
    },
    {
      "instance_id": "aider-dev-1",
      "profile_id": "aider",
      "a2a_base_url": "https://saar.example/instances/aider-dev-1/",
      "lifecycle": "transient",
      "phase": "ready_transient",
      "mode": "run_idle",
      "assigned_port": null,
      "failure_reason": null,
      "registered_at": 1736933400000,
      "status_updated_at": 1736933412345
    }
  ]
}
```

**Nota:** Devuelve `InstanceSummary` (status cacheado + timestamps en ms). Para status live, usar
`GET /sys/agents/:instance_id/status` o `?live=true` (opt-in, puede implicar N+1).
Para vista detallada (perfil asociado, capabilities, `ui_hint`, etc.), usar `GET /agents/:instance_id`.
No existe `GET /sys/agents/:instance_id`.

### 4.3 Estado de instancia

```http
GET /sys/agents/:instance_id/status
Authorization: Bearer <api_key>
```

**Respuesta (200):** `AgentStatusView` serializado (vista; sin params ni recursos BEAM).

```json
{
  "profile_id": "vanna",
  "instance_id": "vanna-prod-1",
  "lifecycle": "continuous",
  "phase": "ready_continuous",
  "mode": "run_idle",
  "assigned_port": 9001,
  "failure_reason": null
}
```

**Nota:** El estado no incluye capabilities. Para esa vista usar `GET /agents/:instance_id`.

### 4.4 Stream de logs

```http
GET /sys/agents/:instance_id/logs/stream
Authorization: Bearer <api_key>
Accept: text/event-stream
```

**Comportamiento:**
1. Al conectar: envía contenido actual del Ring Buffer (histórico)
2. Luego: modo live, reenvía eventos a medida que ocurren
3. **Single-consumer con takeover**: nueva conexión desplaza la anterior
4. Buffer acotado por `log_buffer_bytes` (sin persistencia a disco en v0).
5. Cortar esta conexión **no** afecta al agente; solo deja de entregarse el stream de logs.
6. Para evitar timeouts de proxies en conexiones largas, el servidor envía keep-alives SSE (comentarios) cada `sse_keep_alive_interval_ms` (best-effort).

**Formato SSE:**

```
data: {"ts_ms":1705312800000,"line":"[INFO] Server started","trace_id":null}

data: {"ts_ms":1705312801000,"line":"Processing request...","trace_id":"trace-abc"}
```

**Configuración del histórico:** `log_buffer_bytes` en `config.toml`.

### 4.5 Parar instancia (stop)

```http
POST /sys/agents/:instance_id/stop
Authorization: Bearer <api_key>
```

**Semántica:**
- Asíncrono e idempotente.
- El handler **solo encola** el stop y responde `202`. El stop real ocurre en el core (`AgentManagerActor`/`AgentActor`) y puede tardar hasta `shutdown_timeout_ms`.
- El wrapper aplica SIGTERM al grupo del runner; si tras el timeout sigue vivo, SIGKILL al grupo.
- Si hay provisioning o interacción in-flight, el stop **cancela** esa ejecución best-effort; cualquier interacción en curso termina con error “cancelled” y el SSE (si existe) finaliza.
- **No** limpia workspace ni artefactos; solo detiene ejecución. Útil para pausar sin perder artefactos.
- En v0, `stop` es **reversible**: `POST /sys/agents/:instance_id/start` vuelve a arrancar la instancia.
- En continuous con `managed_port`, el puerto se **libera al completar el stop** y se reasigna al hacer `start` (puede cambiar). `assigned_port` es diagnóstico/hint, no identidad estable.
- La instancia permanece registrada y pasa a estado `Stopped` (visible en `GET /sys/agents/:instance_id/status`).
- Si la instancia ya está parada, responde OK igualmente.

**Respuesta (202):**

```json
{
  "status": "accepted",
  "instance_id": "vanna-prod-1"
}
```

### 4.5.1 Arrancar instancia (start)

```http
POST /sys/agents/:instance_id/start
Authorization: Bearer <api_key>
```

**Semántica (v0):**
- Asíncrono e idempotente.
- Si la instancia está `Stopped` o `Failed`, `start` la transita a `Provisioning` y vuelve a intentar arrancar (en continuous: asigna un `managed_port` y arranca el servidor; en transient: habilita el estado `ReadyTransient`).
- Si la instancia ya está `Provisioning`/`Ready*`, responde `202` igualmente (no-op).
- Si el port pool está exhausto (continuous con `managed_port`), el arranque termina en `Failed` con `failure_reason=port_pool_exhausted`.
- Si el puerto está ocupado en el SO, el arranque termina en `Failed` con `failure_reason=port_in_use`.
- Si el bind-check falla por error del sistema, el arranque termina en `Failed` con `failure_reason=port_bind_failed`.

**Respuesta (202):**

```json
{
  "status": "accepted",
  "instance_id": "vanna-prod-1"
}
```

### 4.6 Eliminar instancia (delete)

```http
DELETE /sys/agents/:instance_id
Authorization: Bearer <api_key>
```

**Semántica:**
- **Determinista (v0):** el handler ejecuta el borrado dentro de la request (sin background jobs).
- **Idempotencia (v0):** si la instancia no existe, responde igualmente como “deleted” (no-op).
- Si el runner sigue vivo, primero aplica la misma secuencia de `/stop` (orden de stop → wrapper envía SIGTERM y, tras timeout, SIGKILL) y luego limpia: workspace, registry y artifact_registry.
- Si hay provisioning/interacción in-flight, `delete` lo cancela primero (best-effort) y el cliente de la interacción verá error “cancelled”.
- En agentes continuous con `managed_port`, libera el puerto reservado al port pool.
- Si la instancia no existe, devuelve 200 igualmente (no-op).
- Si la instancia existe pero falla el cleanup de filesystem (`workspace.cleanup`), devuelve **500** (Problem Details) y la instancia **no** se elimina; aun así, el handler MUST hacer `artifact_registry.purge_by_instance` (rollback de seguridad: los IDs dejan de resolverse).
- Internamente corresponde a `DeleteAgent` (distinto de `StopAgent`): stop ≠ delete.

**Respuesta (200):**

```json
{
  "status": "deleted",
  "instance_id": "vanna-prod-1"
}
```

### 4.7 Recargar perfiles

```http
POST /sys/reload-profiles
Authorization: Bearer <api_key>
```

**Comportamiento:**
- El gateway (borde) hace el IO: carga perfiles desde `profiles.sources` (dir/git)
- Si el IO falla, devuelve 500 y los perfiles anteriores se mantienen
- Si el IO tiene éxito, envía `SetProfiles` al `ProfilesActor` (operación pura)
- Agentes ya creados NO se ven afectados (siguen usando el perfil que tenían)
- Nuevas instancias usarán los perfiles actualizados

**Implementación (IO en el borde):**

```gleam
// saar/gateway/api.gleam

pub fn reload_profiles(req: Request, app_state: AppState, sup_ref: SupervisorRef) -> Response {
  // 1. IO en el borde: cargar desde profiles.sources
  case config.load_profiles_from_sources(
    app_state.config.profiles_sources,
    app_state.config.profiles_git_cache_dir,
    app_state.config.runners_python_bin,
  ) {
    Error(msg) ->
      // Fallo de IO → 500, perfiles anteriores se mantienen
      response.new(500)
      |> response.json(json.object([
        #("type", json.string("https://saar/errors/infra-error")),
        #("status", json.int(500)),
        #("title", json.string("Internal Server Error")),
        #("detail", json.string(msg)),
        #("instance", json.string("/sys/reload-profiles")),
        #("extensions", json.object([
          #("kind", json.string("infra_error")),
          #("trace_id", json.string("trace-...")),
        ])),
      ]))
    
    Ok(profiles) -> {
      // 2. Mensaje puro al ProfilesActor (sin IO)
      let count = profiles_api.set_profiles(
        sup_ref.profiles,
        profiles,
      )
      
      let profile_ids = dict.keys(profiles)
        |> list.map(profile_id_to_string)
      
      response.new(200)
      |> response.json(json.object([
        #("status", json.string("success")),
        #("profiles_loaded", json.int(count)),
        #("profiles", json.array(profile_ids, json.string)),
      ]))
    }
  }
}
```

**Respuesta exitosa (200):**

```json
{
  "status": "success",
  "profiles_loaded": 5,
  "profiles": ["aider", "vanna", "gpt-researcher", "lightrag", "inbox-assist"]
}
```

**Respuesta error (500):**

```json
{
  "type": "https://saar/errors/infra-error",
  "status": 500,
  "title": "Internal Server Error",
  "detail": "Failed to parse profile 'aider': invalid JSON at line 42",
  "instance": "/sys/reload-profiles",
  "extensions": {
    "kind": "infra_error",
    "trace_id": "trace-abc123"
  }
}
```

**Casos de uso:**
- Hot reload de perfiles en desarrollo
- Actualizar perfiles sin reiniciar SAAR
- CI/CD: desplegar nuevos perfiles y recargar

**Nota sobre arquitectura:** El IO (lectura de disco, parsing JSON) ocurre en el gateway
(borde). El supervisor solo recibe un `Dict(ProfileId, Profile)` ya parseado, manteniendo
el principio de core puro.

### 4.8 Listar perfiles disponibles

### 4.9 Adapters (AG-UI / A2A / A2UI)

- AG-UI: el gateway traduce `StreamEvent` → eventos AG-UI (solo texto soportado). `taskId` = `trace_id`.
- A2A: Agent Card desde instancia (profile snapshot + instance_id); endpoints `/instances/:instance_id/a2a/message:send` (sync) y `/instances/:instance_id/a2a/message:stream` (SSE). `taskId` = `trace_id`, `contextId` passthrough. No hay push notifications.
- A2UI: protocolo de UI declarativa por streaming (JSONL) para interfaces agent-driven; SAAR lo soporta como wire/adapter (ver `protocolos.md`).

```http
GET /sys/profiles
Authorization: Bearer <api_key>
```

**Respuesta (200):**

```json
{
  "profiles": [
    {
      "id": "aider",
      "lifecycle": "transient",
      "description": "AI pair programming assistant"
    },
    {
      "id": "vanna",
      "lifecycle": "continuous",
      "description": "Natural language to SQL"
    }
  ]
}
```

---

## 5. API `/agents` (Nativa SAAR)

Endpoints para interacción directa con agentes.

### 5.1 Información del agente

```http
GET /agents/:instance_id
Authorization: Bearer <api_key>
```

**Respuesta (200):**

```json
{
  "instance_id": "vanna-prod-1",
  "profile_id": "vanna",
  "a2a_base_url": "https://saar.example/instances/vanna-prod-1/",
  "description": "Agente SQL en lenguaje natural",
  "capabilities": {
    "chat": {
      "description": "Consultas SQL",
      "input_schema": "std:chat",
      "streaming": true,
      "limits": {
        "timeout_ms": 60000
      }
    },
    "train": {
      "description": "Entrenar con DDL",
      "input_schema": {
        "base": "std:chat",
        "extra_fields": {
          "ddl_source": {"type": "string"}
        }
      },
      "streaming": false
    }
  }
}
```

### 5.2 Interacción (síncrona o streaming)

```http
POST /agents/:instance_id/interact
Content-Type: application/json
Authorization: Bearer <api_key>

{
  "capability": "chat",
  "inputs": {
    "messages": [
      {"role": "user", "content": "¿Cuántas ventas hubo ayer?"}
    ]
  },
  "context": {
    "trace_id": "trace-abc123"
  }
}
```

**Streaming:** Determinado por `capability.streaming` en el perfil.

- Si `streaming: false` → Respuesta JSON síncrona
- Si `streaming: true` → Respuesta SSE (`text/event-stream`)

**Formato de streaming (v0):**
- Por defecto, SAAR emite SSE en formato **AG-UI** (ver `protocolos.md` §3).
- Para solicitar streaming **A2UI** (JSONL de mensajes A2UI), el cliente envía:
  - `X-SAAR-UI-Protocol: a2ui/v0.8`

En modo A2UI, cada línea SSE `data: <json>` contiene **un** mensaje A2UI (p.ej. `{"surfaceUpdate": {...}}`).
SAAR no interpreta ni valida el catálogo; solo aplica límites/backpressure y transporta mensajes (ver `protocolos.md` §0.3).

**Errores comunes (v0):**
- Si el agente está Busy (ya hay una interacción en curso), responde `422` (`agent_error`) con detalle `"Agent is busy"`.

**Respuesta síncrona (200):**

```json
{
  "status": "success",
  "data": {
    "content": "Respuesta final.",
    "metadata": {
      "sql": "SELECT COUNT(*) FROM sales WHERE date = CURRENT_DATE - 1"
    }
  },
  "artifacts": [
    {
      "id": "01J...",
      "name": "report.pdf",
      "url": null,
      "mime": "application/pdf"
    }
  ],
  "trace_id": "trace-abc123"
}
```

**Respuesta streaming:** por defecto ver `protocolos.md` §3 (AG-UI). Para A2UI, ver `protocolos.md` §0.3 y el sitio oficial: https://a2ui.org/introduction/what-is-a2ui/

**Nota (artefactos en streaming):** si la interacción genera artefactos, el evento terminal del stream incluye `artifacts`
(IDs siempre; `url` solo si hay registro/almacenamiento público). Ver `protocolos.md` §2.7.2 (A2A) y §3.4.1 (AG-UI).

**Cancelación (v0):**
- No hay endpoint de cancelación dedicado ni cancelación implícita al cerrar SSE; si el cliente cierra, simplemente deja de recibir eventos. La interacción sigue hasta completar o timeout.
- `POST /sys/agents/:instance_id/stop` y `DELETE /sys/agents/:instance_id` **sí** cancelan provisioning/interacciones in-flight best-effort; el cliente de `interact` observa un error `agent_error` con mensaje `"cancelled"` (sync: RFC7807 422; streaming: evento terminal `RUN_ERROR`/`task_status failed`).

---

## 6. API `/instances/:instance_id/a2a` (Facade A2A)

Fachada para interoperabilidad con agentes externos (Google, AutoGen, etc.).

### 6.1 Agent Card

```http
GET /instances/:instance_id/.well-known/agent-card.json
Authorization: Bearer <api_key>
```

**Nota:** El Agent Card es **por instancia**. El `instance_id` viene del path y se resuelve via registry.

**Generación:** `agent_card_from_instance(instance_info, base_url)` en `saar/a2a.gleam`. Ver `protocolos.md` §2.2 para mapeo Profile → Agent Card.

### 6.2 Enviar mensaje (síncrono)

```http
POST /instances/:instance_id/a2a/message:send
Content-Type: application/json
Authorization: Bearer <api_key>

{
  "message": {
    "messageId": "msg-123",
    "role": "user",
    "parts": [
      {"text": "Analiza este documento"},
      {"file": {"uri": "https://...", "mediaType": "application/pdf", "name": "doc.pdf"}}
    ],
    "metadata": {
      "capability": "chat"
    }
  },
  "context": {
    "contextId": "conv-456"
  }
}
```

**Notas:**
- `contextId` es opcional. Si ausente, SAAR genera uno nuevo (uuid.v7)
- `messageId` lo genera el cliente para sus mensajes
- Para A2UI, activar la extensión con `X-A2A-Extensions: https://a2ui.org/a2a-extension/a2ui/v0.8` y usar `DataPart` con `metadata.mimeType="application/json+a2ui"` (ver `protocolos.md` §2.13).

**Respuesta (200):** `A2ATask` con estado `Completed`:

```json
{
  "result": {
    "id": "trace-abc-789",
    "contextId": "conv-456",
    "status": {"state": "completed"},
    "message": {
      "role": "assistant",
      "parts": [{"text": "Respuesta final."}]
    },
    "artifacts": [
      {
        "id": "01J...",
        "name": "report.pdf",
        "uri": null,
        "mediaType": "application/pdf"
      }
    ]
  }
}
```

- `result.id` es el `taskId` (= `trace_id` de SAAR)
- `contextId` devuelto para correlación

### 6.3 Enviar mensaje (streaming)

```http
POST /instances/:instance_id/a2a/message:stream
Content-Type: application/json
Accept: text/event-stream
Authorization: Bearer <api_key>

{
  "message": {
    "messageId": "msg-123",
    "role": "user",
    "parts": [{"text": "Genera un informe"}]
  },
  "context": {
    "contextId": "conv-456"
  }
}
```

**Respuesta:** SSE en formato A2A `StreamResponse`.

En A2A, cada `data: ...` contiene un JSON que representa un `StreamResponse`.
Regla: un `StreamResponse` contiene exactamente uno de `{task, message, statusUpdate, artifactUpdate}`.

Ejemplo:

```
data: {"task": {"id": "trace-abc-789", "contextId": "conv-456", "status": {"state": "working"}}}

data: {"message": {"role": "assistant", "parts": [{"text": "Generando informe..."}]}}

data: {"statusUpdate": {"taskId": "trace-abc-789", "contextId": "conv-456", "status": {"state": "completed"}}}
```

**Notas:**
- `taskId` = `trace_id` de SAAR (requerido para correlación)
- El sprint S21 define el soporte de operaciones A2A de tarea (`GetTask`/`CancelTask`/`SubscribeToTask`) para que el modo asíncrono sea funcional.
- Para A2UI, activar la extensión con `X-A2A-Extensions: https://a2ui.org/a2a-extension/a2ui/v0.8` y usar `DataPart` A2UI en `parts` (ver `protocolos.md` §2.13).

---

## 7. Proxy `/artifacts`

Sirve artefactos generados por runners con **seguridad path-traversal**.

### 7.1 Modelo de seguridad

```
┌─────────────────────────────────────────────────────────────────────┐
│                    FLUJO DE ARTEFACTOS                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Runner                 Bridge                  Gateway             │
│  ───────                ──────                  ───────             │
│                                                                     │
│  {"artifacts": [        ArtifactRef {           artifact_id →       │
│    {"path":             name,                   WorkspacePath       │
│     "out/file.pdf"}     path: WorkspacePath,    (índice en          │
│                         mime                     memoria)           │
│  ]}                     }                                           │
│                                                                     │
│        │                     │                       │              │
│        │  JSON con path      │  WorkspacePath        │  UUID        │
│        │  como String        │  validado             │  opaco       │
│        ▼                     ▼                       ▼              │
│                                                                     │
│  artifact_ref_decoder   ArtifactRef →           GET /artifacts/:artifact_id  │
│  (valida path dentro    PublicArtifact {        resuelve UUID →     │
│   del workspace)        id: <uuid>,            WorkspacePath       │
│                         url: (opcional)                             │
│                         }                                           │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

**Principio clave:** El cliente NUNCA envía rutas de archivo. Solo recibe y usa UUIDs.

### 7.2 Registro de artefactos

Cuando el runner responde con artefactos:

```gleam
// En bridge/runner.gleam, al parsear RunnerResponse

fn register_artifacts(
  response: RunnerResponse,
  instance_id: InstanceId,
  registry: Subject(ArtifactRegistryMsg),
) -> List(PublicArtifact) {
  response.artifacts
  |> list.map(fn(ref: ArtifactRef) {
    // Registrar y obtener ArtifactId (el ArtifactRegistry asigna el ID)
    let assert Ok(artifact_id) = artifact_registry_api.register_artifact(
      registry,
      ref.path,  // WorkspacePath ya validado
      ref.mime,
      instance_id,
      config.call_timeout_ms,
    )
    
    // Devolver artefacto público (solo UUID, no path)
    PublicArtifact(
      id: artifact_id,
      name: ref.name,
      url: option.Some("/artifacts/" <> artifact_id_to_string(artifact_id)),
      mime: ref.mime,
    )
  })
}
```

**Referencia (API):** `arquitectura/examples/snippets/artifact_registry_api_public.gleam`.

### 7.3 Obtener artefacto

```http
GET /artifacts/:artifact_id
Authorization: Bearer <api_key>
```

**Implementación:**

```gleam
// saar/gateway/proxy.gleam
import mist
import gleam/option.{None}

pub fn get_artifact(req: Request, artifact_id: String, sup_ref: SupervisorRef) -> Response {
  // 1. Resolver artifact_id → WorkspacePath (nunca usa String del cliente)
  let timeout_ms = sup_ref.config.call_timeout_ms

  case artifact_registry_api.lookup_artifact(
    sup_ref.artifact_registry,
    artifact_id_from_string(artifact_id),
    timeout_ms,
  ) {
    Error(_) -> response.new(503)
    Ok(None) -> response.new(404)
    Ok(Some(ArtifactEntry(path: workspace_path, mime: mime, ..))) -> {
      // 2) Defensa en profundidad: lectura/serving symlink-safe dentro del workspace.
      // 3) Servir streaming/sendfile (no cargar el fichero entero en memoria).
      let abs_path =
        workspace_path_to_absolute(
          sup_ref.config.workspaces_directory,
          workspace_path,
        )

      case mist.send_file(abs_path, 0, None) {
        Error(_) -> response.new(404)
        Ok(body) ->
          response.new(200)
          |> response.set_header("content-type", mime)
          |> response.set_header("content-disposition", "attachment")
          |> response.set_header("x-content-type-options", "nosniff")
          |> response.set_body(body)
      }
    }
  }
}
```

**Seguridad:**
- El gateway **nunca** acepta rutas del cliente
- `artifact_id` es un UUID opaco que solo SAAR genera
- `WorkspacePath` fue validado en el decoder del runner response (sin segmentos `..`)
- La lectura/serving debe ser **symlink-safe** (realpath/no-follow) para evitar escapes fuera del workspace
- El serving debe ser streaming/sendfile: nunca cargar el fichero completo en memoria (protección OOM)
- `mime` es input no confiable del runner: se sirve con `X-Content-Type-Options: nosniff` y `Content-Disposition: attachment`

### 7.4 Ciclo de vida de artefactos

```
Instancia creada
       │
       ▼
Interacción produce artefactos
       │
       ▼
artifact_ref_decoder valida path → WorkspacePath
       │
       ▼
Bridge registra (ArtifactRegistry asigna ID)
       │
       ▼
Cliente recibe PublicArtifact { id: <uuid>, url: (opcional) }
       │
       ▼
GET /artifacts/<uuid> → lookup → WorkspacePath → read_file
       │
       ▼
Instancia eliminada (DELETE /sys/agents/:instance_id)
       │
       ▼
Workspace limpiado + artifact_registry purgado para esa instancia
```

**Notas:**
- Artefactos son **efímeros**, ligados al ciclo de vida de la instancia
- Se borran cuando se elimina la instancia (cleanup del workspace)
- Persistencia a S3/GCS es responsabilidad del despliegue, no de SAAR

## 8. Proxy `/ui`

Proxy reverso (HTTP-only v0) para UIs embebidas en runners.

**Implementación:** `saar/gateway/ui_proxy.gleam`

### 8.1 Proxy de UI

```http
GET /agents/:instance_id/ui/*
Authorization: Bearer <api_key>
```

**Comportamiento:**
- Disponible para cualquier agente con endpoints HTTP adicionales
- Caso de uso principal: `ui_hint.kind = "ag-ui"`
- El path después de `/ui/` se reenvía al runner
- SAAR no emite headers CORS; si se requieren, se gestionan fuera (reverse proxy/gateway upstream)

**Headers inyectados:**

| Header | Valor | Propósito |
|--------|-------|-----------|
| `X-Forwarded-For` | IP del cliente | Contexto de red |
| `X-Forwarded-Host` | Host original | Contexto de red |
| `X-SAAR-Instance-Id` | ID de instancia | Contexto de negocio |
| `X-SAAR-Profile-Id` | ID de perfil | Contexto de negocio |

### 8.2 Decisión v0: no proxificar WebSockets

En SAAR v0, `/agents/:instance_id/ui/*` **solo** proxifica HTTP (request/response). Si el cliente intenta un upgrade
(`Upgrade: websocket`), el gateway debe **rechazar** la request (p.ej. 400/426) y no iniciar ningún bridge WS.

**Motivación:** proxificar WS implica implementar un cliente WebSocket upstream + forwarding de frames y subprotocolos,
lo cual añade complejidad y superficie de seguridad que no es core del driver.

**Futuro:** si aparecen agentes que requieran un canal bidireccional (p.ej. voz/realtime), se incorporará un proxy WS
como feature aislada (módulo dedicado + tests de seguridad).

**Seguridad (canónica):**
**Invariante v0 (no open proxy):** el destino (host/port/scheme) siempre se deriva del estado del agente; el cliente solo controla el path bajo `/ui/*`. Cualquier desviación es un bug de seguridad.
- El upstream (host/port/base_url) se deriva **solo** del estado del agente (nunca de headers/query del cliente).
- No es un “open proxy”: el cliente no puede elegir destino ni scheme; solo el path bajo `/ui/*`.
- No se forwardea `Authorization` (ni `Cookie`) del cliente al runner UI.
- Forward de headers por allowlist (solo lo necesario para HTTP/WS), más los headers SAAR (`X-SAAR-*`).
- El path bajo `/ui/*` no puede contener segmentos `..` (incluyendo `%2e%2e` tras decode).

---

## 9. Flujo de creación de instancia

```
┌──────────┐     ┌──────────┐     ┌──────────────┐     ┌──────────┐     ┌──────────┐
│  Cliente │     │ Gateway  │     │ ProfilesActor │     │  Params  │     │Supervisor│
└────┬─────┘     └────┬─────┘     └──────┬───────┘     └────┬─────┘     └────┬─────┘
     │                │                │                │                │
     │ POST /sys/agents               │                │                │
     │ {profile_id,   │                │                │                │
     │  instance_id,  │                │                │                │
     │  init_params}  │                │                │                │
     │───────────────>│                │                │                │
     │                │                │                │                │
     │                │ get_profile(id)                │                │
     │                │───────────────>│ ProfilesActor  │                │
     │                │<───────────────│                │                │
     │                │    Profile     │                │                │
     │                │                │                │                │
     │                │ resolve(profile.params,         │                │
     │                │         config, env, init)      │                │
     │                │───────────────────────────────>│                │
     │                │<───────────────────────────────│                │
     │                │    ResolvedParams | Errors     │                │
     │                │                │                │                │
     │                │ [Si Error: 400 con lista]      │                │
     │                │                │                │                │
     │                │ start_agent(profile, resolved)  │                │
     │                │────────────────────────────────────────────────>│
     │                │<────────────────────────────────────────────────│
     │                │    Ok(pid) | Error              │                │
     │                │                │                │                │
     │<───────────────│                │                │                │
     │   201 Created  │                │                │                │
```

---

## 10. Resumen de endpoints

| Método | Path | Descripción | Auth |
|--------|------|-------------|------|
| `POST` | `/sys/agents` | Crear instancia | API Key |
| `GET` | `/sys/agents` | Listar instancias | API Key |
| `GET` | `/sys/agents/:instance_id/status` | Estado de instancia | API Key |
| `GET` | `/sys/agents/:instance_id/logs/stream` | Stream de logs (SSE) | API Key |
| `POST` | `/sys/agents/:instance_id/stop` | Parar instancia (stop) | API Key |
| `POST` | `/sys/agents/:instance_id/start` | Arrancar instancia (start) | API Key |
| `DELETE` | `/sys/agents/:instance_id` | Eliminar instancia | API Key |
| `POST` | `/sys/reload-profiles` | Recargar perfiles desde disco | API Key |
| `GET` | `/sys/profiles` | Listar perfiles disponibles | API Key |
| `GET` | `/agents/:instance_id` | Info + capabilities | API Key |
| `POST` | `/agents/:instance_id/interact` | Interacción nativa | API Key |
| `GET` | `/instances/:instance_id/.well-known/agent-card.json` | Agent Card A2A | API Key |
| `POST` | `/instances/:instance_id/a2a/message:send` | Mensaje A2A síncrono | API Key |
| `POST` | `/instances/:instance_id/a2a/message:stream` | Mensaje A2A streaming | API Key |
| `GET` | `/artifacts/:artifact_id` | Obtener artefacto | API Key |
| `GET` | `/agents/:instance_id/ui/*` | Proxy UI | API Key |
| `GET` | `/health` | Health check (liveness) | - |
| `GET` | `/health/ready` | Readiness check | - |

---

## 11. Entrypoint (`saar.gleam`)

### 11.1 CLI Args

```gleam
pub type ServeArgs {
  ServeArgs(
    port: Option(Int),           // --port, -p
    config: Option(String),      // --config, -c
    background: Bool,            // --background, -b
    kill: Bool,                  // --kill, -k
    status: Bool,                // --status
  )
}

pub type Command {
  Serve(ServeArgs)
  Validate(path: String)
  DryRun(profile: String, input: String, capability: String)
  RunnerTest(profile: String, input: Option(String), contract: Bool)
  Version
  Help
}
```

### 11.2 Arranque

Referencia completa (v0): `arquitectura/examples/snippets/gateway_cli_entrypoint.gleam`.

Extracto (v0):

```gleam
pub fn main() {
  ...
}
```

### 11.3 Daemon helpers

Referencia completa (v0): `arquitectura/examples/snippets/gateway_cli_daemon_helpers.gleam`.

Extracto (v0):

```gleam
fn daemonize() -> Nil {
  ...
}

fn kill_running_server() -> Nil {
  ...
}
```

### 11.2 Árbol de supervisión

```
RootSupervisor (RestForOne)
├── RegistryActor (permanent)
├── ArtifactRegistry (permanent)
├── ProfilesActor (permanent)
├── AgentManagerActor (permanent)
├── AgentFactorySupervisor (permanent)
└── HttpServer (permanent)

Nota: los `AgentActor` se crean bajo demanda como children del `AgentFactorySupervisor`
(children `Temporary`: sin auto-restart). El `AgentManagerActor` coordina create/register/stop/delete,
pero no linkea ni trackea children manualmente.
```

### 11.3 Config mínima (`config.toml`)

```toml
[server]
host = "0.0.0.0"
port = 8080

[auth]
api_key = "${SAAR_API_KEY}"

[limits]
call_timeout_ms = 30000
shutdown_timeout_ms = 10000
health_check_timeout_ms = 10000

[profiles]
sources = [
  {type = "dir", path = "./profiles"}
]
git_cache_dir = "./.saar/cache/git"

[runners]
python_bin = "python3"

[workspaces]
directory = "./workspaces"
```

### 11.4 Variables de entorno

| Variable | Requerida | Default | Descripción |
|----------|-----------|---------|-------------|
| `SAAR_API_KEY` | Sí | - | API key para autenticación |
| `SAAR_CONFIG_PATH` | No | `./config.toml` | Path al archivo de config |
| `SAAR_LOG_LEVEL` | No | `info` | Nivel de logging |

### 11.5 Shutdown ordenado

```
1. Recibir SIGTERM/SIGINT
   │
2. Dejar de aceptar conexiones nuevas
   │
3. Completar requests en curso (timeout)
   │
	4. Enviar `Terminate(NodeShuttingDown)` a todos los agentes
   │
5. Esperar terminación (shutdown_timeout_ms)
   │
6. Forzar terminación de pendientes
   │
7. Detener supervisores
   │
8. Exit(0)
```

### 11.6 Health checks

| Check | Endpoint | Qué verifica |
|-------|----------|--------------|
| Liveness | `GET /health` | Proceso responde |
| Readiness | `GET /health/ready` | Supervisores activos + perfiles cargados (count > 0) |

```json
// GET /health → 200
{
  "status": "healthy",
  "version": "3.0.0",
  "uptime_ms": 123456
}
```

Si no hay perfiles cargados, `GET /health/ready` responde 503 con `status="not_ready"`.

### 11.7 Errores de arranque

| Error | Causa | Solución |
|-------|-------|----------|
| `Config file not found` | `config.toml` no existe | Crear archivo |
| `Missing required env var` | `SAAR_API_KEY` no definido | Exportar variable |
| `Port already in use` | Puerto ocupado | Cambiar puerto |
