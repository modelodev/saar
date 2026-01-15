# Integración de agentes (perfiles + runners + adaptadores)

Objetivo: que un agente se integre en SAD **sin modificar SAD**, usando (1) un perfil JSON y (2) runners reutilizables (scripts), y que SAD solo implemente adaptadores **de protocolo** (A2A, AG-UI), no “adapters por agente”.

## 1. Superficies de extensión

- **Perfil JSON (por agente)**: describe metadata, parámetros, runner y capabilities. Ver `arquitectura/config.md` y `arquitectura/protocolos.md` §4.
- **Runner (reutilizable)**: script que provisiona/ejecuta un agente según `SAD_INPUT_JSON`. Ver `arquitectura/protocolos_runner.md`.
- **Wrapper (siempre)**: SAD lanza runners vía wrapper; el wrapper hace stop/kill (SIGTERM→SIGKILL) y aislamiento. Ver `arquitectura/examples/wrapper_pid_namespace.md`.
- **Adaptadores de protocolo (en SAD)**: traducen el core genérico (`StreamEvent`, modelos) a wire formats (AG-UI/A2A) y viceversa. No son específicos de un agente.

## 2. Contrato de perfil (resumen)

- **Schemas cerrados**: `input_schema` ∈ {`std:chat`, `std:files`, `std:chat` + `extra_fields`}. SAD valida antes de invocar runners.
- **Interpolación strict**: cualquier `{{namespace.key}}` faltante falla temprano (ver `arquitectura/bridge.md` §3).
- **`managed_port`**: en HTTP continuous no existe `static_port`; SAD asigna host/port y los inyecta por env.
- **Respuesta declarativa**: `ResponseMapping` usa JSON Pointers (`text_pointer`, etc.) en vez de código; resolucion interna sobre Dynamic para evitar conversion Json/Dynamic repetida.
- **Entrega de ficheros (CLI runners)**: SAD pasa URLs (`FileRef.url`). Si un runner necesita rutas locales, descarga/copia dentro del workspace.

## 3. Contrato de streaming (v0)

SAD distingue dos streams:

- **SSE de logs (instancia)**: best-effort; puede `drop/coalesce` bajo presión.
- **SSE de interacción**: se entrega mientras haya conexión, pero **sin buffers infinitos**; SAD aplica batching y si el cliente es lento o se desconecta, corta el streaming (discard) y la interacción continúa hasta `InteractionDone`.

### 3.1 Streaming desde runners (capabilities `runner` con `streaming: true`)

Contrato v0 (alineado con OTP `open_port` y mínima complejidad):

- SAD consume un **único canal capturado** (STDOUT del wrapper/runner). No hay separación contractual stdout/stderr.
- El runner emite un **stream de eventos JSONL** (1 JSON por línea):
  - `t="log"` (opcional) para logs,
  - `t="chunk"` (opcional) para deltas incrementales,
  - `t="result"` (obligatorio; exactamente uno) con forma `RunnerResponse`.

El bridge traduce `t="chunk"` a `ContentChunk` y lo entrega por SSE por batches vía `sad/streams/sink.StreamSink` (sin buffers infinitos).

### 3.2 Streaming desde agentes HTTP (capabilities `http` con `streaming: true`)

- El bridge abre una conexión SSE hacia el agente.
- Cada evento SSE debe ser `data: <json>` donde `<json>` es un **RunnerEvent** (`log|chunk|result`), igual que en JSONL de runners.
- `data` vacio se ignora (keep-alive).
- Si el stream cierra sin `t="result"`, SAD falla con `InfraError` (fail-fast).

**Importante:** v0 no soporta resume/replay tras desconexion del cliente SSE; cortar SSE no cancela la ejecucion (principio SAD).

## 4. Construcción de requests HTTP (capabilities `http`)

Para evitar expresiones tipo `{{input.files[0].url}}` (no soportadas en interpolación strict), SAD soporta:

- `{{namespace.key}}` para **escalares** dentro de strings, y
- `{"$from": "/json/pointer"}` (RFC 6901) para inyectar **valores estructurados** desde `SAD_INPUT_JSON`.

Ejemplos:

- Pasar historial completo de mensajes:
  - `"messages": {"$from": "/input/messages"}`
- Tomar el primer fichero:
  - `{"field":"file","source_pointer":"/input/files/0"}`

## 5. Entrega de ficheros (runners CLI)

Contrato v0:
- SAD pasa siempre `FileRef.url` (equivalente a A2A `file.uri`).
- Si el runner necesita una ruta local, debe materializarla dentro del workspace (download/copy) antes de invocar el agente real.

Si el cliente no tiene una URL pública, debe subir el fichero a un storage accesible (S3/GCS/HTTP) y enviar su URL.

## 6. Ejemplos

- Perfil continuous con runner genérico: `arquitectura/examples/profiles/lightrag/lightrag.json`
- Perfil transient (CLI) con runner genérico: `arquitectura/examples/profiles/aider/aider.json`
- Runners genéricos: `arquitectura/examples/runners/README.md`

## 7. Capacidades

Una capacidad (capability) es una operación visible para el cliente expuesta por una instancia.

- Las capacidades se definen en el perfil bajo `interface.capabilities`.
- El campo `capability` que envía un cliente (API nativa `/agents/:instance_id/interact` o metadata A2A) es una clave de búsqueda dentro de ese diccionario.

Las capacidades son parte del contrato de SAD, no necesariamente del producto agente subyacente.

- **Interfaz runner (`protocol: runner`)**
  - Las capacidades son operaciones “virtuales” implementadas por la invocación del runner descrita en el perfil (args/env/helpers).
  - El binario envuelto (p.ej. Aider) no necesita implementar un sistema de capacidades.
  - Si quieres múltiples operaciones (p.ej. `chat` vs `train`), las modelas como capacidades distintas y las mapeas a distintos argumentos o incluso a distintos runners.
- **Interfaz HTTP (`protocol: http`)**
  - Las capacidades suelen mapear a endpoints HTTP upstream distintos (`path` + `method`) y pueden tener plantillas y mapeos de respuesta distintos.

## 8. Modos de entrega de respuesta

Una capacidad también determina cómo el cliente debe consumir el resultado.

- **Respuesta inmediata (JSON)**: SAD devuelve la respuesta final en la misma llamada.
- **Respuesta por SSE**: SAD mantiene la conexión abierta y emite eventos incrementales hasta el evento terminal.
- **Respuesta diferida (tarea + sondeo/suscripción)**: SAD devuelve un id de tarea y el cliente lo resuelve después consultando un endpoint de tareas.

Detalles y ejemplos completos:

- `INTEGRATION.md` (guía para clientes)
- `runners_and_agents.md` (guía para autores de perfiles y runners)
