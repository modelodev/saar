//// JSON Pointer parsing and resolution.
////
//// Mission: parse RFC 6901-style JSON Pointers and resolve them against
//// `gleam/dynamic.Dynamic` values.
////
//// Responsibilities:
//// - Parse pointer strings into validated pointers with decoded segments.
//// - Resolve segments against dynamic objects/arrays.
//// - Provide conversions between `gleam/json.Json` and `gleam/dynamic.Dynamic`.
////
//// Non-responsibilities:
//// - Schema validation beyond pointer parsing.
//// - Performing I/O.
////
//// Relationships:
//// - Uses `gleam/dynamic/decode` to interpret dynamic values as objects/lists.
//// - Used by higher-level response mapping to extract data by pointer.

import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some, from_result, then}
import gleam/string

/// Errors returned when parsing a JSON Pointer string.
pub type ParseError {
  InvalidPointer(pointer: String)
}

/// A validated JSON Pointer with decoded segments.
pub opaque type Pointer {
  Pointer(segments: List(String))
}

/// Parses a JSON Pointer string into a validated pointer.
///
/// Supports the RFC 6901 escape sequences `~0` ("~") and `~1` ("/").
///
/// Example:
/// ```gleam
/// import saar/json_pointer
///
/// let assert Ok(pointer) = json_pointer.parse("/a~1b/~0")
/// json_pointer.segments(pointer)
/// ```
pub fn parse(pointer: String) -> Result(Pointer, ParseError) {
  case pointer {
    "" -> Ok(Pointer([]))
    _ -> parse_non_empty(pointer)
  }
}

/// Returns the decoded segments from a validated pointer.
///
/// Use this when resolving pointers against non-`dynamic.Dynamic` values.
pub fn segments(pointer: Pointer) -> List(String) {
  let Pointer(segments) = pointer
  segments
}

fn parse_non_empty(pointer: String) -> Result(Pointer, ParseError) {
  case string.split(pointer, "/") {
    ["", ..segments] ->
      case
        list.try_map(segments, fn(segment) { decode_segment(segment, pointer) })
      {
        Ok(decoded) -> Ok(Pointer(decoded))
        Error(err) -> Error(err)
      }

    _ -> Error(InvalidPointer(pointer))
  }
}

/// Resolves a validated pointer against a dynamic value.
///
/// Objects are resolved by key lookup and arrays are resolved by integer index.
/// Returns `None` if resolution fails at any step.
///
/// Example:
/// ```gleam
/// import gleam/dynamic
/// import saar/json_pointer
///
/// let data =
///   dynamic.properties([
///     #(dynamic.string("a"), dynamic.properties([
///       #(dynamic.string("b"), dynamic.string("ok")),
///     ])),
///   ])
///
/// let assert Ok(pointer) = json_pointer.parse("/a/b")
/// json_pointer.resolve(pointer, data)
/// ```
pub fn resolve(
  pointer: Pointer,
  current: dynamic.Dynamic,
) -> Option(dynamic.Dynamic) {
  let Pointer(segments) = pointer
  resolve_segments(segments, current)
}

fn resolve_step(
  segment: String,
  rest: List(String),
  current: dynamic.Dynamic,
) -> Option(dynamic.Dynamic) {
  case dynamic_as_object(current) {
    Some(fields) ->
      fields
      |> dict.get(segment)
      |> from_result
      |> then(fn(next) { resolve_segments(rest, next) })

    None ->
      case dynamic_as_list(current) {
        Some(items) -> resolve_list(segment, rest, items)
        None -> None
      }
  }
}

fn resolve_segments(
  segments: List(String),
  current: dynamic.Dynamic,
) -> Option(dynamic.Dynamic) {
  case segments {
    [] -> Some(current)
    [segment, ..rest] -> resolve_step(segment, rest, current)
  }
}

/// Converts JSON into a `dynamic.Dynamic`.
///
/// This is a convenience helper used for pointer resolution.
/// Prefer passing `dynamic.Dynamic` values at module boundaries to avoid
/// JSON round-trips.
///
/// Example:
/// ```gleam
/// import gleam/json
/// import saar/json_pointer
///
/// json_pointer.json_to_dynamic(json.object([]))
/// ```
pub fn json_to_dynamic(value: json.Json) -> dynamic.Dynamic {
  let assert Ok(dynamic_value) =
    json.to_string(value)
    |> json.parse(using: decode.dynamic)
  dynamic_value
}

/// Converts a `dynamic.Dynamic` into `json.Json`.
///
/// Values that cannot be decoded as a JSON-compatible primitive are converted
/// into `json.null()`.
///
/// Example:
/// ```gleam
/// import gleam/dynamic
/// import saar/json_pointer
///
/// json_pointer.dynamic_to_json(dynamic.string("x"))
/// ```
pub fn dynamic_to_json(value: dynamic.Dynamic) -> json.Json {
  case decode.run(value, decode.optional(json_decoder())) {
    Ok(None) -> json.null()
    Ok(Some(inner)) -> inner
    Error(_) -> json.null()
  }
}

fn decode_segment(
  segment: String,
  pointer: String,
) -> Result(String, ParseError) {
  segment
  |> string.to_graphemes
  |> decode_chars(pointer, [])
}

fn decode_chars(
  chars: List(String),
  pointer: String,
  acc: List(String),
) -> Result(String, ParseError) {
  case chars {
    [] -> Ok(acc |> list.reverse |> string.join(""))
    ["~"] -> Error(InvalidPointer(pointer))
    ["~", "0", ..rest] -> decode_chars(rest, pointer, ["~", ..acc])
    ["~", "1", ..rest] -> decode_chars(rest, pointer, ["/", ..acc])
    ["~", _, ..] -> Error(InvalidPointer(pointer))
    [char, ..rest] -> decode_chars(rest, pointer, [char, ..acc])
  }
}

fn resolve_list(
  segment: String,
  rest: List(String),
  items: List(dynamic.Dynamic),
) -> Option(dynamic.Dynamic) {
  case int.parse(segment) {
    Ok(index) if index >= 0 ->
      items
      |> list.drop(index)
      |> list.first
      |> from_result
      |> then(fn(value) { resolve_segments(rest, value) })

    _ -> None
  }
}

fn dynamic_as_object(
  value: dynamic.Dynamic,
) -> Option(dict.Dict(String, dynamic.Dynamic)) {
  decode.run(value, decode.dict(decode.string, decode.dynamic))
  |> from_result
}

fn dynamic_as_list(value: dynamic.Dynamic) -> Option(List(dynamic.Dynamic)) {
  decode.run(value, decode.list(of: decode.dynamic))
  |> from_result
}

fn json_decoder() -> decode.Decoder(json.Json) {
  use <- decode.recursive

  let object_decoder =
    decode.dict(decode.string, decode.optional(json_decoder()))
    |> decode.map(fn(entries) {
      entries
      |> dict.to_list
      |> list.map(fn(pair) {
        let #(key, value) = pair
        #(key, optional_json(value))
      })
      |> json.object
    })

  let array_decoder =
    decode.list(of: decode.optional(json_decoder()))
    |> decode.map(fn(items) {
      let values = items |> list.map(optional_json)

      json.array(values, fn(item) { item })
    })

  decode.one_of(decode.string |> decode.map(json.string), [
    decode.bool |> decode.map(json.bool),
    decode.int |> decode.map(json.int),
    decode.float |> decode.map(json.float),
    object_decoder,
    array_decoder,
  ])
}

fn optional_json(value: Option(json.Json)) -> json.Json {
  case value {
    None -> json.null()
    Some(inner) -> inner
  }
}
