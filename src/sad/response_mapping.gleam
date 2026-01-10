//// Response mapping for runner and HTTP outputs.
////
//// Mission: resolve JSON pointers over dynamic payloads to build response data.
////
//// Responsibilities:
//// - Resolve optional pointers against dynamic values.
//// - Decode mapped values into response text and artifacts.
//// - Surface mapping errors with consistent error kinds.
////
//// Non-responsibilities:
//// - Parsing raw JSON strings.
//// - Validating schemas beyond pointer resolution.
////
//// Relationships:
//// - Uses `sad/json_pointer` for pointer parsing and resolution.
//// - Consumes `types_profile.ResponseMapping` configuration.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sad/json_pointer
import sad/types/enums as types_enums
import sad/types/profile as types_profile

type MappingFailure {
  InvalidPointer(pointer: String)
  WrongType(expected: String, pointer: Option(String), got: String)
}

/// Output from applying a response mapping.
pub type MappingResult {
  MappingResult(text: Option(String), artifacts: Option(List(json.Json)))
}

/// Errors produced while applying a response mapping.
pub type MappingError {
  MappingError(kind: types_enums.ErrorKind, message: String)
}

/// Applies response mapping pointers to a dynamic payload.
///
/// When `mapping` is `None`, the payload is serialized as a JSON string.
///
/// Example:
/// ```gleam
/// import gleam/dynamic
/// import gleam/option.{Some}
/// import sad/response_mapping
/// import sad/types/profile as types_profile
///
/// let mapping =
///   types_profile.ResponseMapping(
///     text_pointer: Some("/answer"),
///     artifacts_pointer: None,
///   )
///
/// let payload =
///   dynamic.properties([
///     #(dynamic.string("answer"), dynamic.string("ok")),
///   ])
///
/// response_mapping.apply_response_mapping(Some(mapping), payload)
/// ```
pub fn apply_response_mapping(
  mapping: Option(types_profile.ResponseMapping),
  body: dynamic.Dynamic,
) -> Result(MappingResult, MappingError) {
  apply_response_mapping_pure(mapping, body)
  |> result.map_error(mapping_failure_to_error)
}

fn apply_response_mapping_pure(
  mapping: Option(types_profile.ResponseMapping),
  body: dynamic.Dynamic,
) -> Result(MappingResult, MappingFailure) {
  case mapping {
    None ->
      Ok(MappingResult(
        text: Some(json.to_string(json_pointer.dynamic_to_json(body))),
        artifacts: None,
      ))

    Some(types_profile.ResponseMapping(text_pointer, artifacts_pointer)) -> {
      use text_value <- result.try(resolve_pointer_option(text_pointer, body))
      use artifacts_value <- result.try(resolve_pointer_option(
        artifacts_pointer,
        body,
      ))

      use text <- result.try(text_from_value(text_value, text_pointer))
      use artifacts <- result.try(artifacts_from_value(
        artifacts_value,
        artifacts_pointer,
      ))

      Ok(MappingResult(text: text, artifacts: artifacts))
    }
  }
}

fn resolve_pointer_option(
  pointer: Option(String),
  root: dynamic.Dynamic,
) -> Result(Option(dynamic.Dynamic), MappingFailure) {
  case pointer {
    None -> Ok(None)
    Some(value) -> resolve_pointer(value, root)
  }
}

fn resolve_pointer(
  pointer: String,
  root: dynamic.Dynamic,
) -> Result(Option(dynamic.Dynamic), MappingFailure) {
  use parsed_pointer <- result.try(
    json_pointer.parse(pointer)
    |> result.map_error(fn(_) { InvalidPointer(pointer) }),
  )

  case json_pointer.resolve(parsed_pointer, root) {
    None -> Ok(None)
    Some(value) -> Ok(Some(value))
  }
}

fn text_from_value(
  value: Option(dynamic.Dynamic),
  pointer: Option(String),
) -> Result(Option(String), MappingFailure) {
  decode_optional(value, decode.string, "string", pointer)
}

fn artifacts_from_value(
  value: Option(dynamic.Dynamic),
  pointer: Option(String),
) -> Result(Option(List(json.Json)), MappingFailure) {
  use items <- result.try(decode_optional(
    value,
    decode.list(of: decode.dynamic),
    "array",
    pointer,
  ))

  Ok(case items {
    None -> None
    Some(values) -> Some(list.map(values, json_pointer.dynamic_to_json))
  })
}

fn decode_optional(
  value: Option(dynamic.Dynamic),
  decoder: decode.Decoder(a),
  expected: String,
  pointer: Option(String),
) -> Result(Option(a), MappingFailure) {
  case value {
    None -> Ok(None)
    Some(payload) ->
      case decode.run(payload, decoder) {
        Ok(inner) -> Ok(Some(inner))
        Error(_) ->
          Error(WrongType(
            expected: expected,
            pointer: pointer,
            got: describe_dynamic(payload),
          ))
      }
  }
}

fn describe_dynamic(value: dynamic.Dynamic) -> String {
  case decode.run(value, decode.string) {
    Ok(_) -> "string"
    Error(_) ->
      case decode.run(value, decode.bool) {
        Ok(_) -> "bool"
        Error(_) ->
          case decode.run(value, decode.int) {
            Ok(_) -> "number"
            Error(_) ->
              case decode.run(value, decode.float) {
                Ok(_) -> "number"
                Error(_) ->
                  case decode.run(value, decode.list(of: decode.dynamic)) {
                    Ok(_) -> "array"
                    Error(_) ->
                      case
                        decode.run(
                          value,
                          decode.dict(decode.string, decode.dynamic),
                        )
                      {
                        Ok(_) -> "object"
                        Error(_) -> "unknown"
                      }
                  }
              }
          }
      }
  }
}

fn mapping_failure_to_error(failure: MappingFailure) -> MappingError {
  case failure {
    InvalidPointer(pointer) -> invalid_pointer(pointer)
    WrongType(expected, pointer, got) -> wrong_type(expected, pointer, got)
  }
}

fn invalid_pointer(pointer: String) -> MappingError {
  MappingError(
    kind: types_enums.BadRequest,
    message: "Invalid JSON pointer '" <> pointer <> "'",
  )
}

fn wrong_type(
  expected: String,
  pointer: Option(String),
  got: String,
) -> MappingError {
  let suffix = case pointer {
    Some(value) -> " at '" <> value <> "'"
    None -> ""
  }

  MappingError(
    kind: types_enums.AgentError,
    message: "Expected " <> expected <> suffix <> ", got " <> got,
  )
}
