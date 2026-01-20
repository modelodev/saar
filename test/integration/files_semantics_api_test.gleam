//// Mission: validate file semantics metadata for native responses.
////
//// Responsibilities:
//// - Include ingest metadata for file uploads in native responses.
////
//// Non-responsibilities:
//// - A2A response validation.
////
//// Relationships:
//// - Uses `test/tasks_helpers.gleam` for server setup.
//// - Uses `saar/bridge/http_client` for HTTP calls.

import gleam/dict
import gleam/http
import gleam/option.{Some}
import gleam/string
import gleeunit
import gleeunit/should
import saar/bridge/http_client
import tasks_helpers
import test_assertions

pub fn main() {
  gleeunit.main()
}

pub fn upload_returns_ingest_effect_eventual_in_metadata() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-files-eventual"
  tasks_helpers.create_agent(base_url, "echo_files_eventual", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let body =
    interact_body("files", base_url <> "/health", "trace-files-eventual")

  let resp =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/agents/" <> instance_id <> "/interact",
      dict.insert(
        tasks_helpers.auth_headers(),
        "content-type",
        "application/json",
      ),
      Some(body),
      5000,
      1024 * 1024,
    )
    |> test_assertions.assert_ok

  resp.status |> should.equal(200)
  string.contains(resp.body, "\"ingest_effect\":\"eventual\"")
  |> should.equal(True)
  string.contains(resp.body, "\"max_files\":1") |> should.equal(True)
}

fn interact_body(
  capability: String,
  file_url: String,
  trace_id: String,
) -> String {
  "{"
  <> "\"capability\":\""
  <> capability
  <> "\","
  <> "\"inputs\":{\"files\":[{\"name\":\"doc.txt\",\"url\":\""
  <> file_url
  <> "\",\"mime\":\"text/plain\"}]},"
  <> "\"context\":{\"trace_id\":\""
  <> trace_id
  <> "\"}"
  <> "}"
}
