//// CLI HTTP helpers.
////
//// Mission: support CLI client operations with base URL derivation, auth
//// headers, and profile-derived schema/parameter reporting.
////
//// Responsibilities:
//// - Build base URLs from `SaarConfig` with loopback safety.
//// - Produce Authorization headers for CLI requests.
//// - Summarize profile parameters and input schemas for display.
////
//// Non-responsibilities:
//// - Performing HTTP requests.
//// - Printing output or handling IO.
////
//// Relationships:
//// - Used by `saar.gleam` when executing CLI agent commands.
//// - Consumes `saar/types/config` and `saar/types/profile`.

import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import saar/decoders
import saar/json_pointer
import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/profile as types_profile

/// Status of a profile parameter in the local environment.
pub type ParamStatus {
  Provided
  Missing
}

/// Origin of a profile parameter.
pub type ParamSource {
  ParamSourceConfig(key: String)
  ParamSourceSecret(key: String)
  ParamSourceInit(key: String)
  ParamSourceFixed
}

/// Report line for a profile parameter.
pub type ParamReport {
  ParamReport(name: String, source: ParamSource, status: ParamStatus)
}

/// View of a capability input schema for display purposes.
pub type CapabilitySchemaView {
  CapabilitySchemaView(base: String, extra_fields: List(ExtraFieldView))
}

/// View of a schema extra field for display purposes.
pub type ExtraFieldView {
  ExtraFieldView(
    name: String,
    enum_values: Option(List(String)),
    default: Option(types_core.Value),
  )
}

/// CLI errors for interact input handling.
pub type CliError {
  InvalidInput(String)
  InvalidResponse(String)
}

/// CLI flags used to build interaction inputs.
pub type InteractFlags {
  InteractFlags(
    content: Option(String),
    extra_fields: dict.Dict(String, String),
  )
}

/// Parsed capability information from discovery.
pub type CapabilityInfo {
  CapabilityInfo(
    input_schema: types_profile.InputSchema,
    response_mode: types_profile.ResponseMode,
  )
}

/// Builds the base URL for CLI requests from configuration.
pub fn base_url_from_config(cfg: types_config.SaarConfig) -> String {
  let types_config.SaarConfig(server_host: host, server_port: port, ..) = cfg

  let effective_host = case host {
    "0.0.0.0" -> "127.0.0.1"
    _ -> host
  }

  "http://" <> effective_host <> ":" <> int.to_string(port)
}

/// Builds the Authorization header from configuration.
pub fn auth_header_from_config(
  cfg: types_config.SaarConfig,
) -> #(String, String) {
  let types_config.SaarConfig(api_key: api_key, ..) = cfg
  let token = types_core.secret_to_env_value(api_key)
  #("authorization", "Bearer " <> token)
}

/// Renders a CLI error message.
pub fn cli_error_message(err: CliError) -> String {
  case err {
    InvalidInput(message) -> message
    InvalidResponse(message) -> message
  }
}

/// Builds headers for interact requests.
pub fn interact_headers(
  cfg: types_config.SaarConfig,
  stream: Bool,
) -> dict.Dict(String, String) {
  let auth = auth_header_from_config(cfg)

  let accept = case stream {
    True -> "text/event-stream"
    False -> "application/json"
  }

  dict.new()
  |> dict.insert(auth.0, auth.1)
  |> dict.insert("accept", accept)
  |> dict.insert("content-type", "application/json")
}

/// Parses a JSON input payload for `--input`.
pub fn parse_inputs_json(raw: String) -> Result(dynamic.Dynamic, CliError) {
  json.parse(raw, decode.dynamic)
  |> result.map_error(fn(_) { InvalidInput("invalid JSON input") })
}

/// Builds the interaction request body as JSON.
pub fn build_interact_body(
  capability: String,
  inputs: dynamic.Dynamic,
  trace_id: Option(String),
) -> String {
  let fields = [
    #("capability", json.string(capability)),
    #("inputs", json_pointer.dynamic_to_json(inputs)),
  ]

  let fields = case trace_id {
    None -> fields
    Some(trace_id) ->
      list.append(fields, [
        #("context", json.object([#("trace_id", json.string(trace_id))])),
      ])
  }

  json.object(fields) |> json.to_string
}

/// Builds interaction inputs from CLI flags when no `--input` is provided.
pub fn build_inputs_from_flags(
  schema: types_profile.InputSchema,
  flags: InteractFlags,
) -> Result(dynamic.Dynamic, CliError) {
  use overrides <- result.try(build_inputs_overrides(schema, flags, True))

  case overrides {
    None -> Error(InvalidInput("missing required --content"))
    Some(value) -> Ok(value)
  }
}

/// Builds the optional overrides from CLI flags.
pub fn build_inputs_overrides(
  schema: types_profile.InputSchema,
  flags: InteractFlags,
  require_content: Bool,
) -> Result(Option(dynamic.Dynamic), CliError) {
  let InteractFlags(content: content, extra_fields: extra_fields) = flags

  let base_fields = case schema {
    types_profile.SchemaChat | types_profile.SchemaChatExtended(_) -> {
      case content {
        None -> []
        Some(text) -> [#("messages", messages_input(text))]
      }
    }

    types_profile.SchemaFiles -> []
  }

  case require_content, base_fields {
    True, [] ->
      case schema {
        types_profile.SchemaFiles ->
          Error(InvalidInput("capability requires files input"))
        _ -> Error(InvalidInput("missing required --content"))
      }

    _, _ -> {
      use extras <- result.try(extra_fields_inputs(schema, extra_fields))

      let merged = list.append(base_fields, extras)

      case merged {
        [] -> Ok(None)
        _ -> Ok(Some(dynamic_object(merged)))
      }
    }
  }
}

/// Merges input overrides into a base input object.
pub fn merge_inputs(
  base: dynamic.Dynamic,
  overrides: dynamic.Dynamic,
) -> Result(dynamic.Dynamic, CliError) {
  use base_dict <- result.try(decode_object(base))
  use override_dict <- result.try(decode_object(overrides))

  let merged =
    dict.fold(override_dict, base_dict, fn(acc, key, value) {
      dict.insert(acc, key, value)
    })

  Ok(dynamic_from_dict(merged))
}

/// Parses capability information from discovery JSON.
pub fn parse_capability_info(
  body: String,
  capability: String,
) -> Result(CapabilityInfo, CliError) {
  use value <- result.try(
    json.parse(body, decode.dynamic)
    |> result.map_error(fn(_) { InvalidResponse("invalid discovery JSON") }),
  )

  let root_decoder = {
    use caps <- decode.field(
      "capabilities",
      decode.dict(decode.string, decode.dynamic),
    )
    decode.success(caps)
  }

  use caps <- result.try(
    decode.run(value, root_decoder)
    |> result.map_error(fn(_) {
      InvalidResponse("missing capabilities in discovery")
    }),
  )

  use cap <- result.try(case dict.get(caps, capability) {
    Ok(found) -> Ok(found)
    Error(_) -> Error(InvalidResponse("capability not found in discovery"))
  })

  let cap_decoder = {
    use schema_dyn <- decode.optional_field(
      "input_schema",
      dynamic.string("std:chat"),
      decode.dynamic,
    )
    use response_mode <- decode.optional_field(
      "response_mode",
      "sync",
      decode.string,
    )
    decode.success(#(schema_dyn, response_mode))
  }

  use #(schema_dyn, response_mode_raw) <- result.try(
    decode.run(cap, cap_decoder)
    |> result.map_error(fn(_) { InvalidResponse("invalid capability schema") }),
  )

  use schema <- result.try(
    decoders.decode_input_schema(schema_dyn)
    |> result.map_error(fn(_) { InvalidResponse("invalid input_schema") }),
  )

  let response_mode =
    types_profile.response_mode_from_string(response_mode_raw)
    |> result.unwrap(types_profile.ResponseModeSync)

  Ok(CapabilityInfo(input_schema: schema, response_mode: response_mode))
}

/// Resolves parameter status for a profile against config and environment.
pub fn resolve_param_status(
  profile: types_profile.Profile,
  cfg: types_config.SaarConfig,
  env_lookup: fn(String) -> Result(String, Nil),
) -> List(ParamReport) {
  let types_profile.Profile(parameters: parameters, ..) = profile

  parameters
  |> dict.to_list
  |> list.sort(by: fn(a, b) { string.compare(a.0, b.0) })
  |> list.map(fn(pair) {
    let #(name, param) = pair
    param_report(name, param, cfg, env_lookup)
  })
}

/// Renders a `ParamReport` as a CLI line.
pub fn render_param_report(report: ParamReport) -> String {
  let ParamReport(name: name, source: source, status: status) = report
  let status_label = param_status_label(status)
  let source_label = param_source_label(source)
  "- " <> name <> " (" <> source_label <> ") -> " <> status_label
}

/// Returns the input schema view for a capability.
pub fn capability_schema(
  profile: types_profile.Profile,
  capability: String,
) -> Result(CapabilitySchemaView, Nil) {
  let types_profile.Profile(interface: interface, ..) = profile

  case capability_input_schema(interface, capability) {
    Ok(schema) -> Ok(schema_view_from_schema(schema))
    Error(_) -> Error(Nil)
  }
}

/// Renders the input schema into CLI lines.
pub fn capability_schema_lines(
  profile: types_profile.Profile,
  capability: String,
) -> Result(List(String), Nil) {
  use view <- result.try(capability_schema(profile, capability))

  let CapabilitySchemaView(base: base, extra_fields: extra_fields) = view

  let base_line = "- " <> base_schema_line(base)

  let extra_lines =
    extra_fields
    |> list.map(fn(field) { "- " <> extra_field_line(field) })

  Ok([base_line, ..extra_lines])
}

fn param_report(
  name: String,
  param: types_profile.Parameter,
  cfg: types_config.SaarConfig,
  env_lookup: fn(String) -> Result(String, Nil),
) -> ParamReport {
  case param {
    types_profile.FixedParam(_) ->
      ParamReport(name: name, source: ParamSourceFixed, status: Provided)

    types_profile.ConfigParam(key, default, _) -> {
      let status = case types_config.config_value(cfg, key) {
        Some(_) -> Provided
        None ->
          case default {
            Some(_) -> Provided
            None -> Missing
          }
      }

      ParamReport(
        name: name,
        source: ParamSourceConfig(key: key),
        status: status,
      )
    }

    types_profile.SecretParam(key, _) -> {
      let status = case env_lookup(key) {
        Ok(value) ->
          case string.is_empty(value) {
            True -> Missing
            False -> Provided
          }
        Error(_) -> Missing
      }

      ParamReport(
        name: name,
        source: ParamSourceSecret(key: key),
        status: status,
      )
    }

    types_profile.InitParam(key, default, _) -> {
      let status = case default {
        Some(_) -> Provided
        None -> Missing
      }

      ParamReport(name: name, source: ParamSourceInit(key: key), status: status)
    }
  }
}

fn param_status_label(status: ParamStatus) -> String {
  case status {
    Provided -> "OK"
    Missing -> "MISSING"
  }
}

fn param_source_label(source: ParamSource) -> String {
  case source {
    ParamSourceConfig(key: key) -> "config: " <> key
    ParamSourceSecret(key: key) -> "secret env: " <> key
    ParamSourceInit(key: key) -> "init: " <> key
    ParamSourceFixed -> "fixed"
  }
}

fn capability_input_schema(
  interface: types_profile.Interface,
  capability: String,
) -> Result(types_profile.InputSchema, Nil) {
  case interface {
    types_profile.RunnerInterface(caps) ->
      case dict.get(caps, capability) {
        Ok(cap) -> Ok(schema_or_default(cap.input_schema))
        Error(_) -> Error(Nil)
      }

    types_profile.HttpInterface(_, _, _, caps) ->
      case dict.get(caps, capability) {
        Ok(cap) -> Ok(schema_or_default(cap.input_schema))
        Error(_) -> Error(Nil)
      }
  }
}

fn schema_or_default(
  schema: Option(types_profile.InputSchema),
) -> types_profile.InputSchema {
  case schema {
    Some(value) -> value
    None -> types_profile.SchemaChat
  }
}

fn schema_view_from_schema(
  schema: types_profile.InputSchema,
) -> CapabilitySchemaView {
  case schema {
    types_profile.SchemaChat ->
      CapabilitySchemaView(base: "std:chat", extra_fields: [])

    types_profile.SchemaFiles ->
      CapabilitySchemaView(base: "std:files", extra_fields: [])

    types_profile.SchemaChatExtended(extra_fields) -> {
      let fields =
        extra_fields
        |> dict.to_list
        |> list.sort(by: fn(a, b) { string.compare(a.0, b.0) })
        |> list.map(fn(pair) {
          let #(name, def) = pair
          let types_profile.ExtraFieldDef(
            enum_values: enum_values,
            default: default,
            ..,
          ) = def
          ExtraFieldView(name: name, enum_values: enum_values, default: default)
        })

      CapabilitySchemaView(base: "std:chat", extra_fields: fields)
    }
  }
}

fn base_schema_line(base: String) -> String {
  case base {
    "std:chat" -> base <> " (requires messages)"
    "std:files" -> base <> " (requires files)"
    _ -> base
  }
}

fn extra_field_line(field: ExtraFieldView) -> String {
  let ExtraFieldView(name: name, enum_values: enum_values, default: default) =
    field

  let parts =
    ["optional"]
    |> add_enum_part(enum_values)
    |> add_default_part(default)

  "extra_fields: " <> name <> " (" <> string.join(parts, ", ") <> ")"
}

fn add_enum_part(
  parts: List(String),
  enum_values: Option(List(String)),
) -> List(String) {
  case enum_values {
    None -> parts
    Some(values) -> list.append(parts, ["enum: " <> string.join(values, "|")])
  }
}

fn add_default_part(
  parts: List(String),
  default: Option(types_core.Value),
) -> List(String) {
  case default {
    None -> parts
    Some(value) ->
      list.append(parts, ["default: " <> types_core.value_to_string(value)])
  }
}

fn messages_input(content: String) -> dynamic.Dynamic {
  dynamic.list([
    dynamic.properties([
      #(dynamic.string("role"), dynamic.string("user")),
      #(dynamic.string("content"), dynamic.string(content)),
    ]),
  ])
}

fn extra_fields_inputs(
  schema: types_profile.InputSchema,
  extra_fields: dict.Dict(String, String),
) -> Result(List(#(String, dynamic.Dynamic)), CliError) {
  case schema {
    types_profile.SchemaChatExtended(defs) ->
      dict.fold(extra_fields, Ok([]), fn(acc, key, raw) {
        use acc <- result.try(acc)

        case dict.get(defs, key) {
          Error(_) -> Ok(acc)
          Ok(def) ->
            parse_extra_field_value(def, raw)
            |> result.map(fn(value) { [#(key, value), ..acc] })
        }
      })
      |> result.map(list.reverse)

    _ -> Ok([])
  }
}

fn parse_extra_field_value(
  def: types_profile.ExtraFieldDef,
  raw: String,
) -> Result(dynamic.Dynamic, CliError) {
  let types_profile.ExtraFieldDef(type_: type_, ..) = def

  case type_ {
    types_profile.FieldString -> Ok(dynamic.string(raw))

    types_profile.FieldBoolean ->
      case string.lowercase(raw) {
        "true" -> Ok(dynamic.bool(True))
        "false" -> Ok(dynamic.bool(False))
        _ -> Error(InvalidInput("invalid boolean for extra field"))
      }

    types_profile.FieldInteger ->
      int.parse(raw)
      |> result.map(dynamic.int)
      |> result.map_error(fn(_) {
        InvalidInput("invalid integer for extra field")
      })

    types_profile.FieldNumber ->
      float.parse(raw)
      |> result.map(dynamic.float)
      |> result.map_error(fn(_) {
        InvalidInput("invalid number for extra field")
      })
  }
}

fn dynamic_object(fields: List(#(String, dynamic.Dynamic))) -> dynamic.Dynamic {
  fields
  |> list.map(fn(pair) { #(dynamic.string(pair.0), pair.1) })
  |> dynamic.properties
}

fn decode_object(
  value: dynamic.Dynamic,
) -> Result(dict.Dict(String, dynamic.Dynamic), CliError) {
  decode.run(value, decode.dict(decode.string, decode.dynamic))
  |> result.map_error(fn(_) { InvalidInput("inputs must be an object") })
}

fn dynamic_from_dict(
  values: dict.Dict(String, dynamic.Dynamic),
) -> dynamic.Dynamic {
  values
  |> dict.to_list
  |> list.map(fn(pair) { #(dynamic.string(pair.0), pair.1) })
  |> dynamic.properties
}
