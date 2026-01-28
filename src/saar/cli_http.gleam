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
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
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
