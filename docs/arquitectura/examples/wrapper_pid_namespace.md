# Wrapper para runners (PID namespace) sin FFI de señales en SAAR

Objetivo: lanzar cualquier runner a través de un wrapper que:
- Cree un PID namespace (y user namespace para hacerlo sin root).
- Lance el runner real.
- Al recibir control por stdin (JSONL): `{"t":"input","payload":<SAAR_INPUT_JSON>}` → reenvía payload al runner y cierra su stdin; `{"t":"stop"}` o EOF → SIGTERM→timeout→SIGKILL a toda la subtree.
- Si el parent (port owner) muere, se auto-destruya y mate el namespace.

## Notas importantes
- **Decisión v0:** el wrapper debe ser un **binario compilado** (C/Rust/Go). No usar scripts bash como wrapper “init”:
  bash no es fiable para ser PID 1 (reaping de zombies, propagación de señales, process groups) y acabará creando huérfanos bajo carga/errores.
- SAAR sigue necesitando FFI mínima para `open_port`/send/close (ver `../operaciones.md` ADR-002). Aquí “sin FFI” se refiere a **no necesitar FFI de señales/kill en SAAR**: el wrapper gestiona SIGTERM/SIGKILL.
- Sin `CLONE_NEWUSER` el `CLONE_NEWPID` fallará para usuarios normales; hay que habilitar ambos. En userns, habrá que mapear uid/gid (0:UID real).
- **Best-effort:** si namespaces no están permitidos (p.ej. Docker/CI), el wrapper debe hacer fallback a process group y mantener las mismas semantics de stop.
- **Test-only:** `SAAR_WRAPPER_FORCE_FALLBACK=1` fuerza el modo fallback para pruebas deterministas (no recomendado en producción). Si no se define, el wrapper intenta aplicar sandbox con la configuracion normal.
- Salida: SAAR captura un único canal vía `open_port` (STDOUT del wrapper/runner). Para mantener el contrato simple:
  - El wrapper debe permanecer en silencio en STDOUT.
  - El runner emite eventos JSONL por STDOUT (logs/stream/result) según `arquitectura/protocolos_runner.md`.
  - Cualquier diagnóstico del wrapper va por STDERR (fuera de contrato). No se usa `stderr_to_stdout`.
- Stop: SAAR puede enviar la línea `{"t":"stop"}` (terminada en `\n`) por stdin o simplemente cerrar stdin; el wrapper debe tratar ambos como orden de parada.

## Requisitos mínimos (v0)

Un wrapper válido debe cumplir:
- **PID 1 en pidns:** actuar como “init” del namespace y **reapear zombies** (`waitpid(-1, ...)` en loop o handler `SIGCHLD`).
- **Propagación de señales:** ante stop, enviar SIGTERM→grace→SIGKILL a toda la subtree del namespace (y esperar reap final).
- **Control por stdin (JSONL):** `{"t":"input","payload":<SAAR_INPUT_JSON>}` (reenviar payload y cerrar stdin), `{"t":"stop"}` (terminada en `\n`) y EOF como orden de parada.
- **Sin ruido por STDOUT:** no escribir bytes en STDOUT (SAAR espera JSONL del runner ahí). Logs/diagnóstico del wrapper solo por STDERR.
- **Salir si muere el parent:** `PR_SET_PDEATHSIG` o, alternativamente, depender de EOF en stdin si el BEAM/port owner muere.

## Esquema de implementación (C)

El ejemplo completo está en `arquitectura/examples/wrapper/wrapper.c`.
En este documento mantenemos solo los requisitos y el contrato.

## Integración con SAAR
- SAAR lanza siempre el wrapper vía Port: `spawn_executable wrapper -- <runner> ...`.
- Input: SAAR envía `{"t":"input","payload":<SAAR_INPUT_JSON>}` (terminada en `\n`); el wrapper reenvía `payload` al runner y cierra su stdin.
- Stop/Delete: SAAR puede enviar la línea `{"t":"stop"}` (terminada en `\n`) por stdin y/o cerrar stdin; el wrapper hace SIGTERM→SIGKILL a toda la subtree del namespace.
- Salida: el runner emite eventos JSONL por STDOUT (incluye `t="log"`, `t="chunk"`, `t="result"`). El wrapper no debe emitir bytes por STDOUT; cualquier diagnóstico va por STDERR.

## Riesgos y pendientes
- `apply_user_ns_mappings()` debe implementarse correctamente (writing uid_map/gid_map requiere privilegios o restricciones específicas del kernel).
- El wrapper debe ser empaquetado junto a SAAR y usado de forma predeterminada para todos los runners.
