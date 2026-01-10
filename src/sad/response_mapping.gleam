//// Response mapping for runner outputs.
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
) -> Result(Option(dynamic.Dynamic), MappingError) {
  case pointer {
    None -> Ok(None)
    Some(value) -> resolve_pointer(value, root)
  }
}

fn resolve_pointer(
  pointer: String,
  root: dynamic.Dynamic,
) -> Result(Option(dynamic.Dynamic), MappingError) {
  use parsed_pointer <- result.try(
    json_pointer.parse(pointer)
    |> result.map_error(fn(_) { invalid_pointer(pointer) }),
  )
  case json_pointer.resolve(parsed_pointer, root) {
    None -> Ok(None)
    Some(value) -> Ok(Some(value))
  }
}

fn text_from_value(
  value: Option(dynamic.Dynamic),
  pointer: Option(String),
) -> Result(Option(String), MappingError) {
  case value {
    None -> Ok(None)
    Some(payload) ->
      case decode.run(payload, decode.string) {
        Ok(text) -> Ok(Some(text))
        Error(_) -> Error(wrong_type("string", pointer))
      }
  }
}

fn artifacts_from_value(
  value: Option(dynamic.Dynamic),
  pointer: Option(String),
) -> Result(Option(List(json.Json)), MappingError) {
  case value {
    None -> Ok(None)
    Some(payload) ->
      case decode.run(payload, decode.list(of: decode.dynamic)) {
        Ok(items) ->
          Ok(Some(list.map(items, json_pointer.dynamic_to_json)))
        Error(_) -> Error(wrong_type("array", pointer))
      }
  }
}

fn invalid_pointer(pointer: String) -> MappingError {
  MappingError(
    kind: types_enums.BadRequest,
    message: "Invalid JSON pointer '" <> pointer <> "'",
  )
}

fn wrong_type(expected: String, pointer: Option(String)) -> MappingError {
  let suffix = case pointer {
    Some(value) -> " at '" <> value <> "'"
    None -> ""
  }

  MappingError(
    kind: types_enums.AgentError,
    message: "Expected " <> expected <> suffix,
  )
}
