//// Mission: validate file cardinality checks for A2A requests.
////
//// Responsibilities:
//// - Reject file-heavy A2A messages beyond max_files.
////
//// Non-responsibilities:
//// - Validating native interact errors (covered elsewhere).
////
//// Relationships:
//// - Uses `test/tasks_helpers.gleam` for server setup.
//// - Uses `saar/bridge/http_client` for HTTP calls.

import gleam/dict
import gleam/http
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import saar/bridge/http_client
import tasks_helpers
import test_assertions

pub fn main() {
  gleeunit.main()
}

pub fn a2a_rejects_two_files_when_max_files_one() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-a2a-files-one"
  tasks_helpers.create_agent(base_url, "echo_files_one", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let body =
    "{"
    <> "\"message\":{"
    <> "\"messageId\":\"msg-a2a-files-one\","
    <> "\"role\":\"user\","
    <> "\"parts\":["
    <> "{\"file\":{\"uri\":\"https://example.com/doc-1.txt\",\"mediaType\":\"text/plain\",\"name\":\"doc-1.txt\"}},"
    <> "{\"file\":{\"uri\":\"https://example.com/doc-2.txt\",\"mediaType\":\"text/plain\",\"name\":\"doc-2.txt\"}}"
    <> "]"
    <> "}"
    <> "}"

  let resp =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/instances/" <> instance_id <> "/a2a/message:send",
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
