# Limits y defaults canonicos

Plan version: v2.1

Generated from docs/plan/limits.toml. Do not edit by hand.
Regenerate: `make docs-limits`.

## Precedencia
1) Flags CLI (si aplica)
2) Env vars del proceso (solo ruta config y api key)
3) config.toml (interpolacion solo env vars)
4) Defaults en SadConfig.default_*

## Tabla de keys (minimo v0)
| Key | Tipo | Default | Sprint | Uso |
| --- | --- | --- | --- | --- |
| server.host | string | 0.0.0.0 | S02/S13 | bind HTTP |
| server.port | int | 8080 | S02/S13 | bind HTTP |
| auth.api_key | string | "" | S02/S13 | auth middleware (required en loader) |
| profiles.sources | array | [{type="dir", path="."}] | S02/S13 | cargar perfiles/runners |
| profiles.git_cache_dir | string | ./.sad/cache/git | S02/S13 | checkout repos |
| runners.python_bin | string | python3 | S02/S13 | ejecutar scripts .py |
| workspaces.directory | string | ./workspaces | S02/S04/S13 | cwd runner + cleanup |
| limits.call_timeout_ms | int | 30000 | S02/S14 | timeout interaccion |
| limits.status_timeout_ms | int | 5000 | S02 | status calls |
| limits.registry_timeout_ms | int | 5000 | S02 | registry calls |
| limits.health_check_timeout_ms | int | 10000 | S02/S08 | health check continuous |
| limits.shutdown_timeout_ms | int | 10000 | S02/S03 | stop escalation |
| limits.log_buffer_bytes | int | 1048576 | S02/S11 | ring buffer logs |
| limits.max_stdout_bytes | int | 10485760 | S02/S04 | guardrail OOM |
| limits.max_runner_event_bytes | int | 262144 | S02/S03 | JSONL line limit |
| limits.max_request_body_bytes | int | 1048576 | S02/S13 | mist.read_body -> 413 |
| limits.max_http_response_bytes | int | 10485760 | S02/S08 | HTTP non-streaming |
| limits.max_file_fetch_bytes | int | 52428800 | S02/S08 | fetch FileRef (si aplica) |
| limits.sse_keep_alive_interval_ms | int | 15000 | S02/S09 | SSE keep-alive |
| limits.port_range_min | int | 9000 | S02/S07 | managed_port pool |
| limits.port_range_max | int | 9999 | S02/S07 | managed_port pool |
| network.managed_port_host | string | 127.0.0.1 | S02/S07 | runner.host injection |
| log_stream.batch_byte_size | int | 4096 | S02/S09 | SSE logs batching |
| log_stream.flush_interval_ms | int | 50 | S02/S09 | SSE logs flushing |
| interaction_stream.batch_byte_size | int | 4096 | S02/S09 | streaming interact |
| interaction_stream.flush_interval_ms | int | 25 | S02/S09 | streaming interact |
| interaction_stream.push_timeout_ms | int | 250 | S02/S09 | ACK timeout |
| security.landlock_mode | string | best_effort | S20 | landlock: best_effort|enforced|off |
