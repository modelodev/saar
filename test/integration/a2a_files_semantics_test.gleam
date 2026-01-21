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
import gleam/option.{None, Some}
import gleam/string
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

pub fn a2a_files_response_includes_ingest_data_part() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-a2a-files-ingest"
  tasks_helpers.create_agent(base_url, "echo_files_eventual", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let body =
    "{"
    <> "\"message\":{"
    <> "\"messageId\":\"msg-a2a-files-ingest\","
    <> "\"role\":\"user\","
    <> "\"parts\":["
    <> "{\"file\":{\"uri\":\"https://example.com/doc-1.txt\",\"mediaType\":\"text/plain\",\"name\":\"doc-1.txt\"}}"
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

  resp.status |> should.equal(200)
  string.contains(resp.body, "\"ingest\"") |> should.equal(True)
  string.contains(resp.body, "\"maxFiles\":1") |> should.equal(True)
  string.contains(resp.body, "\"effect\":\"eventual\"")
  |> should.equal(True)
}

pub fn agent_card_skill_input_modes_match_input_schema() {
  let base_url = tasks_helpers.start_saar()

  let files_instance_id = "inst-a2a-files-input"
  tasks_helpers.create_agent(base_url, "echo_files_eventual", files_instance_id)
  tasks_helpers.wait_phase(base_url, files_instance_id, "ready_transient", 200)

  let files_card =
    http_client.request_sync_string(
      http.Get,
      base_url
        <> "/instances/"
        <> files_instance_id
        <> "/.well-known/agent-card.json",
      tasks_helpers.auth_headers(),
      None,
      5000,
      1024 * 1024,
    )
    |> test_assertions.assert_ok

  files_card.status |> should.equal(200)
  string.contains(files_card.body, "\"inputModes\":[\"file\"]")
  |> should.equal(True)

  let chat_instance_id = "inst-a2a-chat-input"
  tasks_helpers.create_agent(base_url, "echo_cli", chat_instance_id)
  tasks_helpers.wait_phase(base_url, chat_instance_id, "ready_transient", 200)

  let chat_card =
    http_client.request_sync_string(
      http.Get,
      base_url
        <> "/instances/"
        <> chat_instance_id
        <> "/.well-known/agent-card.json",
      tasks_helpers.auth_headers(),
      None,
      5000,
      1024 * 1024,
    )
    |> test_assertions.assert_ok

  chat_card.status |> should.equal(200)
  string.contains(chat_card.body, "\"inputModes\":[\"text\"]")
  |> should.equal(True)
}

pub fn agent_card_skill_output_modes_include_data_for_files() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-a2a-files-output"
  tasks_helpers.create_agent(base_url, "echo_files_eventual", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/instances/" <> instance_id <> "/.well-known/agent-card.json",
      tasks_helpers.auth_headers(),
      None,
      5000,
      1024 * 1024,
    )
    |> test_assertions.assert_ok

  resp.status |> should.equal(200)
  string.contains(resp.body, "\"outputModes\":[\"text\",\"data\"]")
  |> should.equal(True)
}

pub fn agent_card_skill_extensions_include_max_files_and_ingest_effect() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-a2a-files-ext"
  tasks_helpers.create_agent(base_url, "echo_files_eventual", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/instances/" <> instance_id <> "/.well-known/agent-card.json",
      tasks_helpers.auth_headers(),
      None,
      5000,
      1024 * 1024,
    )
    |> test_assertions.assert_ok

  resp.status |> should.equal(200)
  string.contains(resp.body, "\"urn:saar:extensions:files-semantics:v1\"")
  |> should.equal(True)
  string.contains(resp.body, "\"maxFiles\":1") |> should.equal(True)
  string.contains(resp.body, "\"ingestEffect\":\"eventual\"")
  |> should.equal(True)
}

pub fn agent_card_root_extensions_advertises_files_semantics_uri() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-a2a-files-root-ext"
  tasks_helpers.create_agent(base_url, "echo_files_eventual", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/instances/" <> instance_id <> "/.well-known/agent-card.json",
      tasks_helpers.auth_headers(),
      None,
      5000,
      1024 * 1024,
    )
    |> test_assertions.assert_ok

  resp.status |> should.equal(200)
  string.contains(
    resp.body,
    "\"extensions\":[\"urn:saar:extensions:files-semantics:v1\"]",
  )
  |> should.equal(True)
}
