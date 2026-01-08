import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import sad/response_mapping
import sad/types/enums as types_enums
import sad/types/profile as types_profile

pub fn main() {
  gleeunit.main()
}

pub fn response_mapping_text_pointer_ok_test() {
  let mapping =
    types_profile.ResponseMapping(
      text_pointer: Some("/answer"),
      artifacts_pointer: None,
    )

  let body = json.object([#("answer", json.string("ok"))])

  let assert Ok(response_mapping.MappingResult(text: text, artifacts: artifacts)) =
    response_mapping.apply_response_mapping(Some(mapping), body)

  text |> should.equal(Some("ok"))
  artifacts |> should.equal(None)
}

pub fn response_mapping_text_pointer_missing_test() {
  let mapping =
    types_profile.ResponseMapping(
      text_pointer: Some("/missing"),
      artifacts_pointer: None,
    )

  let body = json.object([#("answer", json.string("ok"))])

  let assert Ok(response_mapping.MappingResult(text: text, artifacts: _)) =
    response_mapping.apply_response_mapping(Some(mapping), body)

  text |> should.equal(None)
}

pub fn response_mapping_pointer_invalid_test() {
  let mapping =
    types_profile.ResponseMapping(
      text_pointer: Some("bad"),
      artifacts_pointer: None,
    )

  let body = json.object([#("answer", json.string("ok"))])

  let assert Error(response_mapping.MappingError(kind: kind, message: _)) =
    response_mapping.apply_response_mapping(Some(mapping), body)

  kind |> should.equal(types_enums.BadRequest)
}

pub fn response_mapping_text_pointer_wrong_type_test() {
  let mapping =
    types_profile.ResponseMapping(
      text_pointer: Some("/answer"),
      artifacts_pointer: None,
    )

  let body = json.object([#("answer", json.int(42))])

  let assert Error(response_mapping.MappingError(kind: kind, message: _)) =
    response_mapping.apply_response_mapping(Some(mapping), body)

  kind |> should.equal(types_enums.AgentError)
}

pub fn response_mapping_artifacts_pointer_wrong_type_test() {
  let mapping =
    types_profile.ResponseMapping(
      text_pointer: None,
      artifacts_pointer: Some("/files"),
    )

  let body = json.object([#("files", json.string("nope"))])

  let assert Error(response_mapping.MappingError(kind: kind, message: _)) =
    response_mapping.apply_response_mapping(Some(mapping), body)

  kind |> should.equal(types_enums.AgentError)
}

pub fn response_mapping_artifacts_pointer_test() {
  let mapping =
    types_profile.ResponseMapping(
      text_pointer: None,
      artifacts_pointer: Some("/files"),
    )

  let body =
    json.object([
      #("files", json.array(["a", "b"], json.string)),
    ])

  let assert Ok(response_mapping.MappingResult(text: _, artifacts: artifacts)) =
    response_mapping.apply_response_mapping(Some(mapping), body)

  let assert Some(items) = artifacts
  list.length(items) |> should.equal(2)
}

pub fn response_mapping_both_pointers_test() {
  let mapping =
    types_profile.ResponseMapping(
      text_pointer: Some("/answer"),
      artifacts_pointer: Some("/files"),
    )

  let body =
    json.object([
      #("answer", json.string("ok")),
      #("files", json.array(["a"], json.string)),
    ])

  let assert Ok(response_mapping.MappingResult(text: text, artifacts: artifacts)) =
    response_mapping.apply_response_mapping(Some(mapping), body)

  text |> should.equal(Some("ok"))
  let assert Some(items) = artifacts
  list.length(items) |> should.equal(1)
}

pub fn response_mapping_none_test() {
  let body = json.object([#("answer", json.string("ok"))])

  let assert Ok(response_mapping.MappingResult(text: text, artifacts: artifacts)) =
    response_mapping.apply_response_mapping(None, body)

  text |> should.equal(Some("{\"answer\":\"ok\"}"))
  artifacts |> should.equal(None)
}
