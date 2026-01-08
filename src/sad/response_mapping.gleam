import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sad/types/enums as types_enums
import sad/types/profile as types_profile

pub type MappingResult {
  MappingResult(text: Option(String), artifacts: Option(List(json.Json)))
}

pub type MappingError {
  MappingError(kind: types_enums.ErrorKind, message: String)
}

pub fn parse_json_pointer(pointer: String) -> Result(List(String), MappingError) {
  case pointer {
    "" -> Ok([])
    _ ->
      case string.split(pointer, "/") {
        ["", ..segments] ->
          list.try_map(segments, fn(segment) {
            decode_pointer_segment(segment, pointer)
          })
        _ -> Error(invalid_pointer(pointer))
      }
  }
}

pub fn apply_response_mapping(
  mapping: Option(types_profile.ResponseMapping),
  body: json.Json,
) -> Result(MappingResult, MappingError) {
  case mapping {
    None -> Ok(MappingResult(text: Some(json.to_string(body)), artifacts: None))
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
  body: json.Json,
) -> Result(Option(json.Json), MappingError) {
  case pointer {
    None -> Ok(None)
    Some(value) -> resolve_pointer(value, body)
  }
}

fn resolve_pointer(
  pointer: String,
  body: json.Json,
) -> Result(Option(json.Json), MappingError) {
  use segments <- result.try(parse_json_pointer(pointer))
  let root = json_to_dynamic(body)
  case resolve_dynamic_pointer(segments, root) {
    None -> Ok(None)
    Some(value) -> Ok(Some(dynamic_to_json(value)))
  }
}

fn text_from_value(
  value: Option(json.Json),
  pointer: Option(String),
) -> Result(Option(String), MappingError) {
  case value {
    None -> Ok(None)
    Some(payload) ->
      case decode.run(json_to_dynamic(payload), decode.string) {
        Ok(text) -> Ok(Some(text))
        Error(_) -> Error(wrong_type("string", pointer))
      }
  }
}

fn artifacts_from_value(
  value: Option(json.Json),
  pointer: Option(String),
) -> Result(Option(List(json.Json)), MappingError) {
  case value {
    None -> Ok(None)
    Some(payload) ->
      case
        decode.run(json_to_dynamic(payload), decode.list(of: decode.dynamic))
      {
        Ok(items) -> Ok(Some(list.map(items, dynamic_to_json)))
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

fn decode_pointer_segment(
  segment: String,
  pointer: String,
) -> Result(String, MappingError) {
  segment
  |> string.to_graphemes
  |> decode_pointer_chars(pointer, [])
}

fn decode_pointer_chars(
  chars: List(String),
  pointer: String,
  acc: List(String),
) -> Result(String, MappingError) {
  case chars {
    [] -> Ok(acc |> list.reverse |> string.join(""))
    ["~"] -> Error(invalid_pointer(pointer))
    ["~", "0", ..rest] -> decode_pointer_chars(rest, pointer, ["~", ..acc])
    ["~", "1", ..rest] -> decode_pointer_chars(rest, pointer, ["/", ..acc])
    ["~", _, ..] -> Error(invalid_pointer(pointer))
    [char, ..rest] -> decode_pointer_chars(rest, pointer, [char, ..acc])
  }
}

fn resolve_dynamic_pointer(
  segments: List(String),
  current: dynamic.Dynamic,
) -> Option(dynamic.Dynamic) {
  case segments {
    [] -> Some(current)
    [segment, ..rest] ->
      case decode.run(current, decode.dict(decode.string, decode.dynamic)) {
        Ok(fields) ->
          case dict.get(fields, segment) {
            Ok(next) -> resolve_dynamic_pointer(rest, next)
            Error(_) -> None
          }
        Error(_) ->
          case decode.run(current, decode.list(of: decode.dynamic)) {
            Ok(items) -> resolve_list_pointer(segment, rest, items)
            Error(_) -> None
          }
      }
  }
}

fn resolve_list_pointer(
  segment: String,
  rest: List(String),
  items: List(dynamic.Dynamic),
) -> Option(dynamic.Dynamic) {
  case int.parse(segment) {
    Ok(index) ->
      case index < 0 {
        True -> None
        False ->
          case list.drop(items, index) |> list.first {
            Ok(value) -> resolve_dynamic_pointer(rest, value)
            Error(_) -> None
          }
      }
    Error(_) -> None
  }
}

fn json_to_dynamic(value: json.Json) -> dynamic.Dynamic {
  let assert Ok(dynamic_value) =
    json.to_string(value)
    |> json.parse(using: decode.dynamic)
  dynamic_value
}

fn dynamic_to_json(value: dynamic.Dynamic) -> json.Json {
  case decode.run(value, decode.optional(decode.dynamic)) {
    Ok(None) -> json.null()
    Ok(Some(inner)) -> dynamic_to_json_non_null(inner)
    Error(_) -> json.null()
  }
}

fn dynamic_to_json_non_null(value: dynamic.Dynamic) -> json.Json {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(entries) ->
      entries
      |> dict.to_list
      |> list.map(fn(pair) { #(pair.0, dynamic_to_json(pair.1)) })
      |> json.object
    Error(_) ->
      case decode.run(value, decode.list(of: decode.dynamic)) {
        Ok(items) -> json.array(items, dynamic_to_json)
        Error(_) ->
          case decode.run(value, decode.string) {
            Ok(text) -> json.string(text)
            Error(_) ->
              case decode.run(value, decode.bool) {
                Ok(flag) -> json.bool(flag)
                Error(_) ->
                  case decode.run(value, decode.int) {
                    Ok(number) -> json.int(number)
                    Error(_) ->
                      case decode.run(value, decode.float) {
                        Ok(number) -> json.float(number)
                        Error(_) -> json.null()
                      }
                  }
              }
          }
      }
  }
}
