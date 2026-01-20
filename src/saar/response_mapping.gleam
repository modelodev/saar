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
//// - Uses `saar/json_pointer` for pointer parsing and resolution.
//// - Consumes `types_profile.ResponseConfig` configuration.

import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import saar/decoders
import saar/json_pointer
import saar/types/core as types_core
import saar/types/enums as types_enums
import saar/types/output as types_output
import saar/types/profile as types_profile

type MappingFailure {
  InvalidPointer(pointer: String)
  WrongType(expected: String, pointer: Option(String), got: String)
}

/// Output from applying a response mapping.
pub type MappingResult {
  MappingResult(
    text: Option(String),
    artifacts: Option(List(json.Json)),
    metadata: dict.Dict(String, json.Json),
  )
}

/// Applies response mapping pointers to a dynamic payload.
///
/// When `mapping` is `None` or `Default`, the payload is serialized as a JSON
/// string.
///
/// Example:
/// ```gleam
/// import gleam/dynamic
/// import gleam/option.{Some}
/// import saar/response_mapping
/// import saar/types/profile as types_profile
///
/// let mapping = types_profile.Text("/answer")
/// let response = types_profile.ResponseConfig(mapping: mapping, capture: dict.new())
///
/// let payload =
///   dynamic.properties([
///     #(dynamic.string("answer"), dynamic.string("ok")),
///   ])
///
/// response_mapping.apply_response_mapping(Some(response), payload)
/// ```
pub fn apply_response_mapping(
  trace_id: types_core.TraceId,
  response: Option(types_profile.ResponseConfig),
  body: dynamic.Dynamic,
) -> Result(MappingResult, types_output.SaarError) {
  let #(mapping, capture) = response_config_parts(response)
  use mapped <- result.try(
    apply_response_mapping_pure(mapping, body)
    |> result.map_error(fn(failure) {
      mapping_failure_to_error(trace_id, failure)
    }),
  )
  use metadata <- result.try(
    capture_metadata(capture, body)
    |> result.map_error(fn(failure) {
      mapping_failure_to_error(trace_id, failure)
    }),
  )
  Ok(MappingResult(
    text: mapped.text,
    artifacts: mapped.artifacts,
    metadata: metadata,
  ))
}

fn apply_response_mapping_pure(
  mapping: Option(types_profile.ResponseMapping),
  body: dynamic.Dynamic,
) -> Result(MappingResult, MappingFailure) {
  case mapping {
    None -> default_mapping(body)
    Some(types_profile.Default) -> default_mapping(body)
    Some(types_profile.Text(text_pointer)) ->
      apply_pointer_mapping(Some(text_pointer), None, body)
    Some(types_profile.Artifacts(artifacts_pointer)) ->
      apply_pointer_mapping(None, Some(artifacts_pointer), body)
    Some(types_profile.Both(text_pointer, artifacts_pointer)) ->
      apply_pointer_mapping(Some(text_pointer), Some(artifacts_pointer), body)
  }
}

fn default_mapping(
  body: dynamic.Dynamic,
) -> Result(MappingResult, MappingFailure) {
  Ok(MappingResult(
    text: Some(json.to_string(json_pointer.dynamic_to_json(body))),
    artifacts: None,
    metadata: dict.new(),
  ))
}

fn apply_pointer_mapping(
  text_pointer: Option(String),
  artifacts_pointer: Option(String),
  body: dynamic.Dynamic,
) -> Result(MappingResult, MappingFailure) {
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

  Ok(MappingResult(text: text, artifacts: artifacts, metadata: dict.new()))
}

fn response_config_parts(
  response: Option(types_profile.ResponseConfig),
) -> #(Option(types_profile.ResponseMapping), dict.Dict(String, String)) {
  case response {
    None -> #(None, dict.new())
    Some(types_profile.ResponseConfig(mapping: mapping, capture: capture)) -> #(
      Some(mapping),
      capture,
    )
  }
}

fn capture_metadata(
  capture: dict.Dict(String, String),
  body: dynamic.Dynamic,
) -> Result(dict.Dict(String, json.Json), MappingFailure) {
  capture
  |> dict.to_list
  |> list.fold(Ok(dict.new()), fn(acc, entry) {
    let #(key, pointer) = entry
    use resolved <- result.try(acc)
    use value <- result.try(resolve_pointer(pointer, body))
    case value {
      None -> Ok(resolved)
      Some(payload) ->
        Ok(dict.insert(resolved, key, json_pointer.dynamic_to_json(payload)))
    }
  })
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
            got: decoders.describe_dynamic_type(payload),
          ))
      }
  }
}

fn mapping_failure_to_error(
  trace_id: types_core.TraceId,
  failure: MappingFailure,
) -> types_output.SaarError {
  case failure {
    InvalidPointer(pointer) -> invalid_pointer(trace_id, pointer)
    WrongType(expected, pointer, got) ->
      wrong_type(trace_id, expected, pointer, got)
  }
}

fn invalid_pointer(
  trace_id: types_core.TraceId,
  pointer: String,
) -> types_output.SaarError {
  types_output.saar_error(
    trace_id,
    types_enums.BadRequest,
    "Invalid JSON pointer '" <> pointer <> "'",
  )
}

fn wrong_type(
  trace_id: types_core.TraceId,
  expected: String,
  pointer: Option(String),
  got: String,
) -> types_output.SaarError {
  let suffix = case pointer {
    Some(value) -> " at '" <> value <> "'"
    None -> ""
  }

  types_output.saar_error(
    trace_id,
    types_enums.AgentError,
    "Expected " <> expected <> suffix <> ", got " <> got,
  )
}
