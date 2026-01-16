# Iteracion 15-16: Plan de refactorizacion integral

## Contexto
Se parte de un inventario YAML completo del repositorio (64 modulos). El objetivo de esta iteracion es ejecutar el plan de refactorizacion completo sin perder funcionalidad observable, con cambios de API explicitados y validables. El entorno de ejecucion es BEAM y el sistema usa OTP con supervision en `saar/core/root_supervisor`.

## Objetivo general
Maximizar claridad, reutilizacion, coherencia arquitectonica y robustez mediante PRs pequenos y revisables. Se permite ruptura de API si se mantiene la funcionalidad.

## Reglas no negociables (operativas)
- PRs pequenos, 1-5 modulos principales por PR.
- No mezclar refactors ortogonales en el mismo PR.
- Cada PR debe incluir: objetivo, alcance, plan de pasos, cambios de API, riesgo y rollback, validacion.
- Cualquier recomendacion debe estar anclada al inventario. Si falta evidencia, marcar "requiere inspeccion en codigo".
- Regenerar inventario despues de cada PR para comprobar que se reducen duplicidades y oportunidades.

## Alcance completo (toda la iteracion)
Incluye todas las epicas y PRs definidos en el plan original, con descripcion detallada para evitar malentendidos.

### Epica E1: Unificar protocolos y helpers transversales
**Motivacion (inventario):**
- Solapamiento de `ArtifactEntry` y `ArtifactRegistryMsg` entre `saar/core/messages` y `saar/core/artifact_registry_protocol`.
- Duplicacion de helpers de llamadas temporizadas entre `saar/core/boundary_call` y `saar/otp/safe_call`.

#### PR 1: Consolidar protocolo de Artifact Registry (tamano S, riesgo bajo)
**Objetivo:** dejar un unico SSOT para el protocolo de artifact registry.

**Alcance (modulos):**
- `saar/core/messages`
- `saar/core/artifact_registry_protocol`
- `saar/core/artifact_registry`
- `saar/gateway/artifacts_api`
- `saar/gateway/http_server`

**Motivacion (inventario):**
- Overlap: "Artifact registry protocol types duplicated".

**Plan de pasos:**
1) Definir `saar/core/artifact_registry_protocol` como SSOT.
2) Reemplazar imports de `ArtifactEntry` y `ArtifactRegistryMsg` en dependientes.
3) Si hay consumidores externos, mantener reexport temporal en `saar/core/messages` con nota de deprecacion.
4) Actualizar documentacion de modulos sobre el SSOT y responsabilidades.

**Cambios de API (obligatorio):**
- API publica:
  - added: []
  - removed: [`saar/core/messages.ArtifactEntry`, `saar/core/messages.ArtifactRegistryMsg`] (si se eliminan)
  - renamed/moved: [`ArtifactEntry`, `ArtifactRegistryMsg` a `saar/core/artifact_registry_protocol`]
  - signature/type changes: []
- API interna:
  - added/removed/renamed/moved: []

**Cambios de datos/ADT:** ninguno.

**Impacto OTP:**
- Afecta `ArtifactRegistryActor` solo por cambio de ubicacion del tipo.
- No cambia la semantica de mensajes.

**Validacion:**
- Comandos: `gleam check`, `gleam test`
- Tests: ajustar imports en tests si aplica.
- Checks manuales: no aplican.

**Riesgo y rollback:**
- Riesgo: rotura de imports en modulos dependientes.
- Rollback: restaurar duplicados en `saar/core/messages`.

**Criterios de aceptacion:**
- Solo existe un SSOT para el protocolo de registry.
- No quedan referencias al tipo duplicado.

#### PR 2: Unificar helpers de llamada temporizada (tamano S, riesgo bajo)
**Objetivo:** consolidar `boundary_call` sobre `safe_call` o fusionar en un unico modulo.

**Alcance (modulos):**
- `saar/core/boundary_call`
- `saar/otp/safe_call`
- `saar/gateway/lookup`
- `saar/gateway/problem`
- `saar/gateway/health`

**Motivacion (inventario):**
- Overlap: "Timed actor call helpers".

**Plan de pasos:**
1) Definir `saar/otp/safe_call` como primitivo estable.
2) Reimplementar `saar/core/boundary_call` como wrapper, o mover funciones al modulo `safe_call`.
3) Actualizar dependientes para consumir una sola ruta.
4) Ajustar documentacion para reflejar punto unico de llamada segura.

**Cambios de API (obligatorio):**
- API publica:
  - added: [] (si no se expone nuevo wrapper)
  - removed: [`saar/core/boundary_call.call`, `saar/core/boundary_call.call_unwrap_result`] (si se elimina)
  - renamed/moved: mover funciones a `saar/otp/safe_call` si aplica
  - signature/type changes: no esperado
- API interna:
  - added/removed/renamed/moved: wrappers internos si aplica

**Cambios de datos/ADT:** ninguno.

**Impacto OTP:** ninguno.

**Validacion:**
- Comandos: `gleam check`, `gleam test`
- Tests: actualizar imports en tests o modulos gateway.

**Riesgo y rollback:**
- Riesgo: cambios de path en imports.
- Rollback: restaurar modulo `boundary_call` original.

**Criterios de aceptacion:**
- No hay duplicidad de helpers en el arbol.
- Todos los call sites usan la ruta unificada.

### Epica E2: ADTs para eliminar estados ilegales (quick wins)
**Motivacion (inventario):**
- Oportunidades ADT en `saar/types/runner`, `saar/types/profile`, `saar/types/input`.
- Simplification: streaming ADT en `saar/bridge/interaction`.

#### PR 3: ADT RuntimeConfig para red gestionada (tamano S, riesgo bajo)
**Objetivo:** evitar combinaciones invalidas de `NoNetwork` con variables de entorno.

**Alcance (modulos):**
- `saar/types/runner`
- `saar/bridge/managed_port_env`
- `saar/bridge/runner`

**Motivacion (inventario):**
- ADT opportunity: RuntimeConfig.

**Plan de pasos:**
1) Fase A: introducir ADT `RuntimeConfig` con variantes `ManagedPort` y `NoNetwork`.
2) Agregar funciones puente para leer el record legado (si existe) y producir el ADT.
3) Ajustar `managed_port_env` para pattern-match por variante.
4) Fase B: migrar decoders/builders y eliminar campos legacy.

**Cambios de API (obligatorio):**
- API publica:
  - added: [`RuntimeConfig.ManagedPort`, `RuntimeConfig.NoNetwork`]
  - removed: [`RuntimeConfig.mode`, `RuntimeConfig.host_env_var`, `RuntimeConfig.port_env_var`] (fase B)
  - renamed/moved: []
  - signature/type changes: cambio de tipo `RuntimeConfig`
- API interna:
  - added/removed/renamed/moved: adaptadores o helpers de compat

**Cambios de datos/ADT:**
- Nuevo tipo `RuntimeConfig` como ADT.
- Migracion: fase A/B con compat temporal.

**Impacto OTP:** none.

**Validacion:**
- Comandos: `gleam check`, `gleam test`
- Tests: unit tests de `managed_port_env`.

**Riesgo y rollback:**
- Riesgo: decoders que dependan de campos legacy.
- Rollback: mantener record original.

**Criterios de aceptacion:**
- No se inyectan env vars en `NoNetwork`.
- Decoders siguen aceptando config previa (si aplica).

#### PR 4: ADT ResponseMapping sin estado vacio (tamano S, riesgo bajo)
**Objetivo:** eliminar `Some(ResponseMapping(None,None))` y dejar default explicito.

**Alcance (modulos):**
- `saar/types/profile`
- `saar/decoders`
- `saar/response_mapping`

**Motivacion (inventario):**
- ADT opportunity: ResponseMapping con opciones vacias.

**Plan de pasos:**
1) Fase A: introducir ADT `ResponseMapping` con `Default | Text | Artifacts | Both`.
2) Mapear objeto vacio del decoder a `Default`.
3) Fase B: migrar `apply_response_mapping` y eliminar record legacy.

**Cambios de API (obligatorio):**
- API publica:
  - added: variantes `Default`, `Text`, `Artifacts`, `Both`
  - removed: campos `text_pointer`, `artifacts_pointer` (fase B)
  - renamed/moved: []
  - signature/type changes: cambio de tipo `ResponseMapping`
- API interna: none esperada

**Cambios de datos/ADT:**
- Nuevo `ResponseMapping` ADT.
- Eliminacion del record con opciones.

**Impacto OTP:** none.

**Validacion:**
- `gleam check`, `gleam test`
- Tests de decoder de mapping y de `apply_response_mapping`.

**Riesgo y rollback:**
- Riesgo: mapeo incorrecto de default.
- Rollback: restaurar record con opciones.

**Criterios de aceptacion:**
- Ningun estado "vacio" distinto de `None`.
- Comportamiento igual para mapping ausente.

### Epica E3: ADTs de ciclo de vida y mensajes internos OTP
**Motivacion (inventario):**
- `SaarInputMeta` con `instance_id` opcional.
- `AgentStatusView` con `phase + failure_reason`.
- `AgentManagerMsg` con mensajes internos no separables.

#### PR 5: ADT StreamMode para streaming (tamano M, riesgo medio)
**Objetivo:** eliminar `streaming=True` con `stream_sink=None`.

**Alcance (modulos):**
- `saar/bridge/interaction`
- `saar/core/agent`
- `saar/gateway/agents_api`

**Motivacion (inventario):**
- Simplification opportunity: StreamMode ADT.

**Plan de pasos:**
1) Fase A: definir `StreamMode` con `Streaming(StreamSink)` y `NonStreaming`.
2) Crear helper de compatibilidad `from_legacy(streaming, stream_sink)`.
3) Usar `StreamMode` en `interaction.run` y `agent.interact`.
4) Fase B: ajustar `agents_api` y eliminar parametros legacy.

**Cambios de API (obligatorio):**
- API publica:
  - added: `StreamMode.Streaming`, `StreamMode.NonStreaming`
  - removed: parametros `streaming` y `stream_sink` (fase B)
  - signature/type changes: `interaction.run`, `agent.interact`, `AgentRequest`
- API interna: helpers de compat si aplica

**Cambios de datos/ADT:**
- Nuevo `StreamMode` ADT.

**Impacto OTP:**
- Mensajes de `AgentMsg.Interact` cambian su payload.
- Revisar handlers y tests de `AgentActor`.

**Validacion:**
- `gleam check`, `gleam test`
- Tests para streaming y no streaming, y error paths.
- Manual: endpoints SSE (si se usan en ambiente de prueba).

**Riesgo y rollback:**
- Riesgo: cambios en serializacion de requests.
- Rollback: volver a `Bool + Option`.

**Criterios de aceptacion:**
- No existe `missing_stream_sink`.
- Cada request tiene un modo streaming explicito.

#### PR 6: ADT SaarInputMeta (tamano M, riesgo medio)
**Objetivo:** impedir `Continuous` sin `instance_id`.

**Alcance (modulos):**
- `saar/types/input`
- `saar/bridge/runner`
- `saar/gateway/agents_api`
- `saar/core/agent_manager`

**Motivacion (inventario):**
- ADT opportunity: `SaarInputMeta` con Option.

**Plan de pasos:**
1) Fase A: introducir `SaarInputMeta` ADT con `TransientMeta` y `ContinuousMeta`.
2) Agregar transformador desde el record legado.
3) Migrar constructores en `gateway/agents_api` y `bridge/runner`.
4) Fase B: eliminar record legacy y actualizar decoders/builders.

**Cambios de API (obligatorio):**
- API publica:
  - added: `SaarInputMeta.TransientMeta`, `SaarInputMeta.ContinuousMeta`
  - removed: `SaarInputMeta.instance_id: Option`, `SaarInputMeta.mode` (fase B)
  - signature/type changes: `SaarInputMeta` y constructores
- API interna: helpers de compat si aplica

**Cambios de datos/ADT:**
- Nuevo `SaarInputMeta` ADT.

**Impacto OTP:**
- Impacta payloads de mensajes que lleven meta (requiere inspeccion en codigo).

**Validacion:**
- `gleam check`, `gleam test`
- Tests en decoders/builders y en `bridge/runner`.

**Riesgo y rollback:**
- Riesgo: callers que construyen meta sin instance_id.
- Rollback: mantener record con Option.

**Criterios de aceptacion:**
- El estado ilegal no se puede representar.

#### PR 7: ADT AgentPhase con FailureReason embebido (tamano M, riesgo medio)
**Estado:** completado.
**Objetivo:** eliminar combinaciones invalidas de `phase` y `failure_reason`.

**Alcance (modulos):**
- `saar/types/agent`
- `saar/core/agent`
- `saar/core/registry`
- `saar/gateway/agents_api`

**Motivacion (inventario):**
- ADT opportunity: `AgentPhase` con `Failed(FailureReason)`.

**Plan de pasos:**
1) Fase A: introducir variante `Failed(FailureReason)` y adaptadores desde el record actual.
2) Migrar constructores de estado en `core/agent`.
3) Fase B: eliminar `failure_reason` en `AgentStatusView` y ajustar JSON/encoders (requiere inspeccion en codigo).

**Cambios de API (obligatorio):**
- API publica:
  - added: `AgentPhase.Failed(FailureReason)`
  - removed: `AgentStatusView.failure_reason` (fase B)
  - signature/type changes: `AgentPhase` y `AgentStatusView`
- API interna: adaptadores si aplica

**Cambios de datos/ADT:**
- Modificacion de `AgentPhase` y de `AgentStatusView`.

**Impacto OTP:**
- Mensajes de estado (registry y gateway) deben ajustarse.

**Validacion:**
- `gleam check`, `gleam test`
- Tests de status y encoders.

**Riesgo y rollback:**
- Riesgo: cambios en payloads de status.
- Rollback: restaurar `failure_reason` separado.

**Criterios de aceptacion:**
- No existe `Failed` sin razon.
- No hay combinaciones invalidadas por el tipo.

#### PR 8: Separar comandos e internos en AgentManagerMsg (tamano M, riesgo medio)
**Objetivo:** impedir que clientes externos envien mensajes internos sin efecto.

**Alcance (modulos):**
- `saar/core/messages`
- `saar/core/agent_manager`
- `saar/core/agent_factory_supervisor`

**Motivacion (inventario):**
- OTP ADT opportunity: `AgentManagerMsg` con `Cmd` e `Internal`.

**Plan de pasos:**
1) Crear `AgentManagerCmd` y `AgentManagerInternal`.
2) Refactor de handlers para que expongan solo `Cmd` al exterior.
3) Migrar mensajes internos a la rama `Internal`.

**Cambios de API (obligatorio):**
- API publica:
  - added: `AgentManagerMsg.Cmd`, `AgentManagerMsg.Internal`, `AgentManagerCmd`, `AgentManagerInternal`
  - removed: variantes internas publicas (p.ej. `DeleteWorkerDone`, `DeleteWorkerDown`)
  - signature/type changes: `AgentManagerMsg`
- API interna: none, salvo helpers de construccion

**Cambios de datos/ADT:**
- Nuevo ADT con separacion de dominios.

**Impacto OTP:**
- Mensajes del actor cambian; requiere ajustar call sites.

**Validacion:**
- `gleam check`, `gleam test`
- Tests de handlers y rutas de mensajes.

**Riesgo y rollback:**
- Riesgo: message routing incorrecto.
- Rollback: mantener ADT plano.

**Criterios de aceptacion:**
- Externos no pueden enviar mensajes internos.
- Los mensajes internos siguen funcionando desde el actor.

### Epica E4: Hotspots y robustez de frontera
**Motivacion (inventario):**
- Hotspot de decodificacion y resolucion de parametros.
- Hotspot FFI con errores opacos.

#### PR 9: Centralizar validacion de perfiles y parametros (tamano M, riesgo medio)
**Objetivo:** evitar deriva de validacion entre decoders, sources y params.

**Alcance (modulos):**
- `saar/decoders`
- `saar/profiles_sources`
- `saar/params`
- `saar/types/profile`

**Motivacion (inventario):**
- Hotspot parsing: decoders + profiles_sources + params.

**Plan de pasos:**
1) Inspeccionar codigo para detectar validaciones duplicadas (requiere inspeccion en codigo).
2) Crear helpers comunes en un modulo compartido o en `saar/decoders`.
3) Migrar `profiles_sources` y `params` a esos helpers.
4) Ajustar tests de validacion.

**Cambios de API (obligatorio):**
- API publica:
  - added: helpers de validacion si se exponen
  - removed: none
  - signature/type changes: none
- API interna: helpers nuevos y uso en call sites

**Cambios de datos/ADT:** none.

**Impacto OTP:** none.

**Validacion:**
- `gleam check`, `gleam test`
- Tests de casos limite en validacion de perfiles.

**Riesgo y rollback:**
- Riesgo: cambio sutil en reglas de validacion.
- Rollback: restaurar validaciones locales.

**Criterios de aceptacion:**
- Validaciones consistentes en todos los caminos.

#### PR 10: ADT de errores FFI para puertos (tamano S, riesgo bajo)
**Objetivo:** centralizar errores FFI compartidos.

**Alcance (modulos):**
- `saar/ffi`
- `saar/bridge/port_process`
- `saar/profiles_sources`

**Motivacion (inventario):**
- Hotspot FFI boundary: errores opacos y dispersos.

**Plan de pasos:**
1) Definir `FfiError` en `saar/ffi`.
2) Mapear errores actuales a `FfiError` en `port_process`.
3) Ajustar `profiles_sources` para usar `FfiError`.

**Cambios de API (obligatorio):**
- API publica:
  - added: `FfiError`
  - removed: none
  - signature/type changes: tipos de error en funciones FFI si aplica
- API interna: none

**Cambios de datos/ADT:**
- Nuevo `FfiError` ADT.

**Impacto OTP:** none.

**Validacion:**
- `gleam check`, `gleam test`
- Tests de mapeo de errores.

**Riesgo y rollback:**
- Riesgo: perdida de detalle en errores.
- Rollback: mantener errores ad-hoc.

**Criterios de aceptacion:**
- Errores FFI consistentes y claros.

### Epica E5: Orden y coherencia de supervision OTP
**Motivacion (inventario):**
- Refactor signal en `saar/core/root_supervisor`: orden de children.

#### PR 11: Ajustar orden de children en root_supervisor (tamano S, riesgo bajo)
**Objetivo:** iniciar `agent_factory` antes de `agent_manager`, o documentar por que es seguro.

**Alcance (modulos):**
- `saar/core/root_supervisor`
- `saar/core/supervisor_names`

**Motivacion (inventario):**
- Refactor signal: `agent_manager` se inicia antes que `agent_factory`.

**Plan de pasos:**
1) Cambiar el orden de children, o documentar la razon si no se cambia.
2) Ajustar documentacion de modulo si se altera el flujo de arranque.

**Cambios de API (obligatorio):**
- API publica:
  - added: []
  - removed: []
  - renamed/moved: []
  - signature/type changes: []
- API interna: none

**Cambios de datos/ADT:** none.

**Impacto OTP:**
- Cambia orden de arranque y de restarts en estrategia rest_for_one.

**Validacion:**
- `gleam check`, `gleam test`
- Manual: arranque del sistema.

**Riesgo y rollback:**
- Riesgo: orden esperado por dependencias internas.
- Rollback: restaurar orden anterior y documentar.

**Criterios de aceptacion:**
- Orden coherente o justificado de forma explicita.

## Cambios de API globales (consolidados por PR)
- PR 1: mover `ArtifactEntry` y `ArtifactRegistryMsg` a `saar/core/artifact_registry_protocol`.
- PR 2: eliminar o mover `boundary_call.call` y `call_unwrap_result`.
- PR 3: `RuntimeConfig` pasa de record a ADT `ManagedPort | NoNetwork`.
- PR 4: `ResponseMapping` pasa a ADT `Default | Text | Artifacts | Both`.
- PR 5: `StreamMode` reemplaza `streaming: Bool` y `stream_sink: Option`.
- PR 6: `SaarInputMeta` pasa a ADT `TransientMeta | ContinuousMeta`.
- PR 7: `AgentPhase.Failed(FailureReason)` y eliminacion de `failure_reason` en `AgentStatusView`.
- PR 8: `AgentManagerMsg` separado en `Cmd` y `Internal`.
- PR 10: `FfiError` para errores de frontera FFI.
- PR 11: sin cambios de API.

## Dependencias y orden recomendado
1) PR 1 y PR 2 primero (eliminan duplicacion).
2) PR 11 temprano (bajo riesgo).
3) PR 3 y PR 4 (ADTs de bajo riesgo).
4) PR 5, PR 6, PR 7 (ADTs de flujo y ciclo de vida).
5) PR 8 (mensajes OTP).
6) PR 9 y PR 10 (hotspots y errores).

## Validacion global por PR
- `gleam check`
- `gleam test`
- Si aplica: pruebas manuales de endpoints HTTP/SSE.

## Regeneracion de inventario
Al cerrar cada PR:
1) Regenerar inventario.
2) Comprobar disminucion de overlaps y oportunidades resueltas.
3) Actualizar este documento si cambia el alcance.

## Ventana temporal
- Iteracion programada para los dias 15 y 16.
- El alcance completo se considera la meta; si alguna tarea no cabe en la ventana, se replanifica sin perder detalle ni objetivos.
