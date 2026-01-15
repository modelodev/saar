# Contrato de runners (detallado)

**Lanzamiento vía wrapper** (obligatorio en v0):
- SAD siempre invoca `wrapper -- <runner> ...` (ver `arquitectura/examples/wrapper_pid_namespace.md`).
- Wrapper crea PID+user namespace, lanza el runner y gestiona control por stdin (JSONL):
  - `{"t":"input","payload":<SAD_INPUT_JSON>}` (línea única): reenvía el `payload` al runner por stdin y luego cierra su stdin.
  - `{"t":"stop"}` (línea única) o EOF → SIGTERM → timeout → SIGKILL a la subtree.
- SAD no necesita FFI de señales ni conocer `os_pid`; la FFI solo cubre open/send/close/receive del port (idealmente vía `sad/bridge/port_process.gleam`).
 - **Wrapper recomendado:** binario compilado tipo “init PID1” (C/Rust/Go). Evitar bash como wrapper: no es fiable para reaping/propagación de señales.

### Entradas y salidas
- STDIN del wrapper: JSONL de control. Primera línea: `{"t":"input","payload":<SAD_INPUT_JSON>}`. Líneas posteriores: `{"t":"stop"}` (o futuros comandos). EOF equivale a stop.
- STDIN del runner: `SAD_INPUT_JSON` (validado) para start/exec; el wrapper lo reenvía y luego cierra stdin.
- STDOUT: **stream de eventos** (una línea por evento, JSONL/NDJSON). Incluye logs, streaming y el resultado final.
- STDERR: fuera de contrato (diagnóstico local). SAD no debe depender de capturarlo ni de separarlo de STDOUT.

**Racional (OTP/BEAM):** `open_port` no ofrece separación real de stdout/stderr cuando se usa `use_stdio`. Para evitar complejidad (wrappers multiplexores, `erlexec`, etc.), SAD trata la salida capturada como **un único canal** y la separación se hace **a nivel de protocolo** (eventos tipados).

### Guardrails (fail-fast sin sorpresas)

- **Wrapper silencioso en STDOUT:** el wrapper no debe imprimir banners/logs a STDOUT; si necesita logs, que vaya a STDERR o a fichero.
- **`sad runner-test` como gate:** cualquier runner/wrapper debe pasar `sad runner-test` (ideal: CI obligatorio) para evitar “basura” accidental en STDOUT.
- **Adaptadores fuera del core:** si queréis ejecutar un binario que escribe texto libre, haced un “shim runner” que capture su salida y emita eventos JSONL; ese shim vive fuera del core SAD.
- **Límite de control:** el wrapper corta si una línea de control excede `SAD_WRAPPER_CONTROL_LINE_BYTES` (default 262_144).

### Interpolación (strict)

- Las plantillas `{{...}}` se resuelven en SAD (bridge) antes de invocar runners (args/env_map/headers/body, etc.).
- Un runner debe asumir que `runner_def.args` y `runner_def.env_map` **ya están resueltos** (sin placeholders). Si detecta `{{` puede fallar fast para evitar ejecuciones ambiguas.

### Provision
- `./runner --provision` recibe `SAD_INPUT_JSON` (params resueltos, helpers, etc.) y debe ser idempotente.
- Respuesta: emitir exactamente un evento `t="provision_result"` con la estructura `{"status":"success","log_files":[]}` o error.

### Exec (transient) / Start (continuous)
- `./runner` recibe `SAD_INPUT_JSON`.
- Respuesta (transient): emitir exactamente un evento `t="result"` (final) con la forma de `RunnerResponse`.
- Start (continuous): proceso long-running; emite `t="log"` (y opcionalmente otros eventos) mientras vive. No hay `t="result"` salvo que el proceso termine por sí mismo.
- Streaming (solo si la capability tiene `streaming: true`):
  - Enviar eventos incrementales `t="chunk"` con el texto delta.
  - El bridge traduce `chunk.delta` a `ContentChunk` y lo entrega por SSE por batches vía `sad/streams/sink.StreamSink` (sin buffers infinitos).

### Protocolo de eventos en STDOUT (JSONL)

Todos los eventos se emiten como **una línea JSON por evento**. SAD parsea línea a línea (fail-fast si el runner emite bytes que no forman líneas válidas bajo el límite configurado).
Para streaming real, el runner debe **flush** tras cada línea (y evitar buffers grandes).

**Límite por evento (v0):** configurable vía `limits.max_runner_event_bytes` (default **262_144 bytes**, UTF-8).
Si se excede, SAD aborta la interacción por violación del contrato (protege de fragmentación/overflow en ports).
Cada evento debe terminar con `\n` (no se aceptan fragmentos `noeol`).

Eventos mínimos:

- Log (opcional):
  - `{"t":"log","message":"...","level":"info"}`
- Chunk de streaming (opcional; solo si `streaming: true`):
  - `{"t":"chunk","delta":"hola"}`
- Resultado final (obligatorio; exactamente uno):
  - `{"t":"result","status":"success","data":{...},"artifacts":[],"error":null}`
- Provision result (obligatorio en `--provision`; exactamente uno):
  - `{"t":"provision_result","status":"success","log_files":[]}`

### Stop
- SAD envía la línea `{"t":"stop"}` (terminada en `\n`) y/o cierra stdin.
- **Sin compatibilidad v0:** no se acepta el formato previo de input “implícito” (JSON único sin `t`).
- **Secuencia de stop (wrapper):**
  - `t0`: recibe EOF/stop.
  - `t0 → t0 + shutdown_timeout_ms`: espera salida natural (sin señales).
  - `t0 + shutdown_timeout_ms`: envía SIGTERM al grupo/subtree.
  - `t0 + shutdown_timeout_ms → t0 + 2*shutdown_timeout_ms`: grace tras SIGTERM.
  - `t0 + 2*shutdown_timeout_ms`: envía SIGKILL.
  - `t0 + 2*shutdown_timeout_ms → + post_kill_wait_ms`: espera extra antes de `waitpid`.
- Valores configurables: `shutdown_timeout_ms` (SAD) y `SAD_WRAPPER_POST_KILL_WAIT_MS`/`SAD_WRAPPER_POLL_MS` (wrapper).
- Nota: `post_kill_wait_ms` es **best-effort**; una señal `SIGCHLD` puede interrumpir el sleep.
- Runners no necesitan implementar stop explícito; basta con manejar SIGTERM/SIGKILL correctamente.

### Artefactos
- `artifacts` en `RunnerResponse` deben usar rutas relativas dentro del workspace. El decoder valida `WorkspacePath`, genera `id` y deja `url` vacío hasta que exista registro/almacenamiento público.

### Red
- Solo `managed_port` o `no_network`.
- Host/port se pasan en env (`SAD_HOST`/`SAD_PORT` y/o `runtime.port_env_var`/`host_env_var`).

### Ejemplos
- Ver `arquitectura/examples/runners/` para `generic_uvx` (CLI) y `generic_uvx_server` (server) ya listos para usarse con el wrapper.

### Guías relacionadas
- `RUNNERS_AND_AGENTS.md`: cómo los perfiles definen capacidades, cómo los runners las mapean a invocaciones reales y cómo los modos de respuesta afectan al cliente.
- `INTEGRATION.md`: guía para clientes sobre selección de capacidades y consumo de respuesta inmediata/SSE/diferida.
