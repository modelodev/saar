// Extracted reference snippet (v0)
// Source: arquitectura/bridge.md:137
// Purpose: documentation-only; may not compile as-is.

import gleam/dict.{type Dict}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import sad/types.{
  type ArtifactConfig, type ChatMessage, type ConfigValue, type ErrorKind,
  type FileRef, type InputPayload, type InputValue, type InstanceId,
  type Lifecycle, type LogEvent, type ProfileId, type RequestContext,
  type Runner, type RunnerError, type RuntimeConfig, type SadHelpers,
  type SadInput, type SadInputMeta, type StreamContext, type StreamEvent,
  type ToolConfig, type TraceId, type Value, BoolVal, ContentChunk, FloatVal,
  IntVal, ListVal, PayloadChat, PayloadFiles, PayloadMixed, StreamError,
  StreamFinished, StreamStarted, StringVal, error_kind_to_string,
  instance_id_to_string, lifecycle_to_string, network_mode_to_string,
  profile_id_to_string, trace_id_to_string, value_to_string,
}

// Streaming (tipos genéricos)

// ============================================================================
// SERIALIZACIÓN DE SadInput
// ============================================================================

/// Serializa SadInputMeta a JSON para el wire.
/// Reemplaza el tipo SadInputMetaWire.
pub fn sad_input_meta_to_json(meta: SadInputMeta) -> Json {
  json.object([
    #("spec_version", json.string(meta.spec_version)),
    #("profile_id", json.string(profile_id_to_string(meta.profile_id))),
    #("instance_id", case meta.instance_id {
      Some(id) -> json.string(instance_id_to_string(id))
      None -> json.null()
    }),
    #("mode", json.string(lifecycle_to_string(meta.mode))),
  ])
}

/// Serializa RequestContext a Dict plano para el wire.
/// SAD es stateless: solo trace_id + extra.
pub fn request_context_to_dict(ctx: RequestContext) -> Dict(String, String) {
  dict.new()
  |> dict.insert("trace_id", trace_id_to_string(ctx.trace_id))
  |> dict.merge(ctx.extra)
}

/// Serializa RequestContext a JSON.
pub fn request_context_to_json(ctx: RequestContext) -> Json {
  ctx
  |> request_context_to_dict
  |> dict.to_list
  |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) })
  |> json.object
}

/// Serializa params (ResolvedValue) a strings para env vars del runner.
/// Usa resolved_value_to_env() que maneja tanto valores normales como secretos.
/// NOTA: Esta función es segura porque los valores van a env vars, no a logs.
pub fn params_to_env_dict(params: ResolvedParams) -> Dict(String, String) {
  dict.map_values(params, fn(_k, v) { resolved_value_to_env(v) })
}

/// Serializa params a JSON para el wire (SadInput).
/// ADVERTENCIA: Los secretos se incluyen en el JSON porque van al runner.
/// Este JSON NO debe loguearse.
pub fn params_to_json(params: ResolvedParams) -> Json {
  params
  |> params_to_env_dict
  |> dict.to_list
  |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) })
  |> json.object
}

/// Serializa params para logs/debug (secretos redactados).
pub fn params_to_debug_dict(params: ResolvedParams) -> Dict(String, String) {
  dict.map_values(params, fn(_k, v) { resolved_value_inspect(v) })
}

/// Serializa RunnerError a JSON.
/// Reemplaza el tipo RunnerErrorWire para serialización directa.
pub fn runner_error_to_json(err: RunnerError) -> Json {
  json.object([
    #("kind", json.string(error_kind_to_string(err.kind))),
    #("message", json.string(err.message)),
  ])
}

/// Serializa SadHelpers a JSON.
pub fn helpers_to_json(helpers: SadHelpers) -> Json {
  json.object([
    #("last_user_content", case helpers.last_user_content {
      Some(content) -> json.string(content)
      None -> json.null()
    }),
    #("last_user_files", json.array(helpers.last_user_files, file_ref_to_json)),
  ])
}

/// Serializa FileRef a JSON.
pub fn file_ref_to_json(file: FileRef) -> Json {
  json.object([
    #("url", json.string(file.url)),
    #("mime", json.string(file.mime)),
    #("name", json.string(file.name)),
    #("context", case file.context {
      Some(ctx) -> json.string(ctx)
      None -> json.null()
    }),
  ])
}

/// Serializa ChatMessage a JSON.
pub fn chat_message_to_json(msg: ChatMessage) -> Json {
  json.object([
    #("role", json.string(msg.role)),
    #("content", json.string(msg.content)),
  ])
}

/// Serializa InputValue a JSON.
pub fn input_value_to_json(value: InputValue) -> Json {
  case value {
    StringVal(s) -> json.string(s)
    IntVal(i) -> json.int(i)
    FloatVal(f) -> json.float(f)
    BoolVal(b) -> json.bool(b)
    ListVal(items) -> json.array(items, json.string)
  }
}

/// Serializa InputPayload a JSON, mezclando extra_params en la raíz para Chat/Mixed.
pub fn input_payload_to_json(payload: InputPayload) -> Json {
  case payload {
    PayloadChat(messages, extra) -> {
      let base = [#("messages", json.array(messages, chat_message_to_json))]
      let extra_fields =
        extra
        |> dict.to_list
        |> list.map(fn(pair) { #(pair.0, input_value_to_json(pair.1)) })
      json.object(list.append(base, extra_fields))
    }
    PayloadFiles(files) -> {
      json.object([#("files", json.array(files, file_ref_to_json))])
    }
    PayloadMixed(messages, files, extra) -> {
      let base = [
        #("messages", json.array(messages, chat_message_to_json)),
        #("files", json.array(files, file_ref_to_json)),
      ]
      let extra_fields =
        extra
        |> dict.to_list
        |> list.map(fn(pair) { #(pair.0, input_value_to_json(pair.1)) })
      json.object(list.append(base, extra_fields))
    }
  }
}

/// Serializa Runner a JSON.
pub fn runner_to_json(runner: Runner) -> Json {
  json.object([
    #("type", json.string(runner.type_)),
    #("tool_config", tool_config_to_json(runner.tool_config)),
    #("runtime", runtime_config_to_json(runner.runtime)),
    #(
      "env_map",
      json.object(
        runner.env_map
        |> dict.to_list
        |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) }),
      ),
    ),
    #("args", json.array(runner.args, json.string)),
    #("artifact_config", artifact_config_to_json(runner.artifact_config)),
  ])
}

fn tool_config_to_json(tc: ToolConfig) -> Json {
  json.object([
    #("package", json.string(tc.package)),
    #("command", json.string(tc.command)),
    #("with_packages", json.array(tc.with_packages, json.string)),
  ])
}

fn runtime_config_to_json(rc: RuntimeConfig) -> Json {
  json.object([
    #("mode", json.string(network_mode_to_string(rc.mode))),
    #("port_env_var", case rc.port_env_var {
      Some(v) -> json.string(v)
      None -> json.null()
    }),
    #("host_env_var", case rc.host_env_var {
      Some(v) -> json.string(v)
      None -> json.null()
    }),
  ])
}

fn artifact_config_to_json(ac: ArtifactConfig) -> Json {
  json.object([
    #("include", json.array(ac.include, json.string)),
    #("exclude", json.array(ac.exclude, json.string)),
  ])
}

/// Serializa SadInput completo a JSON para enviar al runner.
/// Reemplaza el tipo SadInputWire.
/// Los params ya vienen resueltos; aquí solo se serializan.
pub fn sad_input_to_json(input: SadInput) -> Json {
  json.object([
    #("meta", sad_input_meta_to_json(input.meta)),
    #("params", params_to_json(input.params)),
    #("input", input_payload_to_json(input.input)),
    #("context", request_context_to_json(input.context)),
    #("helpers", case input.helpers {
      Some(h) -> helpers_to_json(h)
      None -> json.null()
    }),
    #("runner_def", runner_to_json(input.runner_def)),
  ])
}

/// Convierte SadInput a string JSON listo para enviar por STDIN.
pub fn sad_input_to_string(input: SadInput) -> String {
  input
  |> sad_input_to_json
  |> json.to_string
}

// ============================================================================
// SERIALIZACIÓN DE LogEvent (para SSE)
// ============================================================================

/// Serializa LogEvent a JSON para SSE.
pub fn log_event_to_json(event: LogEvent) -> Json {
  json.object([
    #("ts_ms", json.int(event.ts_ms)),
    #("line", json.string(event.line)),
    #("trace_id", case event.trace_id {
      Some(tid) -> json.string(trace_id_to_string(tid))
      None -> json.null()
    }),
  ])
}
// ============================================================================
// NOTA SOBRE STREAMING
// ============================================================================
// 
// El bridge emite eventos StreamEvent genéricos (ContentChunk, StreamStarted, etc.)
// definidos en tipos.md.
//
// La conversión a formatos específicos de protocolo (AG-UI, A2A) ocurre en los
// adapters (agui.gleam, a2a.gleam), NO en el bridge.
//
// Ver:
//   - tipos.md §11 para los tipos genéricos de streaming
//   - protocolos.md §3 para el adapter AG-UI
//   - protocolos.md §2 para el adapter A2A streaming
