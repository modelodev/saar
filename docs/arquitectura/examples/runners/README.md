# Runners genéricos y contrato de stop

Estos runners se lanzan siempre a través del wrapper de PID namespace (`../wrapper_pid_namespace.md`). El wrapper se encarga de:
- Crear PID namespace + user namespace (rootless).
- Lanzar el runner real.
- Al recibir la línea `{"t":"stop"}` (terminada en `\n`) por stdin o EOF, enviar SIGTERM → timeout → SIGKILL a toda la subtree del namespace y salir.
- Autodestruirse si muere el parent (port owner).

Expectativas para cualquier runner:
- STDOUT: stream JSONL (1 JSON por línea) con eventos tipados:
  - `{"t":"log","message":"...","level":"info"}` (opcional)
  - `{"t":"chunk","delta":"..."}` (opcional; si `streaming: true`)
  - `{"t":"result", ...RunnerResponse...}` (obligatorio; exactamente uno)
- STDERR: fuera de contrato (diagnóstico local); SAD no depende de capturarlo.
- `runner_def.env_map` y `runner_def.args` llegan ya resueltos por SAD (sin `{{...}}`).
- No necesitan implementar stop; basta con reaccionar a SIGTERM/SIGKILL y salir.
- Host/port llegan por env (`SAD_HOST`/`SAD_PORT` o `runtime.port_env_var/host_env_var`).
- Input llega en `SAD_INPUT_JSON` (ya validado) reenviado por el wrapper desde `{"t":"input","payload":<SAD_INPUT_JSON>}`.
- SAD habla con el wrapper/runner vía una única abstracción (`sad/bridge/port_process.gleam`) para aislar la implementación de ports (FFI mínima).

Runners incluidos:
- `generic_uvx.py`: para agentes transient (CLI).
- `generic_uvx_server.py`: para agentes continuous (server).

Nota (continuous): el runner de servidor debe capturar stdout/stderr del proceso hijo y reemitirlos como `t="log"` por STDOUT; el proceso hijo no puede escribir bytes libres al STDOUT del runner, porque SAD espera JSONL.
