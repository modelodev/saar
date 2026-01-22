//// Decoders for user-provided dynamic inputs.
////
//// Mission: decode `gleam/dynamic.Dynamic` values into SAAR's strongly-typed
//// domain models (profiles, runners, interfaces, inputs).
////
//// Responsibilities:
//// - Provide stable public entrypoints that return `Result(_, List(DecodeError))`.
//// - Enforce domain constraints at the decoding boundary (e.g. enum defaults).
////
//// Non-responsibilities:
//// - Executing runners or applying business logic beyond decoding/validation.
//// - Performing I/O.
////
//// Relationships:
//// - Produces values from `saar/types/*`.
//// - Uses `gleam/dynamic/decode` for composable decoders.

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import saar/json_pointer
import saar/types/core as types_core
import saar/types/enums as types_enums
import saar/types/input as types_input
import saar/types/profile as types_profile
import saar/types/runner as types_runner
import saar/validation/params as param_validation

/// Attempts to run a decoder and returns whether it succeeded.
fn can_decode(value: Dynamic, decoder: decode.Decoder(a)) -> Bool {
  case decode.run(value, decoder) {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Describes the "shape" of a dynamic value.
///
/// This is intended for error messages at decoding boundaries.
///
/// Example:
/// ```gleam
/// import gleam/dynamic
/// import saar/decoders
///
/// decoders.describe_dynamic_type(dynamic.int(1))
/// // -> "number"
/// ```
pub fn describe_dynamic_type(value: Dynamic) -> String {
  case
    can_decode(value, decode.string),
    can_decode(value, decode.bool),
    can_decode(value, decode.int),
    can_decode(value, decode.float),
    can_decode(value, decode.list(of: decode.dynamic)),
    can_decode(value, decode.dict(decode.string, decode.dynamic))
  {
    True, _, _, _, _, _ -> "string"
    _, True, _, _, _, _ -> "bool"
    _, _, True, _, _, _ -> "number"
    _, _, _, True, _, _ -> "number"
    _, _, _, _, True, _ -> "array"
    _, _, _, _, _, True -> "object"
    _, _, _, _, _, _ -> "unknown"
  }
}

/// Decodes a scalar value from dynamic input.
///
/// Supported shapes: string, int, float, bool.
pub fn decode_scalar_value(value: Dynamic) -> Result(types_core.Value, Nil) {
  case
    can_decode(value, decode.string),
    can_decode(value, decode.int),
    can_decode(value, decode.float),
    can_decode(value, decode.bool)
  {
    True, _, _, _ ->
      decode.run(value, decode.string)
      |> result.map(types_core.StringVal)
      |> result.map_error(fn(_) { Nil })

    _, True, _, _ ->
      decode.run(value, decode.int)
      |> result.map(types_core.IntVal)
      |> result.map_error(fn(_) { Nil })

    _, _, True, _ ->
      decode.run(value, decode.float)
      |> result.map(types_core.FloatVal)
      |> result.map_error(fn(_) { Nil })

    _, _, _, True ->
      decode.run(value, decode.bool)
      |> result.map(types_core.BoolVal)
      |> result.map_error(fn(_) { Nil })

    _, _, _, _ -> Error(Nil)
  }
}

/// Decodes a profile definition from dynamic input.
///
/// Example:
/// ```gleam
/// import gleam/dynamic/decode
/// import gleam/json
/// import saar/decoders
///
/// let payload = "{\"meta\":{\"id\":\"x\",\"lifecycle\":\"transient\",\"description\":\"d\"},\"parameters\":{},\"runner\":{\"type\":\"echo\",\"tool_config\":{\"script\":\"echo.py\"}},\"interface\":{\"protocol\":\"runner\",\"capabilities\":{}}}"
/// let assert Ok(value) = json.parse(payload, decode.dynamic)
/// decoders.decode_profile(value)
/// ```
pub fn decode_profile(
  value: Dynamic,
) -> Result(types_profile.Profile, List(decode.DecodeError)) {
  decode.run(value, profile_decoder())
}

/// Decodes a runner definition from dynamic input.
///
/// Example:
/// ```gleam
/// import gleam/dynamic/decode
/// import gleam/json
/// import saar/decoders
///
/// let payload = "{\"type\":\"echo\",\"tool_config\":{\"script\":\"echo.py\"}}"
/// let assert Ok(value) = json.parse(payload, decode.dynamic)
/// decoders.decode_runner(value)
/// ```
pub fn decode_runner(
  value: Dynamic,
) -> Result(types_runner.Runner, List(decode.DecodeError)) {
  decode.run(value, runner_decoder())
}

/// Decodes an interface definition from dynamic input.
///
/// Example:
/// ```gleam
/// import gleam/dynamic/decode
/// import gleam/json
/// import saar/decoders
///
/// let payload = "{\"protocol\":\"runner\",\"capabilities\":{}}"
/// let assert Ok(value) = json.parse(payload, decode.dynamic)
/// decoders.decode_interface(value)
/// ```
pub fn decode_interface(
  value: Dynamic,
) -> Result(types_profile.Interface, List(decode.DecodeError)) {
  decode.run(value, interface_decoder())
}

/// Decodes runner capabilities from dynamic input.
///
/// Example:
/// ```gleam
/// import gleam/dynamic/decode
/// import gleam/json
/// import saar/decoders
///
/// let payload = "{\"echo\":{\"input_schema\":\"std:chat\",\"streaming\":false}}"
/// let assert Ok(value) = json.parse(payload, decode.dynamic)
/// decoders.decode_capabilities(value)
/// ```
pub fn decode_capabilities(
  value: Dynamic,
) -> Result(
  dict.Dict(String, types_profile.RunnerCapability),
  List(decode.DecodeError),
) {
  decode.run(value, runner_capabilities_decoder())
}

/// Decodes an input schema from dynamic input.
///
/// Example:
/// ```gleam
/// import gleam/dynamic/decode
/// import gleam/json
/// import saar/decoders
///
/// let assert Ok(value) = json.parse("\"std:chat\"", decode.dynamic)
/// decoders.decode_input_schema(value)
/// ```
pub fn decode_input_schema(
  value: Dynamic,
) -> Result(types_profile.InputSchema, List(decode.DecodeError)) {
  decode.run(value, input_schema_decoder())
}

/// Decodes an instance id from dynamic input.
///
/// Example:
/// ```gleam
/// import gleam/dynamic
/// import saar/decoders
///
/// decoders.decode_instance_id(dynamic.string("inst-1"))
/// ```
pub fn decode_instance_id(
  value: Dynamic,
) -> Result(types_core.InstanceId, List(decode.DecodeError)) {
  decode.run(value, instance_id_decoder())
}

/// Decodes a network mode from dynamic input.
///
/// Example:
/// ```gleam
/// import gleam/dynamic
/// import saar/decoders
///
/// decoders.decode_network_mode(dynamic.string("managed_port"))
/// ```
pub fn decode_network_mode(
  value: Dynamic,
) -> Result(types_runner.NetworkMode, List(decode.DecodeError)) {
  decode.run(value, network_mode_decoder())
}

/// Decodes the standard chat payload.
///
/// Example:
/// ```gleam
/// import gleam/dynamic/decode
/// import gleam/json
/// import gleam/dict
/// import saar/decoders
///
/// let payload = "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
/// let assert Ok(inputs) = json.parse(payload, decode.dynamic)
/// decoders.decode_payload_std_chat(inputs, dict.new())
/// ```
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

/// Decodes the standard files payload.
///
/// Example:
/// ```gleam
/// import gleam/dynamic/decode
/// import gleam/json
/// import saar/decoders
///
/// let payload = "{\"files\":[{\"name\":\"doc.txt\",\"url\":\"https://example.com/doc.txt\",\"mime\":\"text/plain\"}]}"
/// let assert Ok(inputs) = json.parse(payload, decode.dynamic)
/// decoders.decode_payload_std_files(inputs)
/// ```
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

/// Decodes a payload that contains both chat messages and file references.
///
/// Example:
/// ```gleam
/// import gleam/dynamic/decode
/// import gleam/json
/// import gleam/dict
/// import saar/decoders
///
/// let payload = "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"files\":[{\"name\":\"doc.txt\",\"url\":\"https://example.com/doc.txt\",\"mime\":\"text/plain\"}]}"
/// let assert Ok(inputs) = json.parse(payload, decode.dynamic)
/// decoders.decode_payload_mixed(inputs, dict.new())
/// ```
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

/// Decodes the configured extra fields from a payload.
///
/// This is useful for interfaces that need extra, schema-defined inputs.
///
/// Example:
/// ```gleam
/// import gleam/dict
/// import gleam/dynamic/decode
/// import gleam/json
/// import gleam/option.{None, Some}
/// import saar/decoders
/// import saar/types/profile as types_profile
///
/// let defs =
///   dict.from_list([
///     #(
///       "tone",
///       types_profile.ExtraFieldDef(
///         type_: types_profile.FieldString,
///         enum_values: Some(["formal", "casual"]),
///         default: None,
///       ),
///     ),
///   ])
///
/// let payload = "{\"tone\":\"formal\"}"
/// let assert Ok(inputs) = json.parse(payload, decode.dynamic)
/// decoders.decode_extra_fields(defs, inputs)
/// ```
pub fn decode_extra_fields(
  extra_fields: dict.Dict(String, types_profile.ExtraFieldDef),
  inputs: Dynamic,
) -> Result(dict.Dict(String, types_input.InputValue), List(decode.DecodeError)) {
  use fields <- result.try(decode_object(inputs))
  decode_extra_fields_from_fields(extra_fields, fields)
}

/// Returns a decoder for `types_profile.Profile`.
///
/// This is typically used when parsing JSON profiles from disk.
///
/// Example:
/// ```gleam
/// import gleam/json
/// import saar/decoders
///
/// let assert Ok(profile) =
///   json.parse("{\"meta\":{\"id\":\"x\",\"lifecycle\":\"transient\",\"description\":\"d\"},\"parameters\":{},\"runner\":{\"type\":\"echo\",\"tool_config\":{\"script\":\"echo.py\"}},\"interface\":{\"protocol\":\"runner\",\"capabilities\":{}}}", decoders.profile_decoder())
/// profile
/// ```
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

fn instance_id_decoder() -> decode.Decoder(types_core.InstanceId) {
  let assert Ok(placeholder) = types_core.instance_id("instance-1")

  let decoder = {
    use raw <- decode.then(decode.string)
    case types_core.instance_id(raw) {
      Ok(id) -> decode.success(id)
      Error(err) ->
        decode.failure(
          placeholder,
          expected: "InstanceId("
            <> types_core.instance_id_error_to_string(err)
            <> ")",
        )
    }
  }

  decoder
}

fn fixed_param_decoder() -> decode.Decoder(types_profile.Parameter) {
  let decoder = {
    use expected <- decode.field("type", param_validation.param_type_decoder())
    use value <- decode.field(
      "value",
      param_validation.param_value_decoder(expected),
    )
    decode.success(types_profile.FixedParam(value))
  }
  decoder
}

fn config_param_decoder() -> decode.Decoder(types_profile.Parameter) {
  let decoder = {
    use key <- decode.field("key", decode.string)
    use expected <- decode.field("type", param_validation.param_type_decoder())
    use default <- decode.optional_field(
      "default",
      None,
      decode.optional(param_validation.param_value_decoder(expected)),
    )
    decode.success(types_profile.ConfigParam(key, default, expected))
  }
  decoder
}

fn secret_param_decoder() -> decode.Decoder(types_profile.Parameter) {
  let decoder = {
    use key <- decode.field("key", decode.string)
    use expected <- decode.field("type", param_validation.param_type_decoder())
    use default <- decode.optional_field(
      "default",
      None,
      decode.optional(param_validation.param_value_decoder(expected)),
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
    use expected <- decode.field("type", param_validation.param_type_decoder())
    use default <- decode.optional_field(
      "default",
      None,
      decode.optional(param_validation.param_value_decoder(expected)),
    )
    decode.success(types_profile.InitParam(key, default, expected))
  }
  decoder
}

fn parameter_placeholder() -> types_profile.Parameter {
  types_profile.FixedParam(types_core.StringVal(""))
}

/// Returns a decoder for `types_runner.Runner`.
///
/// Example:
/// ```gleam
/// import gleam/json
/// import saar/decoders
///
/// let assert Ok(runner) =
///   json.parse("{\"type\":\"echo\",\"tool_config\":{\"script\":\"echo.py\"}}", decoders.runner_decoder())
/// runner
/// ```
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
      exec_path: option.None,
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
      types_runner.NoNetworkMode,
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
    decode.success(case mode {
      types_runner.ManagedPortMode ->
        types_runner.ManagedPort(
          host_env_var: host_env_var,
          port_env_var: port_env_var,
        )
      types_runner.NoNetworkMode -> types_runner.NoNetwork
    })
  }
  decoder
}

fn network_mode_decoder() -> decode.Decoder(types_runner.NetworkMode) {
  let decoder = {
    use value <- decode.then(decode.string)
    case types_runner.network_mode_from_string(value) {
      Ok(mode) -> decode.success(mode)
      Error(_) ->
        decode.failure(types_runner.NoNetworkMode, expected: "NetworkMode")
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

/// Returns a decoder for `types_profile.Interface`.
///
/// Example:
/// ```gleam
/// import gleam/json
/// import saar/decoders
///
/// let assert Ok(interface) =
///   json.parse("{\"protocol\":\"runner\",\"capabilities\":{}}", decoders.interface_decoder())
/// interface
/// ```
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
    use response_mode <- decode.optional_field(
      "response_mode",
      types_profile.ResponseModeSync,
      response_mode_decoder(),
    )
    use limits <- decode.optional_field(
      "limits",
      None,
      decode.optional(capability_limits_decoder()),
    )
    use files <- decode.optional_field(
      "files",
      None,
      decode.optional(files_semantics_decoder()),
    )
    case validate_response_mode(streaming, response_mode) {
      Ok(_) ->
        decode.success(types_profile.RunnerCapability(
          input_schema: input_schema,
          description: description,
          streaming: streaming,
          response_mode: response_mode,
          limits: limits,
          files: files,
        ))

      Error(expected) ->
        decode.failure(runner_capability_placeholder(), expected: expected)
    }
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
    use body <- decode.optional_field(
      "body",
      None,
      decode.optional(http_body_decoder()),
    )
    use response <- decode.optional_field(
      "response",
      None,
      decode.optional(response_config_decoder()),
    )
    use description <- decode.optional_field(
      "description",
      None,
      decode.optional(decode.string),
    )
    use streaming <- decode.optional_field("streaming", False, decode.bool)
    use response_mode <- decode.optional_field(
      "response_mode",
      types_profile.ResponseModeSync,
      response_mode_decoder(),
    )
    use limits <- decode.optional_field(
      "limits",
      None,
      decode.optional(capability_limits_decoder()),
    )
    use files <- decode.optional_field(
      "files",
      None,
      decode.optional(files_semantics_decoder()),
    )
    case validate_response_mode(streaming, response_mode) {
      Ok(_) ->
        decode.success(types_profile.HttpCapability(
          path: path,
          method: method,
          input_schema: input_schema,
          body: body,
          response: response,
          description: description,
          streaming: streaming,
          response_mode: response_mode,
          limits: limits,
          files: files,
        ))

      Error(expected) ->
        decode.failure(http_capability_placeholder(), expected: expected)
    }
  }
  decoder
}

fn response_mode_decoder() -> decode.Decoder(types_profile.ResponseMode) {
  let decoder = {
    use raw <- decode.then(decode.string)
    case types_profile.response_mode_from_string(raw) {
      Ok(mode) -> decode.success(mode)
      Error(_) ->
        decode.failure(types_profile.ResponseModeSync, expected: "ResponseMode")
    }
  }
  decoder
}

fn validate_response_mode(
  streaming: Bool,
  response_mode: types_profile.ResponseMode,
) -> Result(Nil, String) {
  case response_mode {
    types_profile.ResponseModeStream ->
      case streaming {
        True -> Ok(Nil)
        False -> Error("ResponseModeStreamRequiresStreaming")
      }

    types_profile.ResponseModeDeferred ->
      case streaming {
        True -> Error("ResponseModeDeferredRequiresStreamingFalse")
        False -> Ok(Nil)
      }

    types_profile.ResponseModeSync -> Ok(Nil)
  }
}

fn runner_capability_placeholder() -> types_profile.RunnerCapability {
  types_profile.RunnerCapability(
    input_schema: None,
    description: None,
    streaming: False,
    response_mode: types_profile.ResponseModeSync,
    limits: None,
    files: None,
  )
}

fn http_capability_placeholder() -> types_profile.HttpCapability {
  types_profile.HttpCapability(
    path: "/",
    method: types_profile.HttpPost,
    input_schema: None,
    body: None,
    response: None,
    description: None,
    streaming: False,
    response_mode: types_profile.ResponseModeSync,
    limits: None,
    files: None,
  )
}

fn response_config_decoder() -> decode.Decoder(types_profile.ResponseConfig) {
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
    use capture <- decode.optional_field(
      "capture",
      dict.new(),
      decode.dict(decode.string, decode.string),
    )
    let mapping = case text_pointer, artifacts_pointer {
      None, None -> types_profile.Default
      Some(text), None -> types_profile.Text(text)
      None, Some(artifacts) -> types_profile.Artifacts(artifacts)
      Some(text), Some(artifacts) -> types_profile.Both(text, artifacts)
    }
    decode.success(types_profile.ResponseConfig(
      mapping: mapping,
      capture: capture,
    ))
  }
  decoder
}

fn http_body_decoder() -> decode.Decoder(types_profile.HttpRequestBody) {
  let decoder = {
    use kind <- decode.field("type", decode.string)
    case kind {
      "json" -> http_body_json_decoder()
      "multipart" -> http_body_multipart_decoder()
      _ -> decode.failure(http_body_placeholder(), expected: "HttpBodyType")
    }
  }
  decoder
}

fn http_body_json_decoder() -> decode.Decoder(types_profile.HttpRequestBody) {
  let decoder = {
    use template <- decode.field("template", decode.dynamic)
    decode.success(
      types_profile.JsonBody(json_pointer.dynamic_to_json(template)),
    )
  }
  decoder
}

fn http_body_multipart_decoder() -> decode.Decoder(
  types_profile.HttpRequestBody,
) {
  let decoder = {
    use fields <- decode.optional_field(
      "fields",
      dict.new(),
      decode.dict(decode.string, decode.string),
    )
    use files <- decode.field(
      "files",
      decode.list(of: multipart_file_decoder()),
    )
    decode.success(types_profile.MultipartBody(fields: fields, files: files))
  }
  decoder
}

fn multipart_file_decoder() -> decode.Decoder(types_profile.MultipartFilePart) {
  let decoder = {
    use field <- decode.field("field", decode.string)
    use source_pointer <- decode.field("source_pointer", decode.string)
    decode.success(types_profile.MultipartFilePart(
      field: field,
      source_pointer: source_pointer,
    ))
  }
  decoder
}

fn http_body_placeholder() -> types_profile.HttpRequestBody {
  types_profile.JsonBody(json.null())
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

fn files_semantics_decoder() -> decode.Decoder(types_profile.FilesSemantics) {
  let decoder = {
    use accepts <- decode.field("accepts", decode.bool)
    use max_files <- decode.field("max_files", decode.int)
    use ingest_effect <- decode.optional_field(
      "ingest_effect",
      None,
      decode.optional(ingest_effect_decoder()),
    )
    case validate_files_semantics(accepts, max_files, ingest_effect) {
      Ok(_) ->
        decode.success(types_profile.FilesSemantics(
          accepts: accepts,
          max_files: max_files,
          ingest_effect: ingest_effect,
        ))

      Error(expected) ->
        decode.failure(files_semantics_placeholder(), expected: expected)
    }
  }
  decoder
}

fn ingest_effect_decoder() -> decode.Decoder(types_profile.IngestEffect) {
  let decoder = {
    use raw <- decode.then(decode.string)
    case types_profile.ingest_effect_from_string(raw) {
      Ok(effect) -> decode.success(effect)
      Error(_) ->
        decode.failure(types_profile.IngestImmediate, expected: "IngestEffect")
    }
  }
  decoder
}

fn validate_files_semantics(
  accepts: Bool,
  max_files: Int,
  ingest_effect: Option(types_profile.IngestEffect),
) -> Result(Nil, String) {
  case max_files < 0 {
    True -> Error("FilesMaxFilesNonNegative")
    False ->
      case accepts, max_files {
        False, value if value != 0 -> Error("FilesAcceptsFalseRequiresZero")
        True, value if value < 1 -> Error("FilesAcceptsTrueRequiresPositive")
        _, _ ->
          case accepts, ingest_effect {
            False, Some(_) -> Error("FilesIngestEffectRequiresAcceptsTrue")
            _, _ -> Ok(Nil)
          }
      }
  }
}

fn files_semantics_placeholder() -> types_profile.FilesSemantics {
  types_profile.FilesSemantics(
    accepts: False,
    max_files: 0,
    ingest_effect: None,
  )
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

    validate_extra_field_def(type_, enum_values, default)
  }
  decoder
}

fn validate_extra_field_def(
  type_: types_profile.ExtraFieldType,
  enum_values: Option(List(String)),
  default: Option(types_input.InputValue),
) -> decode.Decoder(types_profile.ExtraFieldDef) {
  case enum_values {
    None -> decode.success(extra_field_def(type_, enum_values, default))
    Some(values) -> validate_string_enum(type_, values, enum_values, default)
  }
}

fn validate_string_enum(
  type_: types_profile.ExtraFieldType,
  values: List(String),
  enum_values: Option(List(String)),
  default: Option(types_input.InputValue),
) -> decode.Decoder(types_profile.ExtraFieldDef) {
  case type_ {
    types_profile.FieldString ->
      validate_enum_default(type_, values, enum_values, default)

    _ -> decode.failure(extra_field_def_placeholder(), expected: "EnumString")
  }
}

fn validate_enum_default(
  type_: types_profile.ExtraFieldType,
  values: List(String),
  enum_values: Option(List(String)),
  default: Option(types_input.InputValue),
) -> decode.Decoder(types_profile.ExtraFieldDef) {
  case default {
    None -> decode.success(extra_field_def(type_, enum_values, default))

    Some(types_core.StringVal(value)) ->
      case list.contains(values, value) {
        True -> decode.success(extra_field_def(type_, enum_values, default))
        False ->
          decode.failure(extra_field_def_placeholder(), expected: "EnumDefault")
      }

    Some(_) ->
      decode.failure(extra_field_def_placeholder(), expected: "EnumDefault")
  }
}

fn extra_field_def(
  type_: types_profile.ExtraFieldType,
  enum_values: Option(List(String)),
  default: Option(types_input.InputValue),
) -> types_profile.ExtraFieldDef {
  types_profile.ExtraFieldDef(
    type_: type_,
    enum_values: enum_values,
    default: default,
  )
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
  let types_profile.ExtraFieldDef(type_: type_, enum_values: enum_values, ..) =
    def

  use decoded <- result.try(decode.run(value, extra_field_value_decoder(type_)))

  case enum_values, decoded {
    None, _ -> Ok(decoded)

    Some(values), types_core.StringVal(s) ->
      case list.contains(values, s) {
        True -> Ok(decoded)
        False -> Error([enum_value_error(s)])
      }

    Some(_), _ -> Error([enum_value_error("non-string")])
  }
}

fn missing_field_error(field: String) -> decode.DecodeError {
  decode.DecodeError(expected: "RequiredField", found: "Missing", path: [field])
}

fn enum_value_error(value: String) -> decode.DecodeError {
  decode.DecodeError(expected: "EnumValue", found: value, path: [])
}
