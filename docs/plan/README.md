# Plan de ejecucion (SAD v3)

Plan version: v2.1

Esta carpeta define el plan de ejecucion auditable (inputs -> outputs -> evidencia), alineado con SSOT.

## Jerarquia SSOT
- docs/arquitectura/tipos.md (tipos e invariantes)
- docs/arquitectura/protocolos_runner.md (runner JSONL, stop, limites)
- docs/arquitectura/bridge.md (port_process, interpolacion, SSE upstream)
- docs/arquitectura/gateway.md (auth, ProblemDetails, SSE, UI proxy, artifacts)
- docs/arquitectura/protocolos.md (HTTP/A2A/AG-UI/A2UI)
- docs/arquitectura/config.md (perfiles, params, profiles.sources)
- docs/arquitectura/operaciones.md (CLI, daemon, env vars)
- docs/arquitectura/integracion.md (file delivery, streaming)
- docs/arquitectura/examples/snippets/* (referencias canonicas)

## Definition of Done (global)
- gleam format --check src test
- gleam test
- gleam test --coverage
- Sin violaciones de arquitectura (types sin OTP/Mist/Ports; gateway sin actor.call directo; wrapper sin STDOUT)
- Evidencia funcional reproducible (tests y/o comandos)

## Estructura
- README.md: reglas y convenciones
- deps.md: dependencias y camino critico
- limits.md: tabla canonica de config y defaults
- decisions.md: deltas explicitos respecto SSOT
- security_model.md: modelo de seguridad operativo (v0)
- sprints/: backlog y gates por sprint
- stories/: historias con inputs/outputs/evidence

## Gates y rollback
- Los gates por sprint estan en sprints/SXX.md.
- Si el gate principal falla a mitad de sprint, se congela scope nuevo y se prioriza pasar el gate.

## v0 vs post-v0
- v0 freeze: S01-S16 (core + bridge + gateway + protocolos)
- post-v0: S17-S20 (CLI/daemon, shutdown, hardening, landlock)
