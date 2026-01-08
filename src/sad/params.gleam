import gleam/dict as dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sad/types as types
import sad/types/core as types_core
import sad/types/profile as types_profile

pub type ParamResolutionError {
  MissingConfig(param_name: String, config_key: String)
  MissingSecret(param_name: String, env_key: String)
  MissingInitParam(param_name: String, init_key: String)
  TypeMismatch(
    param_name: String,
    expected: types_core.ValueType,
    got: types_core.ValueType,
  )
}

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

      case resolve_param(
        param_name: param_name,
        param: param,
        config_values: config_values,
        env_lookup: env_lookup,
        init_params: init_params,
      ) {
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
      case env_lookup(key) {
        Ok(raw) ->
          case parse_env_value(param_name, expected_type, raw) {
            Ok(_) -> Ok(types.SecretVal(types_core.secret_value(raw)))
            Error(err) -> Error(err)
          }
        Error(_) -> Error(MissingSecret(param_name, key))
      }
  }
}

fn resolve_from_dict(
  param_name param_name: String,
  source_key source_key: String,
  expected_type expected_type: types_core.ValueType,
  values values: dict.Dict(String, types_core.Value),
  default default: Option(types_core.Value),
  on_missing on_missing: fn() -> ParamResolutionError,
) -> Result(types.ResolvedValue, ParamResolutionError) {
  case dict.get(values, source_key) {
    Ok(value) -> {
      use checked <- result.try(ensure_type(param_name, expected_type, value))
      Ok(types.NormalValue(checked))
    }
    Error(_) ->
      case default {
        Some(value) -> {
          use checked <- result.try(ensure_type(param_name, expected_type, value))
          Ok(types.NormalValue(checked))
        }
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

fn parse_env_value(
  param_name: String,
  expected: types_core.ValueType,
  raw: String,
) -> Result(types_core.Value, ParamResolutionError) {
  case expected {
    types_core.TypeString -> Ok(types_core.StringVal(raw))
    types_core.TypeInt ->
      case int.parse(raw) {
        Ok(value) -> Ok(types_core.IntVal(value))
        Error(_) ->
          Error(TypeMismatch(param_name, expected, types_core.TypeString))
      }
    types_core.TypeFloat ->
      case float.parse(raw) {
        Ok(value) -> Ok(types_core.FloatVal(value))
        Error(_) ->
          Error(TypeMismatch(param_name, expected, types_core.TypeString))
      }
    types_core.TypeBool ->
      case string.lowercase(raw) {
        "true" -> Ok(types_core.BoolVal(True))
        "false" -> Ok(types_core.BoolVal(False))
        _ -> Error(TypeMismatch(param_name, expected, types_core.TypeString))
      }
    types_core.TypeList ->
      Error(TypeMismatch(param_name, expected, types_core.TypeString))
  }
}
