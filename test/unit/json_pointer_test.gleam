//// Unit tests for `sad/json_pointer`.
////
//// Mission: verify JSON Pointer parsing and resolution behavior.
////
//// Responsibilities:
//// - Validate pointer parsing, escape decoding, and error cases.
//// - Validate resolution against objects and arrays.
////
//// Non-responsibilities:
//// - JSON schema validation.

import gleam/dynamic
import gleam/json
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import sad/json_pointer

pub fn main() {
  gleeunit.main()
}

pub fn parse_empty_pointer_test() {
  let assert Ok(pointer) = json_pointer.parse("")
  json_pointer.segments(pointer)
  |> should.equal([])
}

pub fn parse_requires_leading_slash_test() {
  json_pointer.parse("a/b")
  |> should.equal(Error(json_pointer.InvalidPointer("a/b")))
}

pub fn parse_decodes_escapes_test() {
  let assert Ok(pointer) = json_pointer.parse("/a~1b/~0")
  json_pointer.segments(pointer)
  |> should.equal(["a/b", "~"])
}

pub fn resolve_object_path_test() {
  let data =
    dynamic.properties([
      #(dynamic.string("a"), dynamic.properties([
        #(dynamic.string("b"), dynamic.string("ok")),
      ])),
    ])

  let assert Ok(pointer) = json_pointer.parse("/a/b")

  json_pointer.resolve(pointer, data)
  |> should.equal(Some(dynamic.string("ok")))
}

pub fn resolve_array_index_test() {
  let data =
    dynamic.properties([
      #(dynamic.string("arr"), dynamic.list([
        dynamic.int(1),
        dynamic.int(2),
        dynamic.int(3),
      ])),
    ])

  let assert Ok(pointer) = json_pointer.parse("/arr/1")

  json_pointer.resolve(pointer, data)
  |> should.equal(Some(dynamic.int(2)))
}

pub fn resolve_invalid_index_returns_none_test() {
  let data =
    dynamic.properties([
      #(dynamic.string("arr"), dynamic.list([
        dynamic.int(1),
        dynamic.int(2),
        dynamic.int(3),
      ])),
    ])

  let assert Ok(pointer) = json_pointer.parse("/arr/nope")

  json_pointer.resolve(pointer, data)
  |> should.equal(None)
}

pub fn dynamic_to_json_roundtrip_test() {
  let data =
    dynamic.properties([
      #(dynamic.string("items"), dynamic.list([
        dynamic.string("a"),
        dynamic.string("b"),
      ])),
    ])

  let expected =
    json.object([
      #("items", json.array(["a", "b"], json.string)),
    ])

  data
  |> json_pointer.dynamic_to_json
  |> should.equal(expected)
}
