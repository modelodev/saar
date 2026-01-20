//// Mission: validate ingest metadata capture for HTTP file uploads.
////
//// Responsibilities:
//// - Capture track_id metadata from HTTP responses.
//// - Ignore missing capture pointers without failing.
////
//// Non-responsibilities:
//// - Validating file cardinality limits (covered elsewhere).
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

pub fn files_upload_includes_track_id_when_present() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-files-track"
  tasks_helpers.create_agent(base_url, "echo_server_files_track", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_continuous", 200)

  let body = interact_body("files", base_url <> "/health", "trace-files-track")

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
  string.contains(resp.body, "\"track_id\"") |> should.equal(True)
}

pub fn files_upload_missing_track_id_does_not_fail() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-files-missing"
  tasks_helpers.create_agent(base_url, "echo_server_files_missing", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_continuous", 200)

  let body =
    interact_body("files", base_url <> "/health", "trace-files-missing")

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
  string.contains(resp.body, "missing_track_id") |> should.equal(False)
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
