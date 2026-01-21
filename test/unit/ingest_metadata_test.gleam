import gleam/dict
import gleam/json
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import saar/ingest_metadata

pub fn main() {
  gleeunit.main()
}

pub fn ingest_context_extra_includes_payload_test() {
  let payload = json.object([#("trackId", json.string("track-1"))])

  let extra = ingest_metadata.ingest_context_extra("ctx-1", Some(payload))

  let assert Ok(context_id) = dict.get(extra, "context_id")
  context_id |> should.equal("ctx-1")

  let assert Ok(encoded) = dict.get(extra, "ingest_payload")
  encoded |> should.equal(json.to_string(payload))
}

pub fn ingest_context_extra_omits_payload_when_none_test() {
  let extra = ingest_metadata.ingest_context_extra("ctx-1", None)

  let assert Ok(context_id) = dict.get(extra, "context_id")
  context_id |> should.equal("ctx-1")
  dict.has_key(extra, "ingest_payload") |> should.equal(False)
}

pub fn ingest_payload_from_context_decodes_json_test() {
  let payload = json.object([#("effect", json.string("eventual"))])
  let extra = dict.from_list([#("ingest_payload", json.to_string(payload))])

  let assert Some(decoded) = ingest_metadata.ingest_payload_from_context(extra)

  json.to_string(decoded) |> should.equal(json.to_string(payload))
}

pub fn ingest_payload_from_context_ignores_invalid_json_test() {
  let extra = dict.from_list([#("ingest_payload", "not-json")])

  ingest_metadata.ingest_payload_from_context(extra)
  |> should.equal(None)
}
