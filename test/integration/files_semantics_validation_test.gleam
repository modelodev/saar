//// Mission: validate file cardinality checks for native interact.
////
//// Responsibilities:
//// - Reject payloads when files exceed max_files.
//// - Ensure Problem Details includes file cardinality context.
////
//// Non-responsibilities:
//// - Validating A2A file handling (covered elsewhere).
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

pub fn interact_rejects_files_when_max_files_zero() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-files-zero"
  tasks_helpers.create_agent(base_url, "echo_files_zero", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let body =
    interact_body(
      "files",
      "[{\"name\":\"doc.txt\",\"url\":\"https://example.com/doc.txt\",\"mime\":\"text/plain\"}]",
      "trace-files-zero",
    )

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

  resp.status |> should.equal(400)
}

pub fn interact_rejects_two_files_when_max_files_one() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-files-one"
  tasks_helpers.create_agent(base_url, "echo_files_one", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let body =
    interact_body(
      "files",
      "[{\"name\":\"doc-1.txt\",\"url\":\"https://example.com/doc-1.txt\",\"mime\":\"text/plain\"},{\"name\":\"doc-2.txt\",\"url\":\"https://example.com/doc-2.txt\",\"mime\":\"text/plain\"}]",
      "trace-files-one",
    )

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

  resp.status |> should.equal(400)
}

pub fn problem_details_includes_max_files() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-files-problem"
  tasks_helpers.create_agent(base_url, "echo_files_one", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let body =
    interact_body(
      "files",
      "[{\"name\":\"doc-1.txt\",\"url\":\"https://example.com/doc-1.txt\",\"mime\":\"text/plain\"},{\"name\":\"doc-2.txt\",\"url\":\"https://example.com/doc-2.txt\",\"mime\":\"text/plain\"}]",
      "trace-files-problem",
    )

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

  resp.status |> should.equal(400)
  string.contains(resp.body, "capability=files") |> should.equal(True)
  string.contains(resp.body, "max_files=1") |> should.equal(True)
  string.contains(resp.body, "received_files=2") |> should.equal(True)
}

fn interact_body(
  capability: String,
  files_json: String,
  trace_id: String,
) -> String {
  "{"
  <> "\"capability\":\""
  <> capability
  <> "\","
  <> "\"inputs\":{\"files\":"
  <> files_json
  <> "},"
  <> "\"context\":{\"trace_id\":\""
  <> trace_id
  <> "\"}"
  <> "}"
}
