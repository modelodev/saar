//// Parameter resolution for runner profiles.
////
//// Mission: resolve profile parameters (`types_profile.Parameter`) into concrete
//// values (`types.ResolvedParams`) using config values, init params, and
//// environment lookups.
////
//// Responsibilities:
//// - Resolve each parameter source (fixed/config/init/secret) at the boundary.
//// - Enforce declared value types and report mismatches.
//// - Accumulate per-parameter errors rather than failing fast.
////
//// Non-responsibilities:
//// - Fetching config values; callers provide `config_values`.
//// - Managing secret storage; callers provide `env_lookup`.
////
//// Relationships:
//// - Consumes `types_profile.Parameter` from profile decoding.
//// - Produces `types.ResolvedParams` for interpolation/execution.

import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sad/types
import sad/types/core as types_core
import sad/types/profile as types_profile

/// Errors that can occur while resolving parameters.
pub type ParamResolutionError {
  /// A config-backed parameter was missing from `config_values` and had no default.
  MissingConfig(param_name: String, config_key: String)
  /// A secret-backed parameter was missing from the environment and has no default.
  MissingSecret(param_name: String, env_key: String)
  /// An init-backed parameter was missing from `init_params` and had no default.
  MissingInitParam(param_name: String, init_key: String)
  /// A parameter value did not match its declared `ValueType`.
  TypeMismatch(
    param_name: String,
    expected: types_core.ValueType,
    got: types_core.ValueType,
  )
}

/// Resolves all parameters to concrete values.
///
/// The function resolves parameters in a deterministic order (by name) and
/// accumulates all resolution errors.
///
/// Example:
/// ```gleam
/// import gleam/dict
/// import sad/params
/// import sad/types/core as types_core
/// import sad/types/profile as types_profile
///
/// let parameters =
///   dict.from_list([
///     #("model", types_profile.ConfigParam("model", None, types_profile.ParamString)),
///     #("api_key", types_profile.SecretParam("API_KEY", types_profile.ParamString)),
///   ])
///
/// let config_values = dict.from_list([#("model", types_core.StringVal("gpt-4"))])
/// let env_lookup = fn(key) { Error(Nil) }
///
/// params.resolve_params(parameters, config_values, env_lookup, dict.new())
/// ```
pub fn resolve_params(
  parameters: dict.Dict(String, types_profile.Parameter),
  config_values: dict.Dict(String, types_core.Value),
  env_lookup: fn(String) -> Result(String, Nil),
  init_params: dict.Dict(String, types_core.Value),
) -> Result(types.ResolvedParams, List(ParamResolutionError)) {
  let entries =
    parameters
    |> dict.to_list
    |> list.sort(by: fn(a, b) { string.compare(a.0, b.0) })

  let #(resolved, errors) =
    list.fold(entries, #(dict.new(), []), fn(acc, entry) {
      let #(current, errs) = acc
      let #(param_name, param) = entry

      case
        resolve_param(
          param_name: param_name,
          param: param,
          config_values: config_values,
          env_lookup: env_lookup,
          init_params: init_params,
        )
      {
        Ok(value) -> #(dict.insert(current, param_name, value), errs)
        Error(err) -> #(current, [err, ..errs])
      }
    })

  case errors {
    [] -> Ok(resolved)
    _ -> Error(list.reverse(errors))
  }
}

fn resolve_param(
  param_name param_name: String,
  param param: types_profile.Parameter,
  config_values config_values: dict.Dict(String, types_core.Value),
  env_lookup env_lookup: fn(String) -> Result(String, Nil),
  init_params init_params: dict.Dict(String, types_core.Value),
) -> Result(types.ResolvedValue, ParamResolutionError) {
  case param {
    types_profile.FixedParam(value) -> Ok(types.NormalValue(value))

    types_profile.ConfigParam(key, default, expected_type) ->
      resolve_from_dict(
        param_name: param_name,
        source_key: key,
        expected_type: expected_type,
        values: config_values,
        default: default,
        on_missing: fn() { MissingConfig(param_name, key) },
      )

    types_profile.InitParam(key, default, expected_type) ->
      resolve_from_dict(
        param_name: param_name,
        source_key: key,
        expected_type: expected_type,
        values: init_params,
        default: default,
        on_missing: fn() { MissingInitParam(param_name, key) },
      )

    types_profile.SecretParam(key, expected_type) ->
      resolve_secret_param(param_name, key, expected_type, env_lookup)
  }
}

fn resolve_secret_param(
  param_name: String,
  key: String,
  expected_type: types_profile.ParamType,
  env_lookup: fn(String) -> Result(String, Nil),
) -> Result(types.ResolvedValue, ParamResolutionError) {
  use raw <- result.try(
    env_lookup(key)
    |> result.map_error(fn(_) { MissingSecret(param_name, key) }),
  )

  use _ <- result.try(validate_secret_literal(
    param_name: param_name,
    env_key: key,
    expected: expected_type,
    raw: raw,
  ))

  Ok(types.SecretVal(types_core.secret_value(raw)))
}

fn resolve_from_dict(
  param_name param_name: String,
  source_key source_key: String,
  expected_type expected_type: types_profile.ParamType,
  values values: dict.Dict(String, types_core.Value),
  default default: Option(types_core.Value),
  on_missing on_missing: fn() -> ParamResolutionError,
) -> Result(types.ResolvedValue, ParamResolutionError) {
  let expected_value_type =
    types_profile.param_type_to_value_type(expected_type)

  let validate = fn(value: types_core.Value) {
    use checked <- result.try(ensure_type(
      param_name,
      expected_value_type,
      value,
    ))
    Ok(types.NormalValue(checked))
  }

  case dict.get(values, source_key) {
    Ok(value) -> validate(value)

    Error(_) ->
      case default {
        Some(value) -> validate(value)
        None -> Error(on_missing())
      }
  }
}

fn ensure_type(
  param_name: String,
  expected: types_core.ValueType,
  value: types_core.Value,
) -> Result(types_core.Value, ParamResolutionError) {
  let got = types_core.value_type(value)
  case got == expected {
    True -> Ok(value)
    False -> Error(TypeMismatch(param_name, expected, got))
  }
}

fn validate_secret_literal(
  param_name param_name: String,
  env_key _env_key: String,
  expected expected: types_profile.ParamType,
  raw raw: String,
) -> Result(Nil, ParamResolutionError) {
  let expected_value_type = types_profile.param_type_to_value_type(expected)

  let invalid = fn() {
    TypeMismatch(
      param_name: param_name,
      expected: expected_value_type,
      got: types_core.TypeString,
    )
  }

  case expected {
    types_profile.ParamString -> Ok(Nil)

    types_profile.ParamInt ->
      case int.parse(raw) {
        Ok(_) -> Ok(Nil)
        Error(_) -> Error(invalid())
      }

    types_profile.ParamFloat ->
      case float.parse(raw) {
        Ok(_) -> Ok(Nil)
        Error(_) -> Error(invalid())
      }

    types_profile.ParamBool ->
      case string.lowercase(raw) {
        "true" | "false" -> Ok(Nil)
        _ -> Error(invalid())
      }
  }
}
