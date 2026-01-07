# Decisions

Plan version: v2.1

D-001 profiles.sources only
- Delta: solo profiles.sources (dir/git) y se buscan siempre /profiles y /runners.
- Razon: simplificar carga y evitar sources legacy (directory/s3).

D-003 wrapper silencio con DEBUG=1
- Delta: wrapper silencioso en STDOUT; logs solo por STDERR si DEBUG=1.

D-005 A2UI selector header
- Delta: se fija X-SAD-UI-Protocol: a2ui/v0.8 para forzar A2UI en endpoint nativo.

D-006 port range bajo limits.*
- Delta: se mantiene el rango bajo limits.port_range_min/limits.port_range_max (SSOT).

D-007 git sources con cache + fetch
- Decision: git sources usan profiles.git_cache_dir; clone si no existe, fetch si existe, checkout ref (o HEAD).

D-008 runner resolution solo dentro de sources
- Decision: runner se resuelve en <root>/runners/<type> o <root>/runners/<type>.py; sin fallback externo.

D-009 health/ready requiere perfiles cargados
- Delta: /health/ready retorna 200 solo si profiles_count > 0 (ademas de proceso vivo).

D-010 A2A es por instancia (agente = instancia)
- Decision: los endpoints A2A son instance-scoped bajo /instances/<instance_id>/; el Agent Card se deriva de la instancia.

D-011 Registry impone unicidad por instance_id
- Decision: registry.register falla si ya existe cualquier instance_id (aunque profile_id difiera); expone lookup_by_instance_id.

D-012 a2a_base_url por instancia
- Decision: /sys/agents y /agents/:instance_id incluyen a2a_base_url; se construye desde X-Forwarded-* o Host, con fallback a path relativo.

D-013 propiedades y hardening (S19)
- Decision: anadir 2-6 properties nuevas por area (types, workspace, runner_contract, params, decoders, interpolator, adapters) con 200 iteraciones (100 si son lentas).
- Decision: coverage sin threshold, solo no decrecer.
- Decision: logs pueden drop/coalesce; streaming interact no-drop mientras haya ACK.
- Decision: git cache corrupto => renombrar a .broken-<ts> y reclonar (best-effort).

D-014 Landlock mode y policy (S20)
- Decision: security.landlock_mode = best_effort|enforced|off (default best_effort).
- Decision: scope v0: write solo workspace; read workspace, runners dir, profiles dir y /proc/self; denegar resto.
- Decision: enforced falla la instancia (failure_reason LANDLOCK_UNAVAILABLE), best_effort continua sin Landlock.

Notas:
- D-002 (max_runner_event_bytes configurable) y D-004 (managed_port_host configurable) ya estan integradas en SSOT, por eso no aparecen como deltas.
