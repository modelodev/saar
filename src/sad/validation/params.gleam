////
//// Mission: centralize parameter validation for profile defaults and runtime values.
////
//// Responsibilities:
//// - Decode parameter types and default values from JSON.
//// - Validate runtime values against expected parameter types.
//// - Validate profile parameter defaults for type correctness.
////
//// Non-responsibilities:
//// - Reading environment variables or config sources.
//// - Profile IO or decoding orchestration.
////
//// Relationships:
//// - Used by `sad/decoders` for parameter decoding.
//// - Used by `sad/params` for runtime resolution checks.
//// - Used by `sad/profiles_sources` to validate loaded profiles.

import gleam/dict
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import sad/types/core as types_core
import sad/types/profile as types_profile

/// Validation errors for profile parameter definitions.
pub type ParamValidationError {
  DefaultTypeMismatch(
    name: String,
    expected: types_profile.ParamType,
    got: types_core.ValueType,
  )
}

/// Decodes a `ParamType` from its string representation.
pub fn param_type_decoder() -> decode.Decoder(types_profile.ParamType) {
  let decoder = {
    use value <- decode.then(decode.string)
    case value {
      "string" -> decode.success(types_profile.ParamString)
      "int" -> decode.success(types_profile.ParamInt)
      "float" -> decode.success(types_profile.ParamFloat)
      "bool" -> decode.success(types_profile.ParamBool)
      _ -> decode.failure(types_profile.ParamString, expected: "ParamType")
    }
  }
  decoder
}

/// Decodes a `core.Value` matching the expected parameter type.
pub fn param_value_decoder(
  expected: types_profile.ParamType,
) -> decode.Decoder(types_core.Value) {
  case expected {
    types_profile.ParamString ->
      decode.string |> decode.map(types_core.StringVal)
    types_profile.ParamInt -> decode.int |> decode.map(types_core.IntVal)
    types_profile.ParamFloat -> decode.float |> decode.map(types_core.FloatVal)
    types_profile.ParamBool -> decode.bool |> decode.map(types_core.BoolVal)
  }
}

/// Ensures a runtime value matches the expected parameter type.
pub fn ensure_value_type(
  expected: types_profile.ParamType,
  value: types_core.Value,
) -> Result(types_core.Value, types_core.ValueType) {
  let expected_type = types_profile.param_type_to_value_type(expected)
  let got = types_core.value_type(value)

  case got == expected_type {
    True -> Ok(value)
    False -> Error(got)
  }
}

/// Parses an environment literal into a typed value for secrets.
pub fn parse_literal(
  expected: types_profile.ParamType,
  raw: String,
) -> Result(types_core.Value, Nil) {
  case expected {
    types_profile.ParamString -> Ok(types_core.StringVal(raw))

    types_profile.ParamInt ->
      case int.parse(raw) {
        Ok(value) -> Ok(types_core.IntVal(value))
        Error(_) -> Error(Nil)
      }

    types_profile.ParamFloat ->
      case float.parse(raw) {
        Ok(value) -> Ok(types_core.FloatVal(value))
        Error(_) -> Error(Nil)
      }

    types_profile.ParamBool ->
      case string.lowercase(raw) {
        "true" -> Ok(types_core.BoolVal(True))
        "false" -> Ok(types_core.BoolVal(False))
        _ -> Error(Nil)
      }
  }
}

/// Validates parameter defaults in a profile.
pub fn validate_profile_params(
  profile: types_profile.Profile,
) -> Result(types_profile.Profile, List(ParamValidationError)) {
  let types_profile.Profile(parameters: parameters, ..) = profile

  let errors =
    parameters
    |> dict.to_list
    |> list.filter_map(fn(pair) {
      let #(name, param) = pair

      case param {
        types_profile.ConfigParam(_, default, expected)
        | types_profile.InitParam(_, default, expected) ->
          case default {
            Some(value) ->
              case ensure_value_type(expected, value) {
                Ok(_) -> Error(Nil)
                Error(got) -> Ok(DefaultTypeMismatch(name, expected, got))
              }

            None -> Error(Nil)
          }

        _ -> Error(Nil)
      }
    })

  case errors {
    [] -> Ok(profile)
    _ -> Error(errors)
  }
}
