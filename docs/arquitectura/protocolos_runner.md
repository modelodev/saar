# Contrato de runners (detallado)

**Lanzamiento vía wrapper** (obligatorio en v0):
- SAD siempre invoca `wrapper -- <runner> ...` (ver `arquitectura/examples/wrapper_pid_namespace.md`).
- Wrapper crea PID+user namespace, lanza el runner y gestiona stop: `{"t":"stop"}` o EOF → SIGTERM → timeout → SIGKILL a la subtree.
- SAD no necesita FFI de señales ni conocer `os_pid`; la FFI solo cubre open/send/close del port (idealmente vía `sad/bridge/port_process.gleam`).
 - **Wrapper recomendado:** binario compilado tipo “init PID1” (C/Rust/Go). Evitar bash como wrapper: no es fiable para reaping/propagación de señales.

### Entradas y salidas
- STDIN: `SAD_INPUT_JSON` (validado) para start/exec; `{"t":"stop"}` para detener; EOF equivale a stop.
- STDOUT: **stream de eventos** (una línea por evento, JSONL/NDJSON). Incluye logs, streaming y el resultado final.
- STDERR: fuera de contrato (diagnóstico local). SAD no debe depender de capturarlo ni de separarlo de STDOUT.

**Racional (OTP/BEAM):** `open_port` no ofrece separación real de stdout/stderr cuando se usa `use_stdio`. Para evitar complejidad (wrappers multiplexores, `erlexec`, etc.), SAD trata la salida capturada como **un único canal** y la separación se hace **a nivel de protocolo** (eventos tipados).

### Guardrails (fail-fast sin sorpresas)

- **Wrapper silencioso en STDOUT:** el wrapper no debe imprimir banners/logs a STDOUT; si necesita logs, que vaya a STDERR o a fichero.
- **`sad runner-test` como gate:** cualquier runner/wrapper debe pasar `sad runner-test` (ideal: CI obligatorio) para evitar “basura” accidental en STDOUT.
- **Adaptadores fuera del core:** si queréis ejecutar un binario que escribe texto libre, haced un “shim runner” que capture su salida y emita eventos JSONL; ese shim vive fuera del core SAD.

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
- SAD envía `{"t":"stop"}` y/o cierra stdin.
- Wrapper propaga SIGTERM → espera `shutdown_timeout_ms` → SIGKILL si sigue vivo.
- Runners no necesitan implementar stop explícito; basta con manejar SIGTERM/SIGKILL correctamente.

### Artefactos
- `artifacts` en `RunnerResponse` deben usar rutas relativas dentro del workspace. El decoder valida `WorkspacePath` y expone UUID público.

### Red
- Solo `managed_port` o `no_network`.
- Host/port se pasan en env (`SAD_HOST`/`SAD_PORT` y/o `runtime.port_env_var`/`host_env_var`).

### Ejemplos
- Ver `arquitectura/examples/runners/` para `generic_uvx` (CLI) y `generic_uvx_server` (server) ya listos para usarse con el wrapper.
