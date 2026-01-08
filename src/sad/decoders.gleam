import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/input as types_input
import sad/types/profile as types_profile
import sad/types/runner as types_runner

pub fn decode_profile(
  value: Dynamic,
) -> Result(types_profile.Profile, List(decode.DecodeError)) {
  decode.run(value, profile_decoder())
}

pub fn decode_runner(
  value: Dynamic,
) -> Result(types_runner.Runner, List(decode.DecodeError)) {
  decode.run(value, runner_decoder())
}

pub fn decode_interface(
  value: Dynamic,
) -> Result(types_profile.Interface, List(decode.DecodeError)) {
  decode.run(value, interface_decoder())
}

pub fn decode_capabilities(
  value: Dynamic,
) -> Result(
  dict.Dict(String, types_profile.RunnerCapability),
  List(decode.DecodeError),
) {
  decode.run(value, runner_capabilities_decoder())
}

pub fn decode_input_schema(
  value: Dynamic,
) -> Result(types_profile.InputSchema, List(decode.DecodeError)) {
  decode.run(value, input_schema_decoder())
}

pub fn decode_network_mode(
  value: Dynamic,
) -> Result(types_runner.NetworkMode, List(decode.DecodeError)) {
  decode.run(value, network_mode_decoder())
}

pub fn decode_payload_std_chat(
  inputs: Dynamic,
  extra_fields: dict.Dict(String, types_profile.ExtraFieldDef),
) -> Result(types_input.InputPayload, List(decode.DecodeError)) {
  use fields <- result.try(decode_object(inputs))
  use messages <- result.try(decode_required_field(
    fields,
    "messages",
    chat_messages_decoder(),
  ))
  use extra <- result.try(decode_extra_fields_from_fields(extra_fields, fields))
  Ok(types_input.PayloadChat(messages, extra))
}

pub fn decode_payload_std_files(
  inputs: Dynamic,
) -> Result(types_input.InputPayload, List(decode.DecodeError)) {
  use fields <- result.try(decode_object(inputs))
  use files <- result.try(decode_required_field(
    fields,
    "files",
    files_decoder(),
  ))
  Ok(types_input.PayloadFiles(files))
}

pub fn decode_payload_mixed(
  inputs: Dynamic,
  extra_fields: dict.Dict(String, types_profile.ExtraFieldDef),
) -> Result(types_input.InputPayload, List(decode.DecodeError)) {
  use fields <- result.try(decode_object(inputs))
  use messages <- result.try(decode_required_field(
    fields,
    "messages",
    chat_messages_decoder(),
  ))
  use files <- result.try(decode_required_field(
    fields,
    "files",
    files_decoder(),
  ))
  use extra <- result.try(decode_extra_fields_from_fields(extra_fields, fields))
  Ok(types_input.PayloadMixed(messages, files, extra))
}

pub fn decode_extra_fields(
  extra_fields: dict.Dict(String, types_profile.ExtraFieldDef),
  inputs: Dynamic,
) -> Result(dict.Dict(String, types_input.InputValue), List(decode.DecodeError)) {
  use fields <- result.try(decode_object(inputs))
  decode_extra_fields_from_fields(extra_fields, fields)
}

pub fn profile_decoder() -> decode.Decoder(types_profile.Profile) {
  let decoder = {
    use meta <- decode.field("meta", profile_meta_decoder())
    use parameters <- decode.optional_field(
      "parameters",
      dict.new(),
      parameters_decoder(),
    )
    use runner <- decode.field("runner", runner_decoder())
    use interface <- decode.field("interface", interface_decoder())
    decode.success(types_profile.Profile(
      meta: meta,
      parameters: parameters,
      runner: runner,
      interface: interface,
    ))
  }
  decoder
}

fn profile_meta_decoder() -> decode.Decoder(types_profile.ProfileMeta) {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use name <- decode.optional_field(
      "name",
      None,
      decode.optional(decode.string),
    )
    use lifecycle <- decode.field("lifecycle", lifecycle_decoder())
    use description <- decode.field("description", decode.string)
    decode.success(types_profile.ProfileMeta(
      id: types_core.profile_id(id),
      name: name,
      lifecycle: lifecycle,
      description: description,
    ))
  }
  decoder
}

fn lifecycle_decoder() -> decode.Decoder(types_enums.Lifecycle) {
  let decoder = {
    use lifecycle <- decode.then(decode.string)
    case types_enums.lifecycle_from_string(lifecycle) {
      Ok(value) -> decode.success(value)
      Error(_) -> decode.failure(types_enums.Transient, expected: "Lifecycle")
    }
  }
  decoder
}

fn parameters_decoder() -> decode.Decoder(
  dict.Dict(String, types_profile.Parameter),
) {
  decode.dict(decode.string, parameter_decoder())
}

fn parameter_decoder() -> decode.Decoder(types_profile.Parameter) {
  let decoder = {
    use source <- decode.field("source", decode.string)
    case source {
      "fixed" -> fixed_param_decoder()
      "config" -> config_param_decoder()
      "secret" -> secret_param_decoder()
      "init" -> init_param_decoder()
      _ -> decode.failure(parameter_placeholder(), expected: "ParamSource")
    }
  }
  decoder
}

fn fixed_param_decoder() -> decode.Decoder(types_profile.Parameter) {
  let decoder = {
    use expected <- decode.field("type", value_type_decoder())
    use value <- decode.field("value", value_decoder(expected))
    decode.success(types_profile.FixedParam(value))
  }
  decoder
}

fn config_param_decoder() -> decode.Decoder(types_profile.Parameter) {
  let decoder = {
    use key <- decode.field("key", decode.string)
    use expected <- decode.field("type", value_type_decoder())
    use default <- decode.optional_field(
      "default",
      None,
      decode.optional(value_decoder(expected)),
    )
    decode.success(types_profile.ConfigParam(key, default, expected))
  }
  decoder
}

fn secret_param_decoder() -> decode.Decoder(types_profile.Parameter) {
  let decoder = {
    use key <- decode.field("key", decode.string)
    use expected <- decode.field("type", value_type_decoder())
    use default <- decode.optional_field(
      "default",
      None,
      decode.optional(value_decoder(expected)),
    )
    case default {
      Some(_) ->
        decode.failure(parameter_placeholder(), expected: "NoSecretDefault")
      None -> decode.success(types_profile.SecretParam(key, expected))
    }
  }
  decoder
}

fn init_param_decoder() -> decode.Decoder(types_profile.Parameter) {
  let decoder = {
    use key <- decode.field("key", decode.string)
    use expected <- decode.field("type", value_type_decoder())
    use default <- decode.optional_field(
      "default",
      None,
      decode.optional(value_decoder(expected)),
    )
    decode.success(types_profile.InitParam(key, default, expected))
  }
  decoder
}

fn parameter_placeholder() -> types_profile.Parameter {
  types_profile.FixedParam(types_core.StringVal(""))
}

pub fn runner_decoder() -> decode.Decoder(types_runner.Runner) {
  let decoder = {
    use type_ <- decode.field("type", decode.string)
    use tool_config <- decode.field("tool_config", tool_config_decoder())
    use runtime <- decode.optional_field(
      "runtime",
      types_runner.default_runtime_config(),
      runtime_config_decoder(),
    )
    use env_map <- decode.optional_field(
      "env_map",
      dict.new(),
      decode.dict(decode.string, decode.string),
    )
    use args <- decode.optional_field(
      "args",
      [],
      decode.list(of: decode.string),
    )
    use artifact_config <- decode.optional_field(
      "artifact_config",
      types_runner.default_artifact_config(),
      artifact_config_decoder(),
    )
    decode.success(types_runner.Runner(
      type_: type_,
      tool_config: tool_config,
      runtime: runtime,
      env_map: env_map,
      args: args,
      artifact_config: artifact_config,
    ))
  }
  decoder
}

fn tool_config_decoder() -> decode.Decoder(types_runner.ToolConfig) {
  decode.one_of(tool_config_script_decoder(), or: [
    tool_config_package_decoder(),
  ])
}

fn tool_config_script_decoder() -> decode.Decoder(types_runner.ToolConfig) {
  let decoder = {
    use script <- decode.field("script", decode.string)
    decode.success(types_runner.ToolConfigScript(script))
  }
  decoder
}

fn tool_config_package_decoder() -> decode.Decoder(types_runner.ToolConfig) {
  let decoder = {
    use package <- decode.field("package", decode.string)
    use command <- decode.field("command", decode.string)
    use with_packages <- decode.optional_field(
      "with_packages",
      [],
      decode.list(of: decode.string),
    )
    decode.success(types_runner.ToolConfigPackage(
      package: package,
      command: command,
      with_packages: with_packages,
    ))
  }
  decoder
}

fn runtime_config_decoder() -> decode.Decoder(types_runner.RuntimeConfig) {
  let decoder = {
    use mode <- decode.optional_field(
      "mode",
      types_runner.NoNetwork,
      network_mode_decoder(),
    )
    use port_env_var <- decode.optional_field(
      "port_env_var",
      None,
      decode.optional(decode.string),
    )
    use host_env_var <- decode.optional_field(
      "host_env_var",
      None,
      decode.optional(decode.string),
    )
    decode.success(types_runner.RuntimeConfig(
      mode: mode,
      port_env_var: port_env_var,
      host_env_var: host_env_var,
    ))
  }
  decoder
}

fn network_mode_decoder() -> decode.Decoder(types_runner.NetworkMode) {
  let decoder = {
    use value <- decode.then(decode.string)
    case types_runner.network_mode_from_string(value) {
      Ok(mode) -> decode.success(mode)
      Error(_) ->
        decode.failure(types_runner.NoNetwork, expected: "NetworkMode")
    }
  }
  decoder
}

fn artifact_config_decoder() -> decode.Decoder(types_runner.ArtifactConfig) {
  let decoder = {
    use include <- decode.optional_field(
      "include",
      [],
      string_list_or_single_decoder(),
    )
    use exclude <- decode.optional_field(
      "exclude",
      [],
      string_list_or_single_decoder(),
    )
    decode.success(types_runner.ArtifactConfig(
      include: include,
      exclude: exclude,
    ))
  }
  decoder
}

fn string_list_or_single_decoder() -> decode.Decoder(List(String)) {
  decode.one_of(decode.string |> decode.map(fn(value) { [value] }), or: [
    decode.list(of: decode.string),
  ])
}

pub fn interface_decoder() -> decode.Decoder(types_profile.Interface) {
  let decoder = {
    use protocol <- decode.field("protocol", decode.string)
    case protocol {
      "runner" -> runner_interface_decoder()
      "http" -> http_interface_decoder()
      _ ->
        decode.failure(interface_placeholder(), expected: "InterfaceProtocol")
    }
  }
  decoder
}

fn runner_interface_decoder() -> decode.Decoder(types_profile.Interface) {
  let decoder = {
    use capabilities <- decode.field(
      "capabilities",
      runner_capabilities_decoder(),
    )
    decode.success(types_profile.RunnerInterface(capabilities))
  }
  decoder
}

fn http_interface_decoder() -> decode.Decoder(types_profile.Interface) {
  let decoder = {
    use base_url <- decode.field("base_url", decode.string)
    use headers <- decode.optional_field(
      "headers",
      dict.new(),
      decode.dict(decode.string, decode.string),
    )
    use health_check <- decode.optional_field(
      "health_check",
      None,
      decode.optional(health_check_decoder()),
    )
    use capabilities <- decode.field(
      "capabilities",
      http_capabilities_decoder(),
    )
    decode.success(types_profile.HttpInterface(
      base_url: base_url,
      headers: headers,
      health_check: health_check,
      capabilities: capabilities,
    ))
  }
  decoder
}

fn interface_placeholder() -> types_profile.Interface {
  types_profile.RunnerInterface(dict.new())
}

fn health_check_decoder() -> decode.Decoder(types_profile.HealthCheck) {
  let decoder = {
    use path <- decode.field("path", decode.string)
    use method <- decode.field("method", http_method_decoder())
    use expect_statuses <- decode.field(
      "expect_statuses",
      decode.list(of: decode.int),
    )
    decode.success(types_profile.HealthCheck(
      path: path,
      method: method,
      expect_statuses: expect_statuses,
    ))
  }
  decoder
}

fn runner_capabilities_decoder() -> decode.Decoder(
  dict.Dict(String, types_profile.RunnerCapability),
) {
  decode.dict(decode.string, runner_capability_decoder())
}

fn http_capabilities_decoder() -> decode.Decoder(
  dict.Dict(String, types_profile.HttpCapability),
) {
  decode.dict(decode.string, http_capability_decoder())
}

fn runner_capability_decoder() -> decode.Decoder(types_profile.RunnerCapability) {
  let decoder = {
    use input_schema <- decode.optional_field(
      "input_schema",
      None,
      decode.optional(input_schema_decoder()),
    )
    use description <- decode.optional_field(
      "description",
      None,
      decode.optional(decode.string),
    )
    use streaming <- decode.optional_field("streaming", False, decode.bool)
    use limits <- decode.optional_field(
      "limits",
      None,
      decode.optional(capability_limits_decoder()),
    )
    decode.success(types_profile.RunnerCapability(
      input_schema: input_schema,
      description: description,
      streaming: streaming,
      limits: limits,
    ))
  }
  decoder
}

fn http_capability_decoder() -> decode.Decoder(types_profile.HttpCapability) {
  let decoder = {
    use path <- decode.field("path", decode.string)
    use method <- decode.field("method", http_method_decoder())
    use input_schema <- decode.optional_field(
      "input_schema",
      None,
      decode.optional(input_schema_decoder()),
    )
    use response <- decode.optional_field(
      "response",
      None,
      decode.optional(response_mapping_decoder()),
    )
    use description <- decode.optional_field(
      "description",
      None,
      decode.optional(decode.string),
    )
    use streaming <- decode.optional_field("streaming", False, decode.bool)
    use limits <- decode.optional_field(
      "limits",
      None,
      decode.optional(capability_limits_decoder()),
    )
    decode.success(types_profile.HttpCapability(
      path: path,
      method: method,
      input_schema: input_schema,
      response: response,
      description: description,
      streaming: streaming,
      limits: limits,
    ))
  }
  decoder
}

fn response_mapping_decoder() -> decode.Decoder(types_profile.ResponseMapping) {
  let decoder = {
    use text_pointer <- decode.optional_field(
      "text_pointer",
      None,
      decode.optional(decode.string),
    )
    use artifacts_pointer <- decode.optional_field(
      "artifacts_pointer",
      None,
      decode.optional(decode.string),
    )
    decode.success(types_profile.ResponseMapping(
      text_pointer: text_pointer,
      artifacts_pointer: artifacts_pointer,
    ))
  }
  decoder
}

fn capability_limits_decoder() -> decode.Decoder(types_profile.CapabilityLimits) {
  let decoder = {
    use call_timeout_ms <- decode.optional_field(
      "call_timeout_ms",
      None,
      decode.optional(decode.int),
    )
    decode.success(types_profile.CapabilityLimits(call_timeout_ms))
  }
  decoder
}

fn http_method_decoder() -> decode.Decoder(types_profile.HttpMethod) {
  let decoder = {
    use raw <- decode.then(decode.string)
    case string.lowercase(raw) {
      "get" -> decode.success(types_profile.HttpGet)
      "post" -> decode.success(types_profile.HttpPost)
      "put" -> decode.success(types_profile.HttpPut)
      "delete" -> decode.success(types_profile.HttpDelete)
      _ -> decode.failure(types_profile.HttpGet, expected: "HttpMethod")
    }
  }
  decoder
}

fn input_schema_decoder() -> decode.Decoder(types_profile.InputSchema) {
  decode.one_of(input_schema_string_decoder(), or: [
    input_schema_ref_decoder(),
    input_schema_extended_decoder(),
  ])
}

fn input_schema_string_decoder() -> decode.Decoder(types_profile.InputSchema) {
  let decoder = {
    use value <- decode.then(decode.string)
    case input_schema_from_string(value) {
      Ok(schema) -> decode.success(schema)
      Error(_) ->
        decode.failure(types_profile.SchemaChat, expected: "InputSchema")
    }
  }
  decoder
}

fn input_schema_ref_decoder() -> decode.Decoder(types_profile.InputSchema) {
  let decoder = {
    use value <- decode.field("$ref", decode.string)
    case input_schema_from_string(value) {
      Ok(schema) -> decode.success(schema)
      Error(_) ->
        decode.failure(types_profile.SchemaChat, expected: "InputSchema")
    }
  }
  decoder
}

fn input_schema_extended_decoder() -> decode.Decoder(types_profile.InputSchema) {
  let decoder = {
    use base <- decode.field("base", decode.string)
    use extra_fields <- decode.field("extra_fields", extra_field_defs_decoder())
    case base {
      "std:chat" ->
        decode.success(types_profile.SchemaChatExtended(extra_fields))
      _ ->
        decode.failure(types_profile.SchemaChat, expected: "SchemaChatExtended")
    }
  }
  decoder
}

fn input_schema_from_string(
  value: String,
) -> Result(types_profile.InputSchema, Nil) {
  case value {
    "std:chat" -> Ok(types_profile.SchemaChat)
    "std:files" -> Ok(types_profile.SchemaFiles)
    _ -> Error(Nil)
  }
}

fn extra_field_defs_decoder() -> decode.Decoder(
  dict.Dict(String, types_profile.ExtraFieldDef),
) {
  decode.dict(decode.string, extra_field_def_decoder())
}

fn extra_field_def_decoder() -> decode.Decoder(types_profile.ExtraFieldDef) {
  let decoder = {
    use type_ <- decode.field("type", extra_field_type_decoder())
    use enum_values <- decode.optional_field(
      "enum",
      None,
      decode.optional(decode.list(of: decode.string)),
    )
    use default <- decode.optional_field(
      "default",
      None,
      decode.optional(extra_field_value_decoder(type_)),
    )
    case enum_values {
      Some(values) ->
        case type_ {
          types_profile.FieldString ->
            case default {
              Some(types_core.StringVal(value)) ->
                case list.contains(values, value) {
                  True ->
                    decode.success(types_profile.ExtraFieldDef(
                      type_: type_,
                      enum_values: enum_values,
                      default: default,
                    ))
                  False ->
                    decode.failure(
                      extra_field_def_placeholder(),
                      expected: "EnumDefault",
                    )
                }
              Some(_) ->
                decode.failure(
                  extra_field_def_placeholder(),
                  expected: "EnumDefault",
                )
              None ->
                decode.success(types_profile.ExtraFieldDef(
                  type_: type_,
                  enum_values: enum_values,
                  default: default,
                ))
            }
          _ ->
            decode.failure(
              extra_field_def_placeholder(),
              expected: "EnumString",
            )
        }
      None ->
        decode.success(types_profile.ExtraFieldDef(
          type_: type_,
          enum_values: enum_values,
          default: default,
        ))
    }
  }
  decoder
}

fn extra_field_def_placeholder() -> types_profile.ExtraFieldDef {
  types_profile.ExtraFieldDef(
    type_: types_profile.FieldString,
    enum_values: None,
    default: None,
  )
}

fn extra_field_type_decoder() -> decode.Decoder(types_profile.ExtraFieldType) {
  let decoder = {
    use value <- decode.then(decode.string)
    case value {
      "string" -> decode.success(types_profile.FieldString)
      "boolean" -> decode.success(types_profile.FieldBoolean)
      "number" -> decode.success(types_profile.FieldNumber)
      "integer" -> decode.success(types_profile.FieldInteger)
      _ -> decode.failure(types_profile.FieldString, expected: "ExtraFieldType")
    }
  }
  decoder
}

fn extra_field_value_decoder(
  type_: types_profile.ExtraFieldType,
) -> decode.Decoder(types_input.InputValue) {
  case type_ {
    types_profile.FieldString ->
      decode.string |> decode.map(types_core.StringVal)
    types_profile.FieldBoolean -> decode.bool |> decode.map(types_core.BoolVal)
    types_profile.FieldNumber -> number_value_decoder()
    types_profile.FieldInteger -> decode.int |> decode.map(types_core.IntVal)
  }
}

fn number_value_decoder() -> decode.Decoder(types_core.Value) {
  let int_decoder = decode.int |> decode.map(types_core.IntVal)
  let float_decoder = decode.float |> decode.map(types_core.FloatVal)
  decode.one_of(int_decoder, or: [float_decoder])
}

fn value_type_decoder() -> decode.Decoder(types_core.ValueType) {
  let decoder = {
    use value <- decode.then(decode.string)
    case value {
      "string" -> decode.success(types_core.TypeString)
      "int" -> decode.success(types_core.TypeInt)
      "float" -> decode.success(types_core.TypeFloat)
      "bool" -> decode.success(types_core.TypeBool)
      _ -> decode.failure(types_core.TypeString, expected: "ValueType")
    }
  }
  decoder
}

fn value_decoder(
  expected: types_core.ValueType,
) -> decode.Decoder(types_core.Value) {
  case expected {
    types_core.TypeString -> decode.string |> decode.map(types_core.StringVal)
    types_core.TypeInt -> decode.int |> decode.map(types_core.IntVal)
    types_core.TypeFloat -> decode.float |> decode.map(types_core.FloatVal)
    types_core.TypeBool -> decode.bool |> decode.map(types_core.BoolVal)
    types_core.TypeList ->
      decode.list(of: decode.string) |> decode.map(types_core.ListVal)
  }
}

fn chat_messages_decoder() -> decode.Decoder(List(types_input.ChatMessage)) {
  decode.list(of: chat_message_decoder())
}

fn chat_message_decoder() -> decode.Decoder(types_input.ChatMessage) {
  let decoder = {
    use role <- decode.field("role", decode.string)
    use content <- decode.field("content", decode.string)
    decode.success(types_input.ChatMessage(role: role, content: content))
  }
  decoder
}

fn files_decoder() -> decode.Decoder(List(types_input.FileRef)) {
  decode.list(of: file_ref_decoder())
}

fn file_ref_decoder() -> decode.Decoder(types_input.FileRef) {
  let decoder = {
    use url <- decode.field("url", decode.string)
    use mime <- decode.field("mime", decode.string)
    use name <- decode.field("name", decode.string)
    use context <- decode.optional_field(
      "context",
      None,
      decode.optional(decode.string),
    )
    decode.success(types_input.FileRef(
      url: url,
      mime: mime,
      name: name,
      context: context,
    ))
  }
  decoder
}

fn decode_object(
  inputs: Dynamic,
) -> Result(dict.Dict(String, Dynamic), List(decode.DecodeError)) {
  decode.run(inputs, decode.dict(decode.string, decode.dynamic))
}

fn decode_required_field(
  fields: dict.Dict(String, Dynamic),
  key: String,
  decoder: decode.Decoder(a),
) -> Result(a, List(decode.DecodeError)) {
  case dict.get(fields, key) {
    Ok(value) -> decode.run(value, decoder)
    Error(_) -> Error([missing_field_error(key)])
  }
}

fn decode_extra_fields_from_fields(
  extra_fields: dict.Dict(String, types_profile.ExtraFieldDef),
  fields: dict.Dict(String, Dynamic),
) -> Result(dict.Dict(String, types_input.InputValue), List(decode.DecodeError)) {
  extra_fields
  |> dict.to_list
  |> list.fold(Ok(dict.new()), fn(acc, entry) {
    let #(name, def) = entry
    use resolved <- result.try(acc)
    case dict.get(fields, name) {
      Ok(value) -> {
        use decoded <- result.try(decode_extra_field_value(def, value))
        Ok(dict.insert(resolved, name, decoded))
      }
      Error(_) ->
        case def.default {
          Some(default_value) -> Ok(dict.insert(resolved, name, default_value))
          None -> Error([missing_field_error(name)])
        }
    }
  })
}

fn decode_extra_field_value(
  def: types_profile.ExtraFieldDef,
  value: Dynamic,
) -> Result(types_input.InputValue, List(decode.DecodeError)) {
  let types_profile.ExtraFieldDef(
    type_: type_,
    enum_values: enum_values,
    default: _,
  ) = def

  use decoded <- result.try(decode.run(value, extra_field_value_decoder(type_)))
  case enum_values {
    None -> Ok(decoded)
    Some(values) ->
      case decoded {
        types_core.StringVal(s) ->
          case list.contains(values, s) {
            True -> Ok(decoded)
            False -> Error([enum_value_error(s)])
          }
        _ -> Error([enum_value_error("non-string")])
      }
  }
}

fn missing_field_error(field: String) -> decode.DecodeError {
  decode.DecodeError(expected: "RequiredField", found: "Missing", path: [field])
}

fn enum_value_error(value: String) -> decode.DecodeError {
  decode.DecodeError(expected: "EnumValue", found: value, path: [])
}
