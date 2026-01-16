# Plan de ejecucion (SAAR v3)

Plan version: v2.1

Esta carpeta define el plan de ejecucion auditable (inputs -> outputs -> evidencia), alineado con SSOT.

## Jerarquia SSOT
- arquitectura/tipos.md (tipos e invariantes)
- arquitectura/protocolos_runner.md (runner JSONL, stop, limites)
- arquitectura/bridge.md (port_process, interpolacion, SSE upstream)
- arquitectura/gateway.md (auth, ProblemDetails, SSE, UI proxy, artifacts)
- arquitectura/protocolos.md (HTTP/A2A/AG-UI/A2UI)
- arquitectura/config.md (perfiles, params, profiles.sources)
- arquitectura/operaciones.md (CLI, daemon, env vars)
- arquitectura/integracion.md (file delivery, streaming)
- arquitectura/examples/snippets/* (referencias canonicas)

## Definition of Done (global)
- gleam format --check src test
- gleam test
- gleam test --coverage
- Sin violaciones de arquitectura (types sin OTP/Mist/Ports; gateway sin actor.call directo; wrapper sin STDOUT)
- Evidencia funcional reproducible (tests y/o comandos)

## Estructura
- README.md: reglas y convenciones
- deps.md: dependencias y camino critico
- limits.toml: SSOT machine-readable de config y defaults
- limits.md: tabla generada desde limits.toml (make docs-limits)
- decisions.md: deltas explicitos respecto SSOT
- security_model.md: modelo de seguridad operativo (v0)
- sprints/: backlog y gates por sprint
- stories/: historias con inputs/outputs/evidence

## Gates y rollback
- Los gates por sprint estan en sprints/SXX.md.
- Si el gate principal falla a mitad de sprint, se congela scope nuevo y se prioriza pasar el gate.

## v0 vs post-v0
- v0 freeze: S01-S20 (core + bridge + gateway + protocolos + CLI/daemon + shutdown + hardening + landlock)
- post-v0: TBD (sin sprints definidos)
