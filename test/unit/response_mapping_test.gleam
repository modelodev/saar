import gleam/dynamic
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import sad/response_mapping
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/output as types_output
import sad/types/profile as types_profile

fn trace_id() -> types_core.TraceId {
  types_core.trace_id("trace-1")
}

pub fn main() {
  gleeunit.main()
}

pub fn response_mapping_text_pointer_ok_test() {
  let mapping = types_profile.Text("/answer")

  let body =
    dynamic.properties([
      #(dynamic.string("answer"), dynamic.string("ok")),
    ])

  let assert Ok(response_mapping.MappingResult(text: text, artifacts: artifacts)) =
    response_mapping.apply_response_mapping(trace_id(), Some(mapping), body)

  text |> should.equal(Some("ok"))
  artifacts |> should.equal(None)
}

pub fn response_mapping_text_pointer_missing_test() {
  let mapping = types_profile.Text("/missing")

  let body =
    dynamic.properties([
      #(dynamic.string("answer"), dynamic.string("ok")),
    ])

  let assert Ok(response_mapping.MappingResult(text: text, artifacts: _)) =
    response_mapping.apply_response_mapping(trace_id(), Some(mapping), body)

  text |> should.equal(None)
}

pub fn response_mapping_pointer_invalid_test() {
  let mapping = types_profile.Text("bad")

  let body =
    dynamic.properties([
      #(dynamic.string("answer"), dynamic.string("ok")),
    ])

  let assert Error(types_output.InteractionError(
    kind: kind,
    message: message,
    ..,
  )) = response_mapping.apply_response_mapping(trace_id(), Some(mapping), body)

  kind |> should.equal(types_enums.BadRequest)
  message |> should.equal("Invalid JSON pointer 'bad'")
}

pub fn response_mapping_text_pointer_wrong_type_test() {
  let mapping = types_profile.Text("/answer")

  let body =
    dynamic.properties([
      #(dynamic.string("answer"), dynamic.int(42)),
    ])

  let assert Error(types_output.InteractionError(
    kind: kind,
    message: message,
    ..,
  )) = response_mapping.apply_response_mapping(trace_id(), Some(mapping), body)

  kind |> should.equal(types_enums.AgentError)
  message |> should.equal("Expected string at '/answer', got number")
}

pub fn response_mapping_text_pointer_wrong_type_object_test() {
  let mapping = types_profile.Text("/answer")

  let body =
    dynamic.properties([
      #(
        dynamic.string("answer"),
        dynamic.properties([
          #(dynamic.string("nested"), dynamic.string("nope")),
        ]),
      ),
    ])

  let assert Error(types_output.InteractionError(
    kind: kind,
    message: message,
    ..,
  )) = response_mapping.apply_response_mapping(trace_id(), Some(mapping), body)

  kind |> should.equal(types_enums.AgentError)
  message |> should.equal("Expected string at '/answer', got object")
}

pub fn response_mapping_artifacts_pointer_wrong_type_test() {
  let mapping = types_profile.Artifacts("/files")

  let body =
    dynamic.properties([
      #(dynamic.string("files"), dynamic.string("nope")),
    ])

  let assert Error(types_output.InteractionError(
    kind: kind,
    message: message,
    ..,
  )) = response_mapping.apply_response_mapping(trace_id(), Some(mapping), body)

  kind |> should.equal(types_enums.AgentError)
  message |> should.equal("Expected array at '/files', got string")
}

pub fn response_mapping_artifacts_pointer_test() {
  let mapping = types_profile.Artifacts("/files")

  let body =
    dynamic.properties([
      #(
        dynamic.string("files"),
        dynamic.list([
          dynamic.string("a"),
          dynamic.string("b"),
        ]),
      ),
    ])

  let assert Ok(response_mapping.MappingResult(text: _, artifacts: artifacts)) =
    response_mapping.apply_response_mapping(trace_id(), Some(mapping), body)

  let assert Some(items) = artifacts
  list.length(items) |> should.equal(2)
}

pub fn response_mapping_both_pointers_test() {
  let mapping = types_profile.Both("/answer", "/files")

  let body =
    dynamic.properties([
      #(dynamic.string("answer"), dynamic.string("ok")),
      #(dynamic.string("files"), dynamic.list([dynamic.string("a")])),
    ])

  let assert Ok(response_mapping.MappingResult(text: text, artifacts: artifacts)) =
    response_mapping.apply_response_mapping(trace_id(), Some(mapping), body)

  text |> should.equal(Some("ok"))
  let assert Some(items) = artifacts
  list.length(items) |> should.equal(1)
}

pub fn response_mapping_none_test() {
  let body =
    dynamic.properties([
      #(dynamic.string("answer"), dynamic.string("ok")),
    ])

  let assert Ok(response_mapping.MappingResult(text: text, artifacts: artifacts)) =
    response_mapping.apply_response_mapping(trace_id(), None, body)

  text |> should.equal(Some("{\"answer\":\"ok\"}"))
  artifacts |> should.equal(None)
}

pub fn response_mapping_default_test() {
  let body =
    dynamic.properties([
      #(dynamic.string("answer"), dynamic.string("ok")),
    ])

  let assert Ok(response_mapping.MappingResult(text: text, artifacts: artifacts)) =
    response_mapping.apply_response_mapping(
      trace_id(),
      Some(types_profile.Default),
      body,
    )

  text |> should.equal(Some("{\"answer\":\"ok\"}"))
  artifacts |> should.equal(None)
}
