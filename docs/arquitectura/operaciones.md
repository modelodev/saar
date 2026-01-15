# Operaciones

Dependencias, decisiones de arquitectura, CLI y riesgos.

## Índice

1. [Dependencias](#1-dependencias)
2. [Decisiones (ADRs)](#2-decisiones-adrs)
3. [CLI](#3-cli)
4. [Riesgos y cuestiones abiertas](#4-riesgos)

---

## 1. Dependencias

### 1.1 gleam.toml

```toml
[dependencies]
# Core Gleam
gleam_stdlib = "~> 0.67"
gleam_erlang = "~> 1.3"
gleam_otp = "~> 1.2"

# HTTP
mist = "~> 5.0"
gleam_http = "~> 4.3"
httpp = "~> 1.8"

# Parsing & Serialización
gleam_json = "~> 3.1"
tom = "~> 2.0"

# Filesystem & Environment
simplifile = "~> 2.3"
filepath = "~> 1.1"
envoy = "~> 1.1"

# Utilidades
youid = "~> 1.5"

[dev-dependencies]
gleeunit = "~> 1.2"
startest = "~> 0.2"
```

### 1.2 Justificación

| Dependencia | Rol | Por qué |
|-------------|-----|---------|
| `gleam_erlang` | Ports, processes | Base OTP |
| `gleam_otp` | Actors, supervisors | Concurrencia tipada |
| `mist` | HTTP server | Alto rendimiento, SSE nativo |
| `httpp` | HTTP client | Sync + streaming (SSE) con API Gleam; evita FFI propia de streaming |
| `gleam_json` | JSON codec | Estándar Gleam |
| `tom` | TOML parser | Para config.toml |
| `simplifile` | Filesystem | Multiplataforma |
| `filepath` | Path manipulation | Seguridad de paths |
| `youid` | UUIDs | Elimina FFI para random |

### 1.3 Excluidas

| Librería | Razón |
|----------|-------|
| `wisp` | Demasiado framework; usamos mist directo |
| `birl` | No necesitamos parsing de fechas; `now_ms()` basta |
| `gleam_crypto` | `youid` ya lo incluye transitivamente |

---

## 2. Decisiones (ADRs)

### ADR-001: Cliente HTTP — httpp

**Decisión:** Usar `httpp` para HTTP client (sync + streaming SSE).

**Razón:** Resuelve HTTP sync + streaming SSE (incluye parsing/framing SSE) de forma idiomática en Gleam, evitando implementar streaming/SSE parsing propio en v0.

**Alternativas descartadas:**
- `gleam_hackney`: obligaba a implementar/operar streaming con FFI propia
- `dream_http_client` (httpc): hoy existe y soporta streaming (chunks + integración OTP), pero no trae un parser/envelope SSE; usarlo implicaría implementar SSE parsing propio o cambiar el transporte de streaming upstream, lo cual añade complejidad en v0
- `req` (Elixir): Requiere Elixir runtime

### ADR-002: FFI centralizado

**Decisión:** Toda FFI en `sad/ffi.gleam`.

**Qué requiere FFI:**
- `now_ms()` — timestamps
 - **Ports básicos (open, send, close, receive)** mediante un shim Erlang mínimo (`sad_ffi.erl`) invocado vía `@external` en `sad/ffi.gleam`.

**Qué NO requiere FFI:**
- UUIDs → `youid`
- HTTP sync + streaming SSE → `httpp`
- Base64 → `gleam_stdlib`

**Decisión para ports:**
- FFI mínima para `open_port`/send/close/receive, encapsulada detrás de un módulo frontera (`sad/bridge/port_process.gleam`) para que el resto del sistema no dependa de Erlang.

### ADR-003: Métricas via logs

**Decisión:** v0 usa logs estructurados.

**Formato:**
```
kind=agent_started profile_id=aider instance_id=inst-123
kind=interaction_finished trace_id=trace-abc duration_ms=1234
```

### ADR-004: Artefactos en filesystem

**Decisión:** SAD no maneja S3/GCS. Artefactos en volumen montado.

**Razón:** Simplifica el core. El operador monta el storage.

### ADR-005: Validación estricta SAM

**Decisión:** Sin capa de compatibilidad "mágica".

**Comportamiento:** Payload inválido → 400 Bad Request con detalle.

### ADR-006: SSOT de tipos

**Decisión:** `tipos.md` es la SSOT **documental** de tipos (dominio/wire + contratos internos).

**Regla de implementación:**
- Tipos **dominio/wire** (serializables, sin OTP) viven en `sad/types.gleam`.
- Tipos **runtime/OTP** (p.ej. `AgentState`, `AgentRuntimeState`, `ActorMode`, `AgentResource`) viven en sus módulos (`sad/core/*`) y **no** se exponen por HTTP.

| Tipo | Dueño |
|------|-------|
| Dominio (State, Payload, Error) | `types.gleam` |
| API de actor (`AgentRef` + funciones) | `agent.gleam` |
| Wire (Request, Response) | `types.gleam` |

### ADR-006.1: Reglas de capas (sin reestructurar paths)

**Objetivo:** mantener TDD simple y evitar fugas de capa (OTP/secrets hacia gateway).

- **Domain (puro):** tipos/decoders/interpolación/params/response mapping/workspace path. No importa `gleam/otp/*`, `mist`, ni implementaciones de ports/HTTP.
- **Runtime (OTP):** actores (`AgentActor`, `RegistryActor`, `ArtifactRegistryActor`) y bootstrap de supervisión. Solo exporta APIs tipadas y transforma a `*View` antes de salir.
- **Bridge:** integración externa (ports/runners/http client/serialización). Puede usar FFI, pero no define tipos wire públicos.
- **Gateway:** solo `*View` + protocolos; nunca serializa estado runtime ni `ResolvedParams`.
- **DI/descubrimiento:** evitar `process.named`/lookups globales para comunicar actores (salvo nombres estrictamente necesarios bajo supervisor). Pasar `Subject`s/deps explícitos para hacer tests unitarios triviales.

**Nota operativa (seguridad):** SAD no se considera una API pública. Aun así, se asume que puede quedar expuesto accidentalmente; por eso v0 aplica auth por API key y endurece `/artifacts` y `/ui`. Recomendación: exponer SAD solo detrás de una capa superior (SAM/reverse proxy) y limitar alcance de red.

### ADR-007: Cancelación (fuera de v0)

**Decisión v0:** No hay cancelación explícita ni implícita por desconexión de clientes. Si el cliente SSE se desconecta, SAD deja de emitir eventos pero la interacción sigue y el runner no se mata salvo timeout/errores. Principio: SAD no toma decisiones sobre el agente sin orden superior.

### ADR-008: Puertos dinámicos y wrapper controlador

**Decisión:** Solo `managed_port` + `no_network`. SAD usa un port pool (rango explícito, `min>0` y `max>=min`) e inyecta host/port via env vars. Se elimina `static_port`.

**Kill de runners:** Los runners se lanzan siempre a través de un wrapper que crea PID namespace (rootless vía user namespace), lanza el proceso real y, al recibir `stop` (mensaje o EOF), envía SIGTERM→timeout→SIGKILL a toda su subtree. SAD cierra stdin/envía comando; el wrapper garantiza limpieza sin que SAD tenga que gestionar `os_pid`. Si el wrapper detecta muerte del parent (port owner), debe auto-terminar su subtree.

**Razón:** Evitar leaks y colisiones sin añadir FFI de señales; el wrapper encapsula aislamiento y ciclo de vida.

**Secuencia stop/delete (wrapper):**
- SAD solo cierra stdin del port o envía un comando `stop` al wrapper y espera `shutdown_timeout_ms`.
- El wrapper envía SIGTERM al grupo del runner; si tras el timeout sigue vivo, envía SIGKILL.
- `stop` no limpia workspace/artefactos; `delete` encadena stop + cleanup.

### ADR-009: Endpoints síncronos vs asíncronos (v0)

**Decisión:** SAD v0 evita “background jobs” internos. Un endpoint es:
- **Síncrono** si el trabajo es interno y se espera rápido/determinista (p.ej. cleanup de `/delete`).
- **Asíncrono** si depende de componentes externos o duración impredecible (p.ej. provisioning en `/sys/agents`, o stop que depende del wrapper/runner).

**Razón:** reduce piezas (sin estado Deleting, sin job supervisor), mantiene TDD simple y evita introducir reintentos/rehidratación en v0.

### ADR-010: SSE server en gateway — Mist

**Decisión:** Implementar los endpoints SSE del gateway usando `mist.server_sent_events(...)` (loop estilo actor) y escribir eventos con `mist.send_event(...)`.

**Razón:** reduce código propio de framing/keep-alive/cierre, mantiene BEAM-idiomatic (un proceso dueño del socket) y deja el core agnóstico (el bridge solo habla con `sad/streams/sink.StreamSink`).

---

## 3. CLI

SAD es un **binario único** con subcomandos. No hay `sad-cli` separado.

### 3.1 Servidor

```bash
# Arrancar en foreground (desarrollo)
sad serve
sad serve --port 9000
sad serve --config /etc/sad/config.toml

# Arrancar en background
sad serve -b
sad serve --background
sad serve -b --port 9000

# Matar servidor en ejecución
sad serve -k
sad serve --kill

# Reiniciar (kill + background)
sad serve -k && sad serve -b

# Ver estado
sad serve --status
# Output: SAD running on port 8080 (PID 12345)
# Output: SAD not running
```

**Comportamiento de `-b` (background):**
1. Fork del proceso
2. Escribe PID a `~/.sad/sad.pid` (o `$SAD_PID_FILE`)
3. Redirige logs a `~/.sad/sad.log` (o `$SAD_LOG_FILE`)
4. Proceso padre termina inmediatamente

**Comportamiento de `-k` (kill):**
1. Lee PID de `~/.sad/sad.pid` (o `$SAD_PID_FILE`)
2. Envía `SIGTERM` al proceso **SAD** (no a runners)
3. Espera hasta `limits.shutdown_timeout_ms` (default 10s) a que termine
4. Si no termina, envía `SIGKILL`

**Notas:**
- Exit code: `0` si no hay proceso o si se detuvo; `2` en error operacional.
- El PID file se elimina como parte del flujo de shutdown del servidor (best-effort).

**SIGTERM handler (graceful shutdown):**
- SAD reemplaza el handler por defecto de Erlang para SIGTERM (`sad/ffi/signals.gleam` + `sad/ffi/sad_signal_handler.erl`) y reenvía el evento al proceso `GatewayShutdown`.
- El gateway entra en modo *drain* y puede devolver 503 `shutting_down` a nuevas requests antes de parar el VM.

### 3.2 Herramientas (no requieren servidor)

```bash
# Validar perfiles
sad validate ./profiles/aider.json
sad validate ./profiles/            # Valida todos en directorio

# Dry-run (simula sin ejecutar)
sad dry-run ./profiles/aider.json --input payload.json --capability chat

	# Test de contrato runner
	sad runner-test ./profiles/aider.json --input payload.json
	sad runner-test --contract ./runners/generic_uvx.py
	
	# Info
	sad --version
	sad --help
	```

### 3.3 Variables de entorno

```bash
# Requeridas
export SAD_API_KEY="your-secret-key"

# Opcionales - config
export SAD_CONFIG_PATH="/etc/sad/config.toml"  # Default: ./config.toml
export SAD_LOG_LEVEL="info"                     # debug|info|warn|error
export SAD_PORT="8080"                          # Override de config

# Opcionales - daemon
export SAD_PID_FILE="~/.sad/sad.pid"           # PID file para -b/-k
export SAD_LOG_FILE="~/.sad/sad.log"           # Log file para -b
```

### 3.4 Logs

```bash
# Foreground: logs van a stdout/stderr
sad serve 2>&1 | tee /var/log/sad/sad.log

# Background con redirección
sad serve >> /var/log/sad/sad.log 2>&1 &

# Formato de logs
# [INFO] SAD v3.0.0 starting...
# [INFO] Loaded 5 profiles
# [INFO] HTTP server listening on 0.0.0.0:8080
# kind=agent_started profile_id=aider instance_id=inst-123
```

### 3.5 Systemd (producción)

```ini
# /etc/systemd/system/sad.service
[Unit]
Description=SAD - Sofias Agent Driver
After=network.target

[Service]
Type=simple
User=sad
Group=sad
Environment="SAD_API_KEY=your-secret-key"
Environment="SAD_CONFIG_PATH=/etc/sad/config.toml"
ExecStart=/usr/local/bin/sad serve
Restart=on-failure
RestartSec=5

# Graceful shutdown
TimeoutStopSec=30
KillSignal=SIGTERM

# Logs
StandardOutput=journal
StandardError=journal
SyslogIdentifier=sad

[Install]
WantedBy=multi-user.target
```

```bash
# Gestión con systemd
sudo systemctl enable sad
sudo systemctl start sad
sudo systemctl status sad
sudo systemctl stop sad
journalctl -u sad -f  # Ver logs
```

### 3.6 Docker

```dockerfile
FROM ghcr.io/gleam-lang/gleam:v1.6.1-erlang-alpine

WORKDIR /app
COPY . .
RUN gleam build

ENV SAD_API_KEY=""
ENV SAD_CONFIG_PATH="/app/config.toml"
EXPOSE 8080

CMD ["gleam", "run", "-m", "sad", "--", "serve"]
```

```bash
docker run -d \
  -p 8080:8080 \
  -e SAD_API_KEY="secret" \
  -v ./profiles:/app/profiles \
  -v ./config.toml:/app/config.toml \
  sad:latest
```

### 3.7 Validaciones de `sad validate`

| Validación | Descripción |
|------------|-------------|
| JSON syntax | Archivo válido |
| Schema compliance | Campos requeridos |
| Runner reference | `runner.type` existe en config |
| Template references | `{{params.*}}` referencian parámetros definidos |
| Secret invariant | Secretos sin default |

### 3.8 Test de contrato

`sad runner-test --contract` verifica:
1. Runner soporta `--provision`
2. Provision retorna JSON válido con `status`
3. Ejecución retorna `RunnerResponse` válido
4. Exit codes correctos

---

## 4. Riesgos

### 4.1 Resueltos

| Riesgo | Estado | Solución |
|--------|--------|----------|
| Streaming de salida | ✅ v0 | `StreamEvent` + adapters |
| Retención artefactos | ✅ | Filesystem + volumen |
| Métricas | ✅ | Logs estructurados |
| Cliente HTTP | ✅ | httpp |
| FFI | ✅ | Centralizado en ffi.gleam |
| Cancelación | ✅ v0 | No soportada (ADR-007) |
| Timeouts | ✅ v0 | Defaults en `default_sad_config()`; en producción se ajustan vía `config.toml` |
| Validación de artefactos | ✅ v0 | `ArtifactRef.path` se decodifica a `WorkspacePath`; acceso a disco es symlink-safe |

### 4.2 Pendientes

| Riesgo | Estado | Notas |
|--------|--------|-------|
| Múltiples consumers de logs | Pendiente | Diseño es single-consumer + takeover |

### 4.3 Fuera de alcance v0

- Telemetry/métricas avanzadas
- Cancelación explícita de interacciones
- Múltiples consumidores de logs
- Persistencia de estado (responsabilidad de SAM)
