import gleam/dict
import gleam/json.{type Json}
import gleam/list
import gleam/option
import sad/types

pub fn sad_input_to_json(input: types.SadInput) -> Json {
  json.object([
    #("meta", sad_input_meta_to_json(input.meta)),
    #("params", params_to_json(input.params)),
    #("input", input_payload_to_json(input.input)),
    #("context", request_context_to_json(input.context)),
    #("helpers", json.null()),
    #("runner_def", runner_to_json(input.runner_def)),
  ])
}

pub fn sad_input_to_string(input: types.SadInput) -> String {
  input
  |> sad_input_to_json
  |> json.to_string
}

fn sad_input_meta_to_json(meta: types.SadInputMeta) -> Json {
  json.object([
    #("spec_version", json.string(meta.spec_version)),
    #("profile_id", json.string(types.profile_id_to_string(meta.profile_id))),
    #("instance_id", case meta.instance_id {
      option.Some(id) -> json.string(types.instance_id_to_string(id))
      option.None -> json.null()
    }),
    #("mode", json.string(types.lifecycle_to_string(meta.mode))),
  ])
}

fn params_to_json(params: types.ResolvedParams) -> Json {
  params
  |> dict.to_list
  |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) })
  |> json.object
}

fn request_context_to_json(ctx: types.RequestContext) -> Json {
  let base =
    ctx.extra
    |> dict.insert("trace_id", types.trace_id_to_string(ctx.trace_id))
    |> dict.to_list
    |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) })

  json.object(base)
}

fn input_payload_to_json(payload: types.InputPayload) -> Json {
  case payload {
    types.PayloadChat(messages, extra) -> {
      let base = [#("messages", json.array(messages, chat_message_to_json))]
      let extra_fields =
        extra
        |> dict.to_list
        |> list.map(fn(pair) { #(pair.0, input_value_to_json(pair.1)) })
      json.object(list.append(base, extra_fields))
    }
    types.PayloadFiles(files) ->
      json.object([#("files", json.array(files, file_ref_to_json))])
    types.PayloadMixed(messages, files, extra) -> {
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

fn chat_message_to_json(message: types.ChatMessage) -> Json {
  json.object([
    #("role", json.string(message.role)),
    #("content", json.string(message.content)),
  ])
}

fn file_ref_to_json(file: types.FileRef) -> Json {
  json.object([
    #("url", json.string(file.url)),
    #("mime", json.string(file.mime)),
    #("name", json.string(file.name)),
    #("context", case file.context {
      option.Some(ctx) -> json.string(ctx)
      option.None -> json.null()
    }),
  ])
}

fn input_value_to_json(value: types.InputValue) -> Json {
  case value {
    types.StringVal(s) -> json.string(s)
    types.IntVal(i) -> json.int(i)
    types.FloatVal(f) -> json.float(f)
    types.BoolVal(b) -> json.bool(b)
    types.ListVal(items) -> json.array(items, json.string)
  }
}

fn runner_to_json(runner: types.Runner) -> Json {
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

fn tool_config_to_json(config: types.ToolConfig) -> Json {
  json.object([
    #("package", json.string(config.package)),
    #("command", json.string(config.command)),
    #("with_packages", json.array(config.with_packages, json.string)),
  ])
}

fn runtime_config_to_json(config: types.RuntimeConfig) -> Json {
  json.object([
    #("mode", json.string(types.network_mode_to_string(config.mode))),
    #("port_env_var", case config.port_env_var {
      option.Some(value) -> json.string(value)
      option.None -> json.null()
    }),
    #("host_env_var", case config.host_env_var {
      option.Some(value) -> json.string(value)
      option.None -> json.null()
    }),
  ])
}

fn artifact_config_to_json(config: types.ArtifactConfig) -> Json {
  json.object([
    #("include", json.array(config.include, json.string)),
    #("exclude", json.array(config.exclude, json.string)),
  ])
}
