# Estrategia de Tests SAD v3

**Este documento es el SSOT (Single Source of Truth) para todos los tests del proyecto.**

Los archivos de módulos individuales (`tipos.md`, `config.md`, etc.) pueden incluir 1-2 ejemplos
ilustrativos, pero la definición completa de tests está aquí.

Plan de tests módulo a módulo, distinguiendo **core puro** (unit tests) de **bordes con IO** (integración).

## 1. Estrategia general

### 1.1. Capas de test

| Capa | Módulos | Tipo de test |
|------|---------|--------------|
| **Core** | types, workspace, runner_contract, params, decoders, core/*, adapters/*, sse | Unit tests puros |
| **Bordes** | config, bridge/*, gateway/* | Tests de integración con IO |

### 1.2. Frameworks

| Framework | Cuándo usar |
|-----------|-------------|
| **gleeunit** | Casos concretos, FSM, integración con procesos/ports/HTTP, zoo de agentes |
| **gleam_qcheck** | Invariantes y propiedades en módulos puros, roundtrips encode/decode |

**Regla general:**
- Si el módulo es puro y tiene invariantes matemáticos → gleam_qcheck
- Si necesita fixtures concretos o IO → gleeunit

---

## 2. Zoo de agentes de test

Perfiles en `tests/fixtures/profiles/*.json` con runners reales (scripts Python/bash).

### 2.1. `echo_cli` (Transient, CLI)

**Comportamiento:** Lee `SAD_INPUT_JSON` por stdin, espera ~100ms, devuelve `RunnerResponse` con `status=success` y `data` = eco del input.

**Valida:**
- Flujo transient básico: construcción de `SadInput`, paso por stdin, parseo de `RunnerResponse`
- Manejo de `StatusSuccess`

**Uso:** `runner_contract`, `bridge/runner`, `core/agent` (transient feliz)

### 2.2. `echo_server` (Continuous, HTTP)

**Comportamiento:** Servidor HTTP con:
- `GET/POST /echo` → devuelve body tal cual
- `GET /health` → 200 rápido

**Valida:**
- `bridge/client`: construcción URL, headers, body, parseo respuesta
- Health checks positivos
- Proxy HTTP en gateway

**Uso:** `bridge/client`, `gateway/api`, `core/agent` (continuous sano)

### 2.3. `greedy_logger` (Transient, CLI)

**Comportamiento:** Emite muchos eventos `t="log"` por STDOUT (JSONL), luego emite un `t="result"` success minimal.

**Valida:**
- `bridge/runner` parsea eventos JSONL y preserva invariantes (sin “bytes libres”)
- Bufferiza logs sin explotar memoria
- `LogEvent` se envía correctamente

**Uso:** `bridge/runner`, `core/agent`, logs

### 2.4. `slow_poke` (Continuous, HTTP)

**Comportamiento:** `/health` tarda ~10s en responder; otros endpoints normales.

**Valida:**
- `bridge/client.health_check` respeta `health_check_timeout_ms`
- Actor marca agente como `Failed` si health check falla

**Uso:** `bridge/client`, `core/agent` (provisioning timeout)

### 2.5. `crasher` (Continuous, HTTP)

**Comportamiento:** Arranca OK, tras primer request el proceso muere con `PortExit(code!=0)`.

**Valida:**
- Detección de muerte via Port → `ServerDied`
- Transición `Ready → Failed`
- Política de reinicio del supervisor

**Uso:** `bridge/runner`, `core/agent`, `core/agent_manager`

### 2.6. `artifact_gen` (Transient, CLI)

**Comportamiento:** Crea archivo en workspace, devuelve `RunnerResponse` con `artifacts = [{name, path, mime}]`.

**Valida:**
- `ArtifactRef` con `WorkspacePath` válido
- Validación en `workspace.gleam`
- Servicio `/artifacts/:artifact_id`

**Uso:** `runner_contract`, `workspace`, `bridge/runner`, `gateway/proxy`

### 2.7. `streaming_echo` (Transient, CLI con streaming)

**Comportamiento:** Emite eventos `t="chunk"` (JSONL) por STDOUT con delays y termina emitiendo un `t="result"` (success).

**Valida:**
- Emisión de `StreamStarted`, `ContentChunk` y finalización vía `InteractionDone` (con cierre de stream desde el actor)
- Conversión a AG-UI y A2A

**Uso:** `bridge/runner` (streaming), `adapters/agui`, `adapters/a2a`

---

## 3. Core - módulos puros

### 3.1. `sad/types.gleam`

**Frameworks:** gleeunit + gleam_qcheck

#### gleeunit

| Test | Descripción |
|------|-------------|
| `agent_ready_transient_no_resource` | `agent_ready_transient(params)` crea `ReadyTransient` |
| `agent_ready_continuous_with_resource` | `agent_ready_continuous(params, resource)` crea `ReadyContinuous` |
| `agent_state_predicates` | `is_created/provisioning/ready/ready_transient/ready_continuous/failed` respetan semántica |
| `is_ready_covers_both_variants` | `is_ready(ReadyTransient(_)) == True` y `is_ready(ReadyContinuous(_, _)) == True` |
| `get_resource_returns_some_for_continuous` | `get_resource(ReadyContinuous(_, r))` → `Some(r)` |
| `get_resource_returns_none_for_transient` | `get_resource(ReadyTransient(_))` → `None` |
| `error_kind_roundtrip` | `from_string(to_string(k)) == Ok(k)` para cada `ErrorKind` |
| `derive_helpers_payload_chat` | Extrae `last_user_content` correctamente |
| `derive_helpers_payload_files` | `last_user_files` contiene los archivos |
| `derive_helpers_payload_mixed` | Combina mensaje + archivos |
| `system_log_kind_to_string_all_variants` | Todas las variantes de `SystemLogKind` serializan correctamente |
| `system_log_formats_with_labels` | `system_log(AgentStarted, labels, ...)` → `"kind=agent_started key=value"` |
| `system_log_formats_empty_labels` | `system_log(AgentStarted, dict.new(), ...)` → `"kind=agent_started"` |
| `system_log_preserves_trace_id` | `trace_id` se propaga al `LogEvent` |
| `system_log_preserves_instance_id` | `instance_id` se propaga al `LogEvent` |
| `system_log_source_is_system_log` | `LogEvent.source == SystemLog` |
| `secret_value_inspect_redacted` | `secret_inspect(secret_value("key"))` → `"***REDACTED***"` |
| `secret_to_env_value_returns_inner` | `secret_to_env_value(secret_value("key"))` → `"key"` |
| `secret_is_empty_true` | `secret_is_empty(secret_value(""))` → `True` |
| `secret_is_empty_false` | `secret_is_empty(secret_value("x"))` → `False` |
| `resolved_value_inspect_normal` | `resolved_value_inspect(NormalValue(StringVal("x")))` → `"x"` |
| `resolved_value_inspect_secret` | `resolved_value_inspect(SecretVal(secret_value("x")))` → `"***REDACTED***"` |
| `resolved_value_to_env_normal` | `resolved_value_to_env(NormalValue(StringVal("x")))` → `"x"` |
| `resolved_value_to_env_secret` | `resolved_value_to_env(SecretVal(secret_value("key")))` → `"key"` |

**Nota (seguridad):** SAD solo puede garantizar “no leak” para datos que **él mismo** produce (Problem Details, logs de sistema, mensajes de error). Si un runner imprime secretos en `t="log"` o en su `result`, SAD no intenta redactarlo (sería complejo y daría falsa seguridad).
| `stream_context_initial_phase` | `new_stream_context(...)` → `phase: BeforeFirstChunk` |
| `stream_context_enter_message` | `enter_message(ctx, "msg-1")` → `phase: InMessage("msg-1")` |
| `stream_context_end_message` | `end_message(ctx_in_message)` → `phase: BeforeFirstChunk` |
| `stream_context_is_before_first_chunk` | `is_before_first_chunk(new_ctx)` → `True` |
| `stream_context_current_message_id` | `current_message_id(InMessage("x"))` → `Some("x")` |

#### gleam_qcheck

| Propiedad | Descripción |
|-----------|-------------|
| `prop_error_kind_roundtrip` | Para cualquier `ErrorKind`, roundtrip es identity |
| `prop_agent_state_predicates_partition` | Exactamente un predicado es true por estado |
| `prop_value_to_string_non_empty` | Para valores no vacíos, serialización no es empty string |
| `prop_system_log_kind_to_string_non_empty` | Para cualquier `SystemLogKind`, serialización no es empty |
| `prop_system_log_always_has_kind_prefix` | Output de `system_log` siempre empieza con `"kind="` |

---

### 3.2. `sad/workspace.gleam`

**Frameworks:** gleeunit + gleam_qcheck

#### gleeunit

| Test | Descripción |
|------|-------------|
| `validate_simple_relative_path` | `"outputs/report.txt"` → `Ok(WorkspacePath)` |
| `validate_rejects_absolute_path` | `"/etc/passwd"` → `Error(AbsolutePathNotAllowed)` |
| `validate_rejects_parent_segments` | `"../secret.txt"`, `"foo/../../bar"` → `Error(PathTraversalDetected)` |
| `validate_allows_double_dot_in_filename` | `"abc..def"` → `Ok(WorkspacePath)` |
| `validate_rejects_empty` | `""` → `Error(EmptyPath)` |
| `validate_rejects_null_char` | `"file\0.txt"` → `Error(InvalidCharacter)` |
| `validate_normalizes_dots` | `"./a/./b"` normalizado sin `./` |
| `validate_normalizes_double_slash` | `"a//b"` → `"a/b"` |
| `read_file_rejects_symlink_escape` | `workspace/a.txt` symlink → `/etc/passwd` → `Error(PathOutsideWorkspace)` (symlink-safe FS access) |
| `to_string_roundtrip` | `to_string(validate(s))` preserva path válido |
| `to_os_path_absolute` | Path ya absoluto → devuelve tal cual |
| `to_os_path_relative` | Path relativo → une con base_dir |
| `join_valid` | `join(root, "output/result.json")` → `Ok` |
| `join_traversal` | `join(root, "../etc")` → `Error` |
| `dir_name_format` | `dir_name(id)` → `"workspace-<id>"` |
| `for_instance_format` | `for_instance(base, id)` → `"<base>/workspace-<id>"` |
| `error_to_string_all_variants` | Todas las variantes de `PathError` tienen mensaje legible |
| `cleanup_removes_directory` | `cleanup()` elimina directorio recursivamente |

#### gleam_qcheck

| Propiedad | Descripción |
|-----------|-------------|
| `prop_valid_path_no_parent_segment` | Path aceptado nunca contiene `..` |
| `prop_valid_path_no_null_char` | Path aceptado nunca contiene `\0` |
| `prop_validate_idempotent` | `validate(to_string(p))` equivalente al original |
| `prop_to_os_path_starts_with_base` | Output de `to_os_path` siempre empieza con base_dir |

---

### 3.3. `sad/runner_contract.gleam`

**Frameworks:** gleeunit + gleam_qcheck

#### gleeunit

| Test | Descripción |
|------|-------------|
| `validate_response_success_ok` | `StatusSuccess` + `data` + artifacts válidos → `Ok` |
| `validate_response_error_with_error` | `StatusError` + `error=Some(_)` → `Ok` |
| `validate_response_error_without_error` | `StatusError` + `error=None` → `Error` |
| `validate_response_invalid_artifact_path` | Artifact con path inválido → `Error` |
| `sad_input_to_json_structure` | JSON contiene `meta`, `params`, `input`, `context`, `helpers`, `runner_def` |
| `provision_response_success` | `--provision` → `{"status":"success","log_files":[]}` |
| `provision_response_with_log_files` | Provision con log_files declarados |
| `provision_response_error` | Provision fallido → `{"status":"error",...}` |

#### gleam_qcheck

| Propiedad | Descripción |
|-----------|-------------|
| `prop_runner_response_roundtrip` | `decode(encode(rr)) == rr` |
| `prop_valid_responses_pass_validation` | Respuestas bien formadas siempre pasan `validate_response` |

---

### 3.3.1 JSONL runner events (parser) (`test/unit/jsonl_events_test.gleam` - agregar)

**Framework:** gleeunit

| Test | Descripción |
|------|-------------|
| `jsonl_sequence_logs_chunks_result_ok` | Secuencia válida: 0..N logs + 0..N chunks + 1 result final |
| `jsonl_invalid_json_line` | Línea con `\\n` pero JSON inválido → error de contrato estable |
| `jsonl_two_results_rejected` | Dos `t=\"result\"` → error |
| `jsonl_chunk_without_streaming_rejected` | `t=\"chunk\"` cuando `streaming=false` → error |

---

### 3.4. `sad/params.gleam`

**Frameworks:** gleeunit + gleam_qcheck

#### gleeunit

| Test | Descripción |
|------|-------------|
| `resolve_fixed_param` | Devuelve valor embebido |
| `resolve_config_param_ok` | Clave presente en config → valor |
| `resolve_config_param_missing` | Clave ausente → `MissingConfig` |
| `resolve_secret_param_ok` | Variable de entorno presente → valor |
| `resolve_secret_param_missing` | Variable ausente → `MissingSecret` |
| `resolve_init_param_ok` | Presente en init_params → valor |
| `resolve_init_param_with_default` | Ausente pero con default → default |
| `resolve_init_param_missing` | Ausente sin default → `MissingInitParam` |
| `resolve_multiple_params` | Composición de varios sources → `ResolvedParams` completo |

#### gleam_qcheck

| Propiedad | Descripción |
|-----------|-------------|
| `prop_fixed_always_same` | `FixedParam` ignora fuentes externas |
| `prop_missing_sources_produce_error` | Sin default + fuente vacía → siempre error |
| `prop_resolved_keys_match_input` | Keys de output = keys de input (para los exitosos) |

---

### 3.5. `sad/decoders.gleam`

**Frameworks:** gleeunit + gleam_qcheck

#### gleeunit

| Test | Descripción |
|------|-------------|
| `decode_valid_profile` | Perfil completo parsea correctamente |
| `decode_rejects_secret_with_default` | `source=secret` + `default` → error |
| `decode_rejects_unknown_lifecycle` | `lifecycle="weird"` → error |
| `decode_config_toml` | Config con timeouts parsea correctamente |
| `decode_payload_chat` | `SchemaChat` → `PayloadChat` |
| `decode_payload_files` | `SchemaFiles` → `PayloadFiles` |
| `decode_payload_chat_extended` | Con `extra_fields` → valores tipados |
| `http_method_decoder_get` | `"GET"` → `Ok(http.Get)` |
| `http_method_decoder_post` | `"POST"` → `Ok(http.Post)` |
| `http_method_decoder_put` | `"PUT"` → `Ok(http.Put)` |
| `http_method_decoder_delete` | `"DELETE"` → `Ok(http.Delete)` |
| `http_method_decoder_lowercase` | `"get"` → `Ok(http.Get)` (case insensitive) |
| `http_method_decoder_invalid` | `"GETT"` → `Error` con mensaje descriptivo |
| `http_method_decoder_empty` | `""` → `Error` |
| `health_check_uses_method_type` | `HealthCheck.method` es `http.Method`, no `String` |
| `http_capability_uses_method_type` | `HttpCapability.method` es `http.Method`, no `String` |
| `decode_http_body_json` | `body.type=json` + `$from` parsea correctamente |
| `decode_http_body_multipart` | `body.type=multipart` + `files[].source_pointer` parsea correctamente |
| `decode_payload_unknown_schema` | `schema="unknown"` → `Error(UnknownSchema)` |
| `decode_payload_missing_schema` | Sin campo `schema` → `Error` |
| `decode_lifecycle_unknown` | `lifecycle="weird"` → `Error(UnknownLifecycle)` |
| `decode_param_source_unknown` | `source="magic"` → `Error(UnknownParamSource)` |
| `decode_capability_limits` | `limits.call_timeout_ms` parsea correctamente |
| `decode_capability_limits_optional` | Sin `limits` usa defaults |
| `decode_network_mode_host` | `network_mode="host"` → Error (no soportado) |
| `decode_network_mode_none` | `network_mode="none"` → Error (no soportado) |
| `decode_log_files_array` | `log_files: ["app.log"]` parsea correctamente |

#### gleam_qcheck

| Propiedad | Descripción |
|-----------|-------------|
| `prop_extra_fields_ignored` | Campos JSON extra no rompen parsing |
| `prop_parameter_keys_preserved` | Keys de `parameters` en JSON = keys en tipo |
| `prop_http_method_roundtrip` | `decode(method_to_string(m)) == Ok(m)` para métodos válidos |

---

### 3.6. `sad/core/agent_internal.gleam`

**Framework:** gleeunit

| Test | Descripción |
|------|-------------|
| `internal_api_compiles` | `provisioning_done/ingest_log/interaction_done/server_died` disponibles y tipados |
| `stream_event_variants` | `StreamStarted`, `ContentChunk`, `StreamFinished`, `StreamError` tipados |
| `bridge_workers_use_spawn_unlinked` | Un crash en worker no tumba al actor (spawn_unlinked + monitor) |
| `stream_sink_timeout_switches_to_discard_no_mailbox_growth` | Timeout/disconnect de `StreamSink.push_batch` degrada a discard sin crecimiento descontrolado del mailbox del worker |

---

### 3.7. `sad/core/agent.gleam`

**Framework:** gleeunit con `Bridge` fake (inyectado)

| Test | Descripción |
|------|-------------|
| `transient_happy_path` | Crear actor → interact → `InteractionResult` correcto |
| `continuous_happy_path` | Provisioning → health OK → `Ready` con resource |
| `health_check_timeout` | Mock devuelve timeout → `Failed` |
| `server_died` | `ServerDied(code)` → `Ready → Failed` |
| `runner_error` | `InteractionDone(Error)` → error al cliente |
| `worker_down` | `WorkerDown` sin `InteractionDone` → limpia estado |
| `no_cancel_endpoint` | No existe cancelación pública; desconexión SSE no cancela; `StopInstance`/`Terminate` pueden abortar la ejecución si se ordena |
| `stop_instance_idempotent` | Múltiples `StopInstance(UserRequested)` no causan crash |
| `stop_instance_user_requested` | `StopInstance(UserRequested)` → pasa a `Stopped` (sin cleanup) |
| `terminate_node_shutting_down` | `Terminate(NodeShuttingDown)` → termina el proceso del actor |
| `stop_instance_idle_timeout` | `StopInstance(IdleTimeout)` → pasa a `Stopped` |
| `stop_expected_uses_actor_stop` | Parada esperada usa `actor.stop()` (normal), no panic |
| `interact_while_busy_rejected` | Segundo `Interact` mientras Busy → Error |
| `attach_logs_receives_events` | Suscriptor recibe `LogEvent` |
| `attach_logs_takeover` | Nueva suscripción de logs reemplaza anterior |
| `logs_ring_buffer_capacity` | Buffer no excede `buffer_size` configurado |
| `logs_ring_buffer_drops_oldest` | Al exceder capacidad, descarta más antiguos |
| `logs_attach_sends_history` | Al conectar, envía contenido actual del buffer |
| `logs_attach_preserves_metadata` | Replay preserva `ts_ms` y `trace_id` del `LogEvent` (no reescribe campos) |
| `interact_uses_capability_timeout_core` | Timeout efectivo se resuelve en el actor con `resolve_call_timeout_for` (no depende del gateway) |

---

### 3.8. `sad/core/agent.gleam`

**Framework:** gleeunit

| Test | Descripción |
|------|-------------|
| `interact_delegates_to_actor` | Respuesta del actor llega al caller |
| `interact_respects_timeout` | Usa timeout de config |
| `status_uses_status_timeout` | Timeout correcto para status |
| `attach_logs_sends_message` | Actor recibe `AttachLogs(subscriber)` |

---

### 3.9. `sad/core/registry.gleam` y `registry_api.gleam`

**Framework:** gleeunit

| Test | Descripción |
|------|-------------|
| `register_new_instance` | Registro vacío → `Register(status, agent)` → aparece en mapa con summary |
| `register_duplicate_fails` | Misma clave dos veces → error |
| `register_is_atomic_for_uniqueness` | No depende de `lookup` previo: `Register` es la fuente de unicidad (evita TOCTOU) |
| `unregister_removes` | `Unregister` → `Lookup` devuelve `None` |
| `unregister_by_instance_id_removes` | `UnregisterByInstanceId` → `LookupByInstanceId` devuelve `None` |
| `list_by_profile_filters` | Solo devuelve instancias del perfil pedido |
| `list_all_returns_summaries` | `ListAll` devuelve `InstanceSummary` con status cacheado |
| `lookup_by_ids_uses_key` | Construye `InstanceKey` correctamente |
| `update_status_updates_summary` | `UpdateStatus` refresca status y `status_updated_at` |
| `agent_down_removes_entry` | Proceso monitoreado muere → entrada eliminada automáticamente |
| `monitor_established_on_register` | Al registrar se establece monitor del proceso |

---

### 3.10. `sad/core/supervisor.gleam` y `agent_manager.gleam` (AgentManagerActor)

**Framework:** gleeunit

| Test | Descripción |
|------|-------------|
| `root_supervisor_rest_for_one_order` | `RestForOne` reinicia `ProfilesActor`/`AgentManagerActor`/`AgentFactorySupervisor` y `HttpServer` si cae Registry/ArtifactRegistry |
| `root_supervisor_restart_tolerance` | Excede intensidad → root falla; límites aplican |
| `root_supervisor_start_fail_fast` | `StartResult` erróneo hace crash temprano con log |
| `agent_factory_restart_strategy_temporary` | Factory supervisor arranca children con `restart=Temporary` (sin auto-restart) |
| `deps_discovered_by_name_not_passed_by_hand` | Root usa `Name` + `get_by_name` (sin “returning chain” ni subjects inventados) |
| `agent_crash_does_not_crash_manager` | Caída de un agente no tumba al manager (no están linkados) |
| `agent_crash_does_not_restart_automatically` | Si un agente cae, SAD no lo reinicia; SAM decide recreación |
| `start_agent_same_key_one_wins` | Dos `StartAgent` concurrentes con misma `instance_id` → exactamente uno Ok; el otro `RegistrationFailed(AlreadyExists)` sin leaks |
| `start_agent_registration_failed_rolls_back` | Si `registry.register` falla, el agente arrancado se termina (`Terminate(SupervisorCleanup)`) |
| `list_agents_returns_summaries` | `ListAgents` devuelve summaries cacheados (sin N+1) |
| `reload_does_not_affect_running_agents` | Agentes existentes mantienen su perfil original (snapshot en StartArgs) |

---

### 3.11. `sad/core/profiles.gleam` (ProfilesActor)

**Framework:** gleeunit

| Test | Descripción |
|------|-------------|
| `profiles_actor_receives_initial_profiles` | Al arrancar, recibe perfiles del borde |
| `set_profiles_updates_state` | `SetProfiles` actualiza dict de perfiles |
| `set_profiles_returns_count` | Responde con número de perfiles establecidos |
| `set_profiles_is_pure` | No hace IO, solo actualiza estado |
| `get_profile_returns_some` | Perfil existente → `Some(Profile)` |
| `get_profile_returns_none` | Perfil inexistente → `None` |
| `list_profiles_returns_all_ids` | Devuelve lista de todos los ProfileIds |

---
### 3.12. `sad/adapters/agui.gleam`

**Framework:** gleeunit + gleam_qcheck

#### gleeunit

| Test | Descripción |
|------|-------------|
| `convert_stream_started` | `StreamStarted` → `AgUiEvent(RunStarted)` |
| `convert_first_content_chunk` | Primer chunk → `[TextMessageStart, TextMessageContent]` |
| `convert_subsequent_chunk` | Chunks siguientes → solo `TextMessageContent` |
| `convert_stream_finished` | Con mensaje activo → `[TextMessageEnd, RunFinished]` |
| `convert_stream_error` | → `AgUiEvent(RunError)` con `error.kind/message/trace_id` |
| `to_core_event_content` | `TextMessageContent` → `SomeEvent(ContentChunk)` |
| `to_core_event_start_end` | `TextMessageStart/End` → `NoEvent` |
| `to_sse_line_format` | Usa `sse.line`, formato correcto |
| `agui_sse_success_payload_exact` | SSE de éxito coincide con `protocolos.md` §3.4.1 |
| `agui_sse_error_payload_exact` | `RUN_ERROR` coincide con `protocolos.md` §3.4.2 |

#### gleam_qcheck

| Propiedad | Descripción |
|-----------|-------------|
| `prop_trace_id_preserved` | Conversión preserva `trace_id` |

---

### 3.12.1. `sad/adapters/a2ui.gleam`

**Framework:** gleeunit

| Test | Descripción |
|------|-------------|
| `a2ui_shape_exact` | Forma exacta A2UI (según `protocolos.md` §0.3) |
| `post_agents_interact_streaming_a2ui_message_shape` | (Gateway) En modo A2UI nativo, cada `data:` parsea a JSON y contiene exactamente una key top-level |

---

### 3.12.2. `sad/adapters/a2a.gleam`

**Framework:** gleeunit + gleam_qcheck

#### gleeunit

| Test | Descripción |
|------|-------------|
| `message_to_payload_text_only` | Solo `TextPart` → `PayloadChat` |
| `message_to_payload_files_only` | Solo `FilePart` → `PayloadFiles` |
| `message_to_payload_mixed` | `TextPart` + `FilePart` → `PayloadMixed` |
| `message_to_payload_empty` | Sin parts → `PayloadChat([])` |
| `interaction_result_to_task` | Genera `A2ATask` con `Completed` |
| `agent_card_uses_meta_id` | `name` = `profile_id_to_string(meta.id)` |
| `sad_error_to_a2a_error` | `BadRequest→400`, `AgentError→422`, `InfraError→500` + `type` A2A |
| `to_sse_line_format` | Usa `sse.line` |
| `decode_a2a_message_missing_parts` | A2A Message sin `parts` → `Error` |
| `decode_a2a_message_invalid_role` | `role="alien"` → `Error(InvalidRole)` |
| `decode_a2a_task_invalid_id` | `id` no UUID → `Error(InvalidTaskId)` |
| `decode_a2a_part_unknown_ignored` | Part desconocido se ignora (robustez de parsing) |
| `decode_a2a_file_bytes_rejected` | `file.bytes` → `Error(BadRequest)` (v0 no soporta bytes) |
| `decode_a2a_file_media_type_optional` | Sin `file.mediaType` → default `application/octet-stream` |
| `decode_a2a_text_parts_concatenated` | Múltiples `TextPart` → un único `ChatMessage` concatenado |
| `a2a_message_send_shape_exact` | `message:send` devuelve `result.id/contextId/status/message/artifacts` según `protocolos.md` §2.12 |
| `a2a_stream_success_sequence_exact` | SSE working → 0..N message → completed según `protocolos.md` §2.7.2 |
| `a2a_stream_error_payload_exact` | SSE failed con `error.kind/message/trace_id` según `protocolos.md` §2.7.3 |
| `a2ui_data_part_requires_extension` | `DataPart` con `mimeType="application/json+a2ui"` solo se acepta/procesa si está activa la extensión A2UI (ver `protocolos.md` §2.13) |
| `a2ui_stream_message_shape_exact` | Con extensión activa, SSE `message.parts` contiene `DataPart` A2UI (y no `TextPart`) según `protocolos.md` §2.13 |
| `validate_agent_card_missing_name` | Agent Card sin `name` → `Error` |
| `validate_agent_card_missing_url` | Agent Card sin `url` → `Error` |

#### gleam_qcheck

| Propiedad | Descripción |
|-----------|-------------|
| `prop_task_id_equals_trace_id` | `task.id == trace_id` siempre |
| `prop_valid_a2a_message_has_role` | Mensaje válido siempre tiene `role` in `[user, assistant]` |

---

### 3.13. `sad/sse.gleam`

**Framework:** gleeunit

| Test | Descripción |
|------|-------------|
| `line_format` | `line(json)` → `"data: <json>\n\n"` |
| `named_event_format` | `named_event(type, json)` → `"event: <type>\ndata: <json>\n\n"` |
| `comment_format` | `comment(text)` → `": <text>\n\n"` |

---

### 3.14. `sad/ffi.gleam`

**Framework:** gleeunit

| Test | Descripción |
|------|-------------|
| `now_ms_returns_positive` | `now_ms() > 0` |
| `now_ms_is_monotonic` | Segunda llamada >= primera |
| `port_open_valid_command` | Comando válido → `PortOk` |
| `port_open_invalid_command` | Comando inexistente → `PortError` |
| `port_send_receives_data` | Port recibe datos enviados |

**Nota:** Tests de integración completa de ports están en `bridge/runner_test.gleam`.

---

## 4. Bordes - módulos con IO

### 4.1. `sad/config.gleam`

**Framework:** gleeunit (FS temporal)

| Test | Descripción |
|------|-------------|
| `load_config_toml` | TOML con timeouts → `SadConfig` correcto |
| `load_profile_json` | Perfil de prueba decodifica correctamente |
| `load_profiles_with_invalid` | Directorio con perfil corrupto → error localizado |
| `timeout_functions` | `resolve_call_timeout`, etc. usan config |

---

### 4.2. `sad/bridge/serialization.gleam`

**Frameworks:** gleeunit + gleam_qcheck

#### gleeunit

| Test | Descripción |
|------|-------------|
| `sad_input_to_json` | Estructura JSON correcta |
| `input_payload_chat_json` | `PayloadChat` → JSON con `messages` |
| `input_payload_files_json` | `PayloadFiles` → JSON con `files` |
| `input_payload_mixed_json` | `PayloadMixed` → JSON con `messages` + `files` |
| `log_event_to_json` | Estructura correcta con `ts_ms`, `line`, `trace_id` |

#### gleam_qcheck

| Propiedad | Descripción |
|-----------|-------------|
| `prop_payload_roundtrip` | Si hay decoder inverso, `decode(encode(p)) == p` |

---

### 4.3. `sad/bridge/interpolator.gleam`

**Frameworks:** gleeunit + gleam_qcheck

#### gleeunit

| Test | Descripción |
|------|-------------|
| `interpolate_params` | `"{{params.name}}"` → valor resuelto |
| `interpolate_helpers` | `"{{helpers.last_user_content}}"` → contenido |
| `interpolate_context` | `"{{context.trace_id}}"` → id serializado |
| `interpolate_runner` | `"{{runner.host}}"`, `"{{runner.port}}"` |
| `interpolate_missing` | → `Error` |
| `interpolate_hyphenated_key` | `"{{params.api-key}}"` resuelve key con guión |
| `interpolate_json` | Interpola dentro de estructura JSON |

#### gleam_qcheck

| Propiedad | Descripción |
|-----------|-------------|
| `prop_no_placeholders_unchanged` | String sin `{{` → idéntica |
| `prop_no_new_braces` | Interpolación no introduce `{{` nuevos |

---

### 4.4. `sad/bridge/runner.gleam`

**Framework:** gleeunit con zoo

| Test | Zoo Agent | Descripción |
|------|-----------|-------------|
| `transient_echo_happy` | `echo_cli` | Flujo completo → `InteractionResult` eco |
| `transient_greedy_logs` | `greedy_logger` | `t="log"` → `LogEvent`, `t="result"` final |
| `transient_bad_exit` | custom | exit != 0 → `InfraError` |
| `transient_invalid_json` | custom | bytes fuera de contrato (no JSONL) → error fail-fast |
| `transient_timeout_stops_runner` | `timeout_sleep` | Timeout → infra_error y proceso detenido |
| `artifact_valid_path` | `artifact_gen` | `ArtifactRef.path` pasa validación |
| `continuous_start_health_ok` | `echo_server` | Health check OK → `Ready` |
| `continuous_health_timeout` | `slow_poke` | Timeout → `Failed` |
| `continuous_server_died` | `crasher` | `PortExit` → `ServerDied` |
| `streaming_chunks` | `streaming_echo` | Emite `ContentChunk` incrementales |
| `stdout_buffer_optimized` | `echo_cli` | Respuestas grandes no son O(n²) |
| `provision_success` | `echo_cli` | `--provision` retorna success |
| `provision_creates_log_files` | `greedy_logger` | Log files declarados son creados |
| `provision_failure` | custom | Provision fallido → error antes de Ready |

---

### 4.5. `sad/bridge/client.gleam`

**Framework:** gleeunit con zoo

| Test | Zoo Agent | Descripción |
|------|-----------|-------------|
| `get_runner_network_transient` | - | Sin resource → `(None, None)` |
| `get_runner_network_continuous` | - | Con resource → host + port |
| `health_check_success` | `echo_server` | → `Ok` |
| `health_check_timeout` | `slow_poke` | → `InteractionError` |
| `http_interaction_sync` | `echo_server` | `streaming=false` → `InteractionDone` |
| `http_interaction_streaming` | `echo_server` | `streaming=true` → SSE con eventos `t="chunk"` y `t="result"` → `InteractionDone` |
| `http_streaming_post_with_body_ok` | `echo_server` | Streaming HTTP con `method=POST` + body JSON → SSE OK → `InteractionDone` |
| `http_streaming_method_not_restricted_but_response_must_be_sse_framed` | custom | `streaming=true` pero upstream responde no-SSE (o sin framing) → `InfraError` |
| `http_streaming_close_without_result_errors` | custom | SSE cierra sin `t="result"` → `InfraError` |

---

### 4.6. `sad/gateway/api.gleam`

**Framework:** gleeunit

| Test | Descripción |
|------|-------------|
| `post_sys_agents_creates_instance` | Responde 201 + `state=provisioning` (no espera provisioning); registra actor y arranca worker asíncrono |
| `get_sys_agents_lists_cached` | `/sys/agents` devuelve `InstanceSummary` con status cacheado (sin N+1) |
| `get_sys_agents_lists_live_true` | `/sys/agents?live=true` refresca status live (opt-in) |
| `get_sys_agents_status` | Devuelve `AgentStatusView` |
| `get_sys_agents_status_does_not_expose_params` | `AgentStatusView`/`AgentInfoView` no incluye `ResolvedParams` ni secretos (solo vista pública) |
| `get_sys_agents_logs_stream` | SSE de `LogEvent` |
| `get_agent_capabilities` | Devuelve capabilities del perfil (endpoint nativo) |
| `post_agents_interact_transient` | `echo_cli` → respuesta nativa (sync o SSE según capability) |
| `post_agents_interact_continuous` | `echo_server` → respuesta nativa (sync o SSE según capability) |
| `post_agents_interact_agent_down` | Agente caído → `safe_call.call_within` devuelve error HTTP sin tumbar handler |
| `post_agents_interact_timeout` | Timeout → `safe_call.call_within` devuelve 504/timeout, proceso sigue vivo |
| `post_agents_interact_timeout_then_next_request_ok` | Continuous: tras un timeout, el servidor sigue atendiendo requests (el handler no queda muerto ni el router inconsistente) |
| `post_agents_interact_streaming_a2ui_header_switches_wire` | Con `X-SAD-UI-Protocol: a2ui/v0.8`, el SSE entrega JSONL A2UI (sin envelope AG-UI) |
| `post_agents_interact_streaming_a2ui_disconnect_is_terminal` | En modo A2UI “puro”, el fin del stream se observa por cierre de conexión (sin evento terminal adicional) |
| `problem_details_mapping_native` | `ErrorKind` → RFC7807 nativo vía `sad/gateway/problem.gleam` + status (400/422/500) |
| `problem_details_mapping_a2a` | `ErrorKind` → RFC7807 A2A vía `sad/gateway/problem.gleam` (type A2A) + status (400/422/500) |
| `problem_details_does_not_leak_secrets` | Errores por interpolación/headers no incluyen valores sensibles (API keys, Authorization, secretos) en `detail` |
| `interact_uses_capability_timeout` | Timeout de capability sobrescribe default |
| `interact_uses_config_call_timeout_ms` | Sin timeout en capability → usa `config.call_timeout_ms` |
| `post_reload_profiles_success` | `POST /sys/reload-profiles` → 200 con count |
| `post_reload_profiles_auth_required` | Sin API key → 401 |
| `post_reload_profiles_io_error` | Directorio inexistente → 500 |
| `post_reload_profiles_invalid_json` | Perfil corrupto → 500 con mensaje |
| `post_reload_profiles_keeps_old_on_error` | Error de IO → perfiles anteriores se mantienen |
| `post_reload_profiles_does_not_affect_existing_instances` | Reload solo afecta a instancias nuevas (snapshot por instancia) |
| `get_sys_profiles_lists_all` | `GET /sys/profiles` → lista con metadata |
| `get_agent_card_auth_required` | `GET /instances/:instance_id/.well-known/agent-card.json` sin API key → 401 |
| `post_a2a_message_send_ok` | `POST /instances/:instance_id/a2a/message:send` → 200 con `Message`/`Task` según `protocolos.md` |
| `post_a2a_send_auth_required` | `POST /instances/:instance_id/a2a/message:send` sin API key → 401 |
| `post_a2a_message_stream_ok` | `POST /instances/:instance_id/a2a/message:stream` → SSE con `task_status`/`message` |
| `post_a2a_stream_auth_required` | `POST /instances/:instance_id/a2a/message:stream` sin API key → 401 |
| `post_a2a_message_stream_a2ui_extension` | Con `X-A2A-Extensions` A2UI activo, `message:stream` emite `message.parts` como `DataPart` (`mimeType="application/json+a2ui"`) según `protocolos.md` §2.13 |

---

### 4.6.1. `sad/otp/safe_call.gleam` (`test/unit/safe_call_test.gleam` - agregar)

**Framework:** gleeunit (tests de procesos; sin IO externo)

| Test | Descripción |
|------|-------------|
| `call_within_ok_on_reply` | Respuesta llega antes de timeout → `Ok(reply)` |
| `call_within_disconnected_when_callee_down` | Callee muere antes de responder → `Error(Disconnected)` |
| `call_within_timed_out_when_no_reply` | No reply dentro del timeout → `Error(TimedOut)` y el proceso caller sigue vivo |

### 4.6.2. `sad/streams/sink.gleam` (StreamSink) (`test/unit/streams_sink_test.gleam` - agregar)

**Framework:** gleeunit

| Test | Descripción |
|------|-------------|
| `stream_sink_push_batch_is_ack_backpressure` | `push_batch` espera ack del loop SSE; `process.send` sin ack está prohibido en interacción |
| `stream_sink_finish_closes_stream` | `finish` emite terminal (AG-UI/A2A) y cierra conexión SSE |

### 4.7. `sad/gateway/proxy.gleam`

**Framework:** gleeunit

| Test | Zoo Agent | Descripción |
|------|-----------|-------------|
| `get_artifact_serves_file` | `artifact_gen` | Contenido + Content-Type correcto |
| `get_artifact_auth_required` | - | Sin API key → 401 |
| `get_artifact_outside_workspace` | - | → 404 |
| `artifact_after_agent_stopped` | `artifact_gen` | Artefacto sigue disponible (stop no limpia workspace) |
| `artifact_after_agent_deleted` | `artifact_gen` | → 404 (delete limpia workspace/registry) |

---

### 4.8. `sad/gateway/ui_proxy.gleam`

**Framework:** gleeunit

**Nota de seguridad:** estos tests son obligatorios para garantizar que `/ui` no es un open proxy.

| Test | Zoo Agent | Descripción |
|------|-----------|-------------|
| `proxy_ui_agui` | custom | Ruta `/agents/:instance_id/ui/agui` proxifica |
| `ui_proxy_auth_required` | - | Sin API key → 401 |
| `proxy_ui_server_down` | `crasher` | → error HTTP |
| `ui_proxy_upstream_not_client_controlled` | - | No permite host/port/scheme desde el cliente (solo por estado del agente) |
| `ui_proxy_does_not_forward_authorization` | - | No forwardea `Authorization`/`Cookie` al runner UI |
| `ui_proxy_does_not_add_cors_headers` | - | No agrega headers `Access-Control-*` (CORS se gestiona fuera de SAD) |
| `ui_proxy_problem_details_does_not_leak_secrets` | - | Si el upstream cae o hay error de proxy, el RFC7807 no incluye valores sensibles (headers/config/Authorization) |
| `ui_proxy_rejects_path_traversal` | - | Rechaza `..` (incluyendo `%2e%2e`) en el path bajo `/ui/*` |
| `ui_proxy_rejects_websocket_upgrade` | - | Request con `Upgrade: websocket` → error (v0 HTTP-only) |

---

### 4.9. `sad.gleam` (Entrypoint)

**Framework:** gleeunit

| Test | Descripción |
|------|-------------|
| `start_initializes_supervisors` | `RootSupervisor`, `Registry`, `ProfilesActor`, `AgentManagerActor`, `AgentFactorySupervisor`, `HttpServer` vivos |
| `start_fails_without_config` | Sin `config.toml` → error descriptivo |
| `start_fails_without_api_key` | Sin `SAD_API_KEY` → error |
| `health_endpoint_responds` | `GET /health` → 200 |
| `ready_endpoint_when_healthy` | `GET /health/ready` → 200 cuando supervisores OK y profiles_count > 0 |
| `ready_endpoint_when_unhealthy` | `GET /health/ready` → 503 si supervisor caído o no hay perfiles cargados |
| `routes_respond` | `/sys` y `/agents` responden (smoke test) |
| `graceful_shutdown_stops_agents` | `SIGTERM` → agentes reciben `Terminate(NodeShuttingDown)` |
| `shutdown_respects_timeout` | Agentes lentos se terminan después de timeout |
| `serve_background_creates_pid_file` | `sad serve -b` → crea `~/.sad/sad.pid` |
| `serve_background_forks_process` | `sad serve -b` → proceso padre termina, hijo corre |
| `serve_kill_stops_running` | `sad serve -k` con servidor corriendo → termina |
| `serve_kill_no_server` | `sad serve -k` sin servidor → mensaje "not running" |
| `serve_status_running` | `sad serve --status` → muestra PID y puerto |
| `serve_status_not_running` | `sad serve --status` sin servidor → "not running" |

---

## 5. Resumen por módulo

### Meta: doc-lint (arquitectura)

Estos checks existen para que el plan TDD sea ejecutable: el doc no puede sugerir APIs inexistentes o patrones prohibidos.

| Check | Descripción |
|-------|-------------|
| `docs_do_not_reference_nonexistent_apis` | CI falla si aparecen patrones como `process.try_call`, `process.select_after`, `process.select(selector)` |
| `docs_actor_stop_usage_is_valid` | CI falla si aparece `actor.stop(process.Normal)`; usar `actor.stop()`/`actor.stop_abnormal(...)` |
| `docs_defaults_match_config` | CI falla si los defaults en `docs/plan/limits.toml` o `docs/arquitectura/config.md` no coinciden con `SadConfig.default_*` |
| `docs_limits_md_matches_toml` | CI falla si `docs/plan/limits.md` no refleja `docs/plan/limits.toml` |

### Core (unit tests)

| Módulo | gleeunit | gleam_qcheck | Tests |
|--------|----------|--------------|-------|
| `types.gleam` | estado, predicados, errores, SystemLogKind | roundtrips, particiones | 14 + 5 props |
| `workspace.gleam` | paths, validación, to_os_path | seguridad de paths | 15 + 4 props |
| `runner_contract.gleam` | validación, JSON shape | roundtrips | 5 + 2 props |
| `params.gleam` | resolución, errores | propiedades de sources | 9 + 3 props |
| `decoders.gleam` | perfiles, config, payloads, http_method, extra_fields, network_mode | robustez | 33 + 3 props |
| `ffi.gleam` | now_ms, ports | - | 5 |
| `core/agent_internal.gleam` | API interna tipada | - | 2 |
| `core/agent.gleam` | FSM completa con mock | - | 10 |
| `core/agent.gleam` | delegación, timeouts | - | 4 |
| `core/registry*.gleam` | CRUD de instancias | - | 5 |
| `core/supervisor*.gleam` | topología, restarts, profiles | - | 10 |
| `adapters/agui.gleam` | conversión, SSE | trace_id | 8 + 1 prop |
| `adapters/a2a.gleam` | PayloadMixed, Agent Card, validación estricta | task_id, role | 20 + 2 props |
| `sse.gleam` | formatos SSE | - | 4 |
| `cli.gleam` | parsing de comandos y flags | - | 9 |
| `artifact_registry.gleam` | registro y lookup de artefactos | - | 7 |
| `response_mapping.gleam` | JSON pointers para respuestas | - | 7 |
| `port_pool.gleam` | asignación de puertos | - | 14 |

**Total Core:** ~192 tests + ~21 properties

### Bordes (integración)

| Módulo | gleeunit | Zoo Agents | Tests |
|--------|----------|------------|-------|
| `config.gleam` | FS temporal | - | 4 |
| `bridge/serialization.gleam` | JSON | - | 5 + 1 prop |
| `bridge/interpolator.gleam` | templates, JSON interpolation | - | 13 + 2 props |
| `bridge/runner.gleam` | ports | echo_cli, greedy_logger, artifact_gen, streaming_echo, crasher | 10 |
| `bridge/client.gleam` | HTTP | echo_server, slow_poke | 6 |
| `gateway/api.gleam` | endpoints | echo_cli, echo_server | 13 |
| `gateway/proxy.gleam` | artefactos | artifact_gen | 4 |
| `gateway/ui_proxy.gleam` | ui proxy (HTTP-only) | crasher | 6 |
| `sad.gleam` | smoke, daemon flags | - | 8 |
| `system_log.gleam` | emisión de logs estructurados | echo_cli | 8 |
| `shutdown.gleam` | graceful shutdown | echo_server | 8 |

**Total Bordes:** ~84 tests + ~3 properties

### Total general: ~276 tests + ~24 properties (~300 con margin)

---

## 6. Fixtures y estructura de tests

Referencia completa (v0): `arquitectura/examples/snippets/tests_fixtures_tree.txt`.

Extracto (v0):

```text
test/
├── fixtures/
│   ├── profiles/
│   │   ├── echo_cli.json
│   │   └── ...
│   ├── runners/
│   │   ├── echo_cli.py
│   │   └── ...
│   └── config/
│       └── test_config.toml
├── unit/
│   ├── types_test.gleam
│   └── ...
├── integration/
│   ├── runner_test.gleam
│   └── ...
└── properties/
    └── ...
```

**Totales:**
- Unit tests: ~175
- Integration tests: ~100
- Property tests: ~24
- **Total: ~300 tests**

---

## 7. Tests adicionales (gaps identificados)

### 7.1 CLI Parsing (`test/unit/cli_test.gleam`)

**Framework:** gleeunit

| Test | Descripción |
|------|-------------|
| `parse_dry_run_valid` | `sad dry-run --profile aider --input file.json --capability chat` parsea correctamente |
| `parse_dry_run_missing_profile` | Sin `--profile` → error descriptivo |
| `parse_dry_run_missing_capability` | Sin `--capability` → error descriptivo |
| `parse_version` | `sad --version` → `Command::Version` |
| `parse_help` | `sad --help` → `Command::Help` |
| `parse_help_subcommand` | `sad serve --help` → help de serve |
| `parse_unknown_command` | `sad unknown` → error con sugerencias |
| `parse_conflicting_flags` | `sad serve -b -k` → error (no puede background y kill) |
| `parse_duplicate_flags` | `sad serve -p 8080 -p 9090` → usa último o error |

---

### 7.2 Artifact Registry (`test/unit/artifact_registry_test.gleam`)

**Framework:** gleeunit

| Test | Descripción |
|------|-------------|
| `register_artifact_returns_uuid` | Registrar artefacto devuelve UUID único |
| `register_artifact_stores_workspace_path` | UUID mapea a WorkspacePath correcto |
| `lookup_existing_artifact` | UUID válido → `Ok(Some(ArtifactEntry(path, mime, instance_id)))` |
| `lookup_nonexistent_artifact` | UUID inventado → `Ok(None)` |
| `purge_by_instance_removes_all` | Purge elimina todos los artefactos de una instancia |
| `purge_by_instance_preserves_others` | Purge no afecta artefactos de otras instancias |
| `concurrent_register_unique_uuids` | Registros concurrentes generan UUIDs distintos |

---

### 7.3 Interpolación JSON (`test/unit/interpolator_test.gleam` - agregar)

| Test | Descripción |
|------|-------------|
| `interpolate_json_nested_objects` | `{"a": {"b": "{{params.x}}"}}` interpola correctamente |
| `interpolate_json_arrays` | `{"items": ["{{params.a}}", "{{params.b}}"]}` interpola todos |
| `interpolate_json_mixed_types` | JSON con strings, ints, bools: solo strings se interpolan |
| `interpolate_json_preserves_null` | `null` se preserva intacto |
| `interpolate_json_preserves_numbers` | Números no se tocan aunque contengan `{{` en string |
| `interpolate_json_deep_nesting` | 5+ niveles de anidamiento funcionan |
| `interpolation_error_does_not_leak_secrets` | Error de interpolación en headers/URL no incluye valores de secretos (solo nombres/keys) |

---

### 7.4 A2A Decoding (`test/unit/a2a_test.gleam` - agregar)

| Test | Descripción |
|------|-------------|
| `decode_a2a_file_part_valid` | FilePart con uri y mimeType parsea |
| `decode_a2a_file_part_missing_uri` | FilePart sin `file.uri` → `Error` |
| `decode_a2a_file_part_missing_mimetype` | Sin mimeType → usa default `application/octet-stream` |
| `decode_a2a_message_empty_parts` | `parts: []` → `PayloadChat([])` |
| `decode_a2a_context_optional` | Sin `context` → genera trace_id |
| `decode_a2a_metadata_capability` | `metadata.capability` extrae capability name |

---

### 7.5 Response Mapping (`test/unit/response_mapping_test.gleam`)

**Framework:** gleeunit

| Test | Descripción |
|------|-------------|
| `response_mapping_text_pointer_root` | `text_pointer: "/answer"` extrae campo raíz |
| `response_mapping_text_pointer_nested` | `text_pointer: "/data/content"` extrae anidado |
| `response_mapping_text_pointer_missing` | Pointer a campo inexistente → `None` |
| `response_mapping_artifacts_pointer` | `artifacts_pointer: "/files"` extrae lista |
| `response_mapping_invalid_pointer` | Pointer malformado → error descriptivo |
| `response_mapping_both_pointers` | Ambos pointers funcionan juntos |
| `response_mapping_none` | Sin mapping → body completo como content |

---

### 7.7 Extra Fields Validation (`test/unit/decoders_test.gleam` - agregar)

| Test | Descripción |
|------|-------------|
| `decode_extra_field_string_valid` | `type: "string"` acepta strings |
| `decode_extra_field_string_invalid` | `type: "string"` rechaza int |
| `decode_extra_field_enum_valid` | Valor en `enum_values` → Ok |
| `decode_extra_field_enum_invalid` | Valor fuera de `enum_values` → Error |
| `decode_extra_field_default_applied` | Campo ausente + default → usa default |
| `decode_extra_field_required_missing` | Campo ausente sin default → Error |
| `decode_extra_field_number_valid` | `type: "number"` acepta float e int |
| `decode_extra_field_boolean_valid` | `type: "boolean"` acepta true/false |

---

### 7.8 System Log Emission (`test/integration/system_log_test.gleam`)

**Framework:** gleeunit (integración con actor real)

| Test | Descripción |
|------|-------------|
| `agent_emits_started_on_init` | Al crear agente → log con `kind=agent_started` |
| `agent_emits_stopped_on_stop` | Al detener → log con `kind=agent_stopped` |
| `agent_emits_interaction_started` | Al iniciar interact → log con `kind=interaction_started` |
| `agent_emits_interaction_finished` | Al completar → log con `kind=interaction_finished` + `duration_ms` |
| `agent_emits_interaction_failed` | Al fallar → log con `kind=interaction_failed` + `error_kind` |
| `continuous_emits_server_died` | Servidor muere → log con `kind=server_died` + `exit_code` |
| `system_log_includes_profile_label` | Todos los logs incluyen `profile=<id>` |
| `system_log_includes_trace_id` | Logs de interacción incluyen `trace_id` |

---

### 7.9 Graceful Shutdown (`test/integration/shutdown_test.gleam`)

**Framework:** gleeunit

| Test | Descripción |
|------|-------------|
| `shutdown_stops_accepting_connections` | Tras SIGTERM, nuevas conexiones rechazadas |
| `shutdown_completes_inflight_request` | Request en curso se completa antes de cerrar |
| `shutdown_sends_terminate_to_all_agents` | Todos los agentes reciben `Terminate(NodeShuttingDown)` |
| `shutdown_waits_for_agents` | Espera hasta `shutdown_timeout_ms` |
| `shutdown_force_kills_after_timeout` | Agentes lentos se matan tras timeout |
| `shutdown_cleans_pid_file` | `sad.pid` se elimina al cerrar |
| `shutdown_continuous_stops_server` | Servidor continuous se detiene (wrapper aplica SIGTERM→SIGKILL) |
| `shutdown_returns_zero_on_success` | Exit code 0 si shutdown limpio |

---

### 7.10 Network Mode (`test/unit/decoders_test.gleam` - agregar)

| Test | Descripción |
|------|-------------|
| `decode_network_mode_managed_port` | `"managed_port"` → `ManagedPort` |
| `decode_network_mode_no_network` | `"no_network"` → `NoNetwork` |
| `decode_network_mode_unknown` | `"unknown_mode"` → Error descriptivo |
| `decode_network_mode_case_sensitive` | `"MANAGED_PORT"` → Error (no case insensitive) |

---

### 7.11 Port Pool (`test/unit/port_pool_test.gleam`)

**Framework:** gleeunit

| Test | Descripción |
|------|-------------|
| `port_pool_allocate_returns_port` | Allocate → puerto en rango configurado |
| `port_pool_allocate_checked_returns_port` | Allocate con check OK → puerto reservado |
| `port_pool_allocate_checked_skips_in_use` | Check `CheckPortInUse` salta al siguiente puerto |
| `port_pool_allocate_checked_port_in_use_error` | Un solo candidato ocupado → `PortInUse` |
| `port_pool_allocate_checked_no_available_after_retries` | Varios candidatos ocupados → `NoAvailablePortAfterRetries` |
| `port_pool_allocate_checked_bind_check_failed` | Check fatal → `BindCheckFailed` |
| `port_pool_allocate_checked_pool_exhausted` | Pool lleno → `PoolExhausted` aunque el check sea OK |
| `port_pool_allocate_unique` | N allocates → N puertos distintos |
| `port_pool_release_frees_port` | Release → puerto disponible de nuevo |
| `port_pool_exhausted_error` | Pool lleno → `Error(PoolExhausted)` |
| `port_pool_reuse_after_release` | Allocate tras release puede reusar |
| `port_pool_respects_range` | Puertos dentro de `[min_port, max_port]` |
| `port_pool_concurrent_allocate` | Allocates concurrentes no colisionan |
| `port_pool_requires_explicit_range` | `managed_port` requiere rango explícito (min>0, max>=min) |

---

### 7.11.1 Port check (bind-check real) (`test/integration/port_check_test.gleam` - agregar)

**Framework:** gleeunit (integración; usa sockets reales)

| Test | Descripción |
|------|-------------|
| `port_check_reports_in_use` | Puerto ocupado → `CheckPortInUse` |
| `port_check_invalid_host_returns_bind_failed` | Host inválido → `CheckBindFailed` |

---

### 7.11.2 Port pool con bind-check (`test/unit/port_pool_checked_test.gleam`, `test/integration/port_pool_checked_test.gleam` - agregar)

**Framework:** gleeunit

| Test | Descripción |
|------|-------------|
| `allocate_checked_with_success` | Check OK + uso OK → reserva exitosa |
| `allocate_checked_with_in_use_fails_fast` | Uso detecta puerto ocupado → `PortInUse` |
| `allocate_checked_with_bind_failed` | Uso falla → `BindCheckFailed` |
| `port_pool_checked_in_use_returns_error` | Puerto ocupado → `PortInUse` (integración) |
| `port_pool_checked_race_fails_fast` | Carrera entre check/uso → `PortInUse` (integración) |

---

### 7.11.3 `managed_port`: semántica de exhaustión (`test/integration/managed_port_semantics_test.gleam` - agregar)

**Framework:** gleeunit (integración; usa un zoo agent `continuous` y `limits.port_range_min/max` pequeño)

| Test | Descripción |
|------|-------------|
| `managed_port_exhaustion_transitions_to_failed` | Con rango de 1 puerto, 2 instancias continuous → una queda `Failed` con `failure_reason` estable `PORT_POOL_EXHAUSTED` |
| `managed_port_in_use_transitions_to_failed` | Puerto ocupado en el SO → `Failed` con `PORT_IN_USE` |
| `managed_port_bind_failed_transitions_to_failed` | Bind-check falla → `Failed` con `PORT_BIND_FAILED` |
| `managed_port_race_fails_fast` | Puerto se ocupa tras check → `Failed` con `PORT_IN_USE` (fail-fast) |
| `stop_releases_managed_port` | `stop` en continuous con `managed_port` libera el puerto al completar: crear otra instancia en rango 1 pasa |
| `start_after_stop_reallocates_managed_port` | stop → start vuelve a provisioning y reasigna puerto (puede ser el mismo si está libre) |
| `start_after_stop_can_fail_if_pool_taken` | stop(inst1) libera; create(inst2) ocupa; start(inst1) termina en `Failed` con `PORT_POOL_EXHAUSTED` |
| `delete_releases_managed_port` | `delete` libera el puerto: tras borrar, se puede crear otra instancia en rango 1 |

---

### 7.12 Cancelación no tumba al actor (`test/integration/cancel_safety_test.gleam` - agregar)

**Framework:** gleeunit (integración con actor real)

| Test | Descripción |
|------|-------------|
| `killing_worker_does_not_crash_actor` | Interacción en curso + matar worker → actor sigue vivo y limpia estado (Idle) |
| `worker_down_without_done_is_handled` | `WorkerDown` sin `InteractionDone` → actor responde error y vuelve a Idle |
| `timeout_does_not_crash_actor` | Timeout de interacción → se limpia estado sin tumbar actor; en transient se cierra el port y se detiene el runner |
| `hard_timeout_not_extended_by_output` | Runner emite output continuo → el timeout sigue siendo hard (no se resetea por actividad) |

---

### 7.13 Stop vs Delete (artefactos y workspace) (`test/integration/stop_delete_semantics_test.gleam` - agregar)

**Framework:** gleeunit (integración con gateway + filesystem)

| Test | Descripción |
|------|-------------|
| `stop_does_not_purge_artifacts` | Generar artefacto → `/stop` → `/artifacts/:artifact_id` sigue sirviendo el fichero |
| `stop_clears_assigned_port` | En `continuous` con `managed_port`, tras `/stop` el status muestra `assigned_port=null` |
| `start_after_stop_restores_assigned_port` | Tras `/start`, la instancia vuelve a `ready_continuous` con `assigned_port` dentro de rango (puede cambiar) |
| `delete_purges_artifacts_and_workspace` | Generar artefacto → `/delete` → artifact_registry no lo resuelve y fichero no existe |
| `delete_nonexistent_is_ok` | `/delete` sobre instancia inexistente → 200 (no-op idempotente) |
| `delete_cleanup_failure_returns_500` | Forzar fallo de `workspace.cleanup` → `/delete` devuelve 500 (Problem Details) y la instancia no se elimina |
| `delete_cleanup_failure_still_purges_artifacts` | Cleanup falla → los ArtifactIds dejan de resolverse (rollback de seguridad) |
| `stop_while_interaction_inflight_cleans_worker` | Interact en curso + `/stop` → worker/port terminan; no quedan procesos colgando; instancia pasa a `Stopped` |
| `stop_while_interaction_inflight_client_sees_cancelled` | Interact en curso + `/stop` → el cliente de `interact` recibe error “cancelled” (sync o SSE terminal) |
| `delete_while_interaction_inflight_cleans_everything` | Interact en curso + `/delete` → worker/port terminan; workspace eliminado; artefactos purgados; instancia desaparece |
| `delete_while_interaction_inflight_client_sees_cancelled` | Interact en curso + `/delete` → el cliente de `interact` recibe error “cancelled” antes del borrado |

---

### 7.14 WorkspacePath: casos agresivos (incluidos)

Los casos “agresivos” de traversal (Windows separators, `%2e%2e`, null bytes y symlink escape) están cubiertos como parte de los tests unitarios de `sad/workspace.gleam` (ver §3.2). No se crea un fichero de tests separado para esto.

---

### 7.16 Backpressure (mailbox acotado) (`test/integration/backpressure_test.gleam` - agregar)

**Framework:** gleeunit (integración)

**Nota:** estos casos están planificados para S19 (v0) salvo que se prioricen antes.

| Test | Descripción |
|------|-------------|
| `logs_drop_under_pressure` | Logs a alta tasa + consumer lento → no OOM; se observan drops/coalesce |
| `interaction_backpressure_or_discard_under_pressure` | Streaming de interacción + SSE lento → el producer aplica backpressure hacia el `sad/streams/sink.StreamSink` hasta `push_timeout_ms` y luego degrada a discard (sin OOM) |
| `slow_ack_applies_backpressure` | `StreamSink.push_batch` con ack artificialmente lento → el worker no acumula eventos sin límite (no OOM) |
| `mailbox_does_not_grow_unbounded` | Bajo carga sostenida, `message_queue_len` del actor/stream pump se mantiene acotado |
| `disconnect_does_not_cancel` | Cortar SSE no cancela la ejecución; solo detiene la entrega |
| `sink_disconnect_switches_to_discard` | Si el `sad/streams/sink.StreamSink` muere (cliente desconectado), el worker deja de empujar batches y aun así emite `InteractionDone` al actor |
| `disconnect_still_emits_interaction_done` | Cliente SSE desconecta temprano → el actor recibe `InteractionDone` igualmente (resultado completo) |

---

### 7.17 Port process + wrapper (`test/integration/port_process_test.gleam` - agregar)

**Framework:** gleeunit (integración con scripts de test)

| Test | Descripción |
|------|-------------|
| `port_process_delivers_stdout_lines` | Runner emite 2 líneas JSONL → 2 `PortStdout` (sin merges/splits) |
| `port_process_exit_status_propagated` | Proceso sale con código !=0 → `PortExit(code)` correcto |
| `stderr_noise_does_not_break_stdout` | Runner escribe mucho en STDERR + stdout válido → SAD no lo bufferiza ni falla por ello |
| `port_process_rejects_oversized_event_line` | Runner emite 1 evento JSONL > 262_144 bytes → error de contrato (InfraError) claro |
| `port_process_noeol_fragmentation_is_contract_error` | Runner emite línea sin `\\n` y termina → error de contrato claro (sin reensamblar) |
| `port_process_invalid_json_line_is_contract_error` | Runner emite una línea con `\\n` pero JSON inválido → error de contrato estable (no panic; no intenta “adivinar”) |
| `wrapper_eof_triggers_stop` | Cerrar stdin → wrapper aplica stop y el port termina en tiempo |
| `wrapper_stop_timeout_escalates_to_sigkill` | Runner ignora SIGTERM/stop → wrapper aplica SIGKILL tras grace y el port termina (sin quedar huérfanos) |
| `wrapper_stop_timing_respects_double_shutdown` | Secuencia de stop respeta el doble `shutdown_timeout_ms` antes de SIGKILL (el `post_kill_wait_ms` es best-effort) |
| `wrapper_is_silent_on_stdout` | Wrapper no emite bytes por STDOUT (solo runner), para no romper el contrato JSONL |

---

### 7.18 Terminal de streaming (resultado y artefactos) (`test/integration/streaming_terminal_test.gleam` - agregar)

**Framework:** gleeunit (gateway + SSE + runner streaming)

| Test | Descripción |
|------|-------------|
| `streaming_terminal_includes_artifacts` | SSE terminal incluye `artifacts` con URLs públicas (`/artifacts/<id>`) |
| `interaction_done_contains_artifacts` | En streaming, el actor recibe `InteractionDone` con `InteractionResult.artifacts` completos |
| `streaming_terminal_preserves_trace_id` | `trace_id` en evento terminal coincide con el request |
| `streaming_finish_closes_connection` | Tras evento terminal (`StreamFinished` o error), la conexión SSE se cierra (no queda colgada) |
| `logs_stream_sends_keep_alive` | `GET /sys/.../logs/stream` envía comentarios SSE periódicos (keep-alive) en ausencia de logs |

---

### 7.19 Anti-orphans (supervisión) (`test/integration/supervision_orphans_test.gleam` - agregar)

**Framework:** gleeunit (OTP real)

| Test | Descripción |
|------|-------------|
| `killing_agent_manager_actor_kills_agents` | Matar `AgentManagerActor` → agentes caen (sin huérfanos) |
| `registry_crash_rest_for_one_kills_and_restarts_subtree` | Crash de `RegistryActor` → `RestForOne` tumba y reinicia dependientes (manager/factory/http), sin huérfanos; registry queda consistente |

## 8. Prioridad de implementación (alineada con `docs/plan`)

### Etapas 1–2: Fundamentos (crítico)
1. `test/unit/types_test.gleam` - estados/errores/secretos (safe-to-log)
2. `test/unit/workspace_test.gleam` - seguridad de paths (incluye symlink-safe si aplica)

### Etapas 3–5: Dominio puro (sin IO)
3. `test/unit/decoders_test.gleam` - parsing de perfiles/config
4. `test/unit/params_test.gleam` - resolución determinista
5. `test/unit/interpolator_test.gleam` - templates strict
6. `test/unit/response_mapping_test.gleam` - JSON pointer mapping
7. `test/unit/runner_contract_test.gleam` + `test/unit/jsonl_events_test.gleam` - contrato runner + eventos JSONL
8. `test/unit/serialization_test.gleam` - JSON wire (`SadInput`, payloads, logs)

### Etapas 6–8: Bridge (IO controlado)
9. `test/unit/ffi_test.gleam` + `test/integration/port_process_test.gleam` - FFI mínima + ports + wrapper v0.1
10. `test/integration/runner_test.gleam` - transient E2E con zoo
11. `test/integration/client_test.gleam` - continuous HTTP + streaming upstream

### Etapa 9: Borde SSE y safe-call
12. `test/unit/safe_call_test.gleam` + `test/unit/streams_sink_test.gleam` - borde sin panic + backpressure
13. `test/integration/backpressure_test.gleam` - integración: drop/coalesce + discard sin OOM

### Etapa 10: Core OTP
14. `test/unit/messages_test.gleam`, `test/unit/agent_test.gleam`, `test/unit/registry_test.gleam`, `test/unit/supervisor_test.gleam`, `test/unit/artifact_registry_test.gleam`
15. `test/integration/cancel_safety_test.gleam`, `test/integration/managed_port_semantics_test.gleam`, `test/integration/supervision_orphans_test.gleam`

### Etapa 11: Gateway + adapters + E2E
16. `test/unit/agui_test.gleam`, `test/unit/a2a_test.gleam`
17. `test/integration/config_test.gleam`, `test/integration/sad_test.gleam`, `test/integration/api_test.gleam`, `test/integration/proxy_test.gleam`, `test/integration/ui_proxy_test.gleam`
18. `test/integration/stop_delete_semantics_test.gleam`, `test/integration/streaming_terminal_test.gleam`

### Post-v0: Properties
19. `test/properties/workspace_props.gleam` (y el resto de `test/properties/*_props.gleam`) - propiedades gleam_qcheck

---

## 9. Fixtures de datos

**Estructura esperada (alineada con `docs/plan`):**
- `test/test_assertions.gleam`
- Source root: `test/fixtures/source_local/`
  - Runners: `test/fixtures/source_local/runners/echo_cli.py`, `test/fixtures/source_local/runners/echo_server.py`, `test/fixtures/source_local/runners/greedy_logger.py`, `test/fixtures/source_local/runners/slow_poke.py`, `test/fixtures/source_local/runners/crasher.py`, `test/fixtures/source_local/runners/artifact_gen.py`, `test/fixtures/source_local/runners/streaming_echo.py`
  - Perfiles: `test/fixtures/source_local/profiles/echo_cli.json`, `test/fixtures/source_local/profiles/echo_server.json`, `test/fixtures/source_local/profiles/greedy_logger.json`, `test/fixtures/source_local/profiles/slow_poke.json`, `test/fixtures/source_local/profiles/crasher.json`, `test/fixtures/source_local/profiles/artifact_gen.json`, `test/fixtures/source_local/profiles/streaming_echo.json`
- Config: `test/fixtures/config/test_config.toml`
- Payloads: `test/fixtures/payloads/chat_simple.json`, `test/fixtures/payloads/chat_multi.json`, `test/fixtures/payloads/files_single.json`

### 9.1 Perfiles de prueba

```json
// test/fixtures/source_local/profiles/echo_cli.json
{
  "meta": {
    "id": "echo_cli",
    "lifecycle": "transient",
    "description": "Echo CLI for testing"
  },
  "parameters": {
    "delay_ms": {"source": "fixed", "value": 100, "type": "int"}
  },
  "runner": {
    "type": "echo_cli",
    "tool_config": {"script": "echo_cli.py"}
  },
  "interface": {
    "protocol": "runner",
    "capabilities": {
      "echo": {"input_schema": "std:chat", "streaming": false}
    }
  }
}
```

```json
// test/fixtures/source_local/profiles/echo_server.json
{
  "meta": {
    "id": "echo_server",
    "lifecycle": "continuous",
    "description": "Echo HTTP server for testing"
  },
  "parameters": {},
  "runner": {
    "type": "echo_server",
    "tool_config": {"script": "echo_server.py"}
  },
  "interface": {
    "protocol": "http",
    "base_url": "http://{{runner.host}}:{{runner.port}}",
    "health_check": {"path": "/health", "method": "GET", "expect_statuses": [200]},
    "capabilities": {
      "echo": {"path": "/echo", "method": "POST", "streaming": false}
    }
  }
}
```

### 9.2 Config de prueba

```toml
# test/fixtures/config/test_config.toml
[server]
host = "127.0.0.1"
port = 0  # Puerto aleatorio (solo para el HTTP server de tests)

[auth]
api_key = "test-api-key"

[limits]
call_timeout_ms = 5000
status_timeout_ms = 1000
shutdown_timeout_ms = 2000
health_check_timeout_ms = 1000

[profiles]
sources = [
  {type = "dir", path = "./test/fixtures/source_local"}
]
git_cache_dir = "./test/fixtures/.cache/git"

[runners]
python_bin = "python3"

[workspaces]
directory = "./test-workspaces"
```

### 9.3 Payloads de prueba

```json
// test/fixtures/payloads/chat_simple.json
{
  "messages": [
    {"role": "user", "content": "Hello"}
  ]
}

// test/fixtures/payloads/chat_multi.json
{
  "messages": [
    {"role": "user", "content": "Hi"},
    {"role": "assistant", "content": "Hello!"},
    {"role": "user", "content": "How are you?"}
  ]
}

// test/fixtures/payloads/files_single.json
{
  "files": [
    {"name": "doc.pdf", "url": "https://example.com/doc.pdf", "mime": "application/pdf"}
  ]
}
```

---

## 9. Runners del Zoo

### 9.1 echo_cli.py

```python
#!/usr/bin/env python3
"""Echo CLI runner for testing."""
import sys
import json
import time

def main():
    if "--provision" in sys.argv:
        print(json.dumps({"status": "success", "log_files": []}))
        return 0
    
    input_json = json.loads(sys.stdin.read())
    delay_ms = input_json.get("params", {}).get("delay_ms", 100)
    time.sleep(delay_ms / 1000)
    
    response = {
        "status": "success",
        "data": input_json.get("input", {}),
        "artifacts": [],
        "error": None
    }
    print(json.dumps({"t": "result", **response}))
    return 0

if __name__ == "__main__":
    sys.exit(main())
```

### 9.2 echo_server.py

Referencia completa (v0): `arquitectura/examples/snippets/zoo_echo_server.py`.

Extracto (v0):

```python
#!/usr/bin/env python3
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"status": "healthy"}')

def main():
    if "--provision" in sys.argv:
        print(json.dumps({"t": "provision_result", "status": "success", "log_files": []}))
        return 0

    port = int(os.environ.get("PORT", 8080))
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
```

### 9.3 slow_poke.py

```python
#!/usr/bin/env python3
"""Slow health check server for timeout testing."""
import time
# ... igual que echo_server pero /health hace time.sleep(10)
```

### 9.4 crasher.py

```python
#!/usr/bin/env python3
"""Server that crashes after first request."""
import sys
# ... responde a /health OK, luego en /echo hace sys.exit(1)
```

### 9.5 greedy_logger.py

```python
#!/usr/bin/env python3
"""Runner that emits many log events."""
import sys
import json

def main():
    def emit(obj):
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()
    
    # Emitir ~1MB de logs (JSONL)
    for _ in range(10000):
        emit({"t": "log", "level": "info", "message": "x" * 100})
    
    # Resultado final
    emit({"t": "result", "status": "success", "data": {}, "artifacts": [], "error": None})
    return 0
```

### 9.6 artifact_gen.py

```python
#!/usr/bin/env python3
"""Runner that generates artifacts."""
import sys
import json
import os

def main():
    input_json = json.loads(sys.stdin.read())
    workspace = os.environ.get("SAD_WORKSPACE", "/tmp")
    
    # Crear archivo
    output_path = os.path.join(workspace, "outputs", "report.pdf")
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "wb") as f:
        f.write(b"%PDF-1.4 test content")
    
    response = {
        "status": "success",
        "data": {},
        "artifacts": [
            {"name": "report.pdf", "path": "outputs/report.pdf", "mime": "application/pdf"}
        ]
    }
    print(json.dumps(response))
    return 0
```

### 9.7 streaming_echo.py

```python
#!/usr/bin/env python3
"""Runner that streams output."""
import sys
import json
import time

def main():
    input_json = json.loads(sys.stdin.read())
    content = input_json.get("input", {}).get("messages", [{}])[-1].get("content", "")
    
    # Emitir chunks
    for word in content.split():
        chunk = {"t": "chunk", "delta": word + " "}
        print(json.dumps(chunk), flush=True)
        time.sleep(0.05)
    
    # Respuesta final
    print(json.dumps({"t": "result", "status": "success", "data": {"content": content}, "artifacts": [], "error": None}))
    return 0
```

---

## 10. Helpers de test

### 10.1 Test utilities

Referencia completa (v0): `arquitectura/examples/snippets/tests_test_helpers.gleam`.

Extracto (v0):

```gleam
pub fn test_config() -> SadConfig {
  ...
}
```

### 10.2 Assertions comunes

```gleam
// test/test_assertions.gleam

import gleeunit/should

/// Verifica que Result es Ok y devuelve el valor.
pub fn assert_ok(result: Result(a, e)) -> a {
  case result {
    Ok(v) -> v
    Error(e) -> panic as ("Expected Ok, got Error: " <> string.inspect(e))
  }
}

/// Verifica que Result es Error y devuelve el error.
pub fn assert_error(result: Result(a, e)) -> e {
  case result {
    Ok(v) -> panic as ("Expected Error, got Ok: " <> string.inspect(v))
    Error(e) -> e
  }
}

/// Verifica que lista tiene exactamente N elementos.
pub fn assert_length(list: List(a), expected: Int) {
  list.length(list) |> should.equal(expected)
}
```
