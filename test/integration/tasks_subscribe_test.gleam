////
//// Mission: verify deferred task SSE subscription behavior.
////
//// Responsibilities:
//// - Assert snapshot-first semantics for task subscriptions.
//// - Assert streams close on terminal task states.
//// - Assert terminal snapshots for already-completed tasks.
////
//// Non-responsibilities:
//// - Validating streaming interaction SSE payloads.
//// - Testing A2A task subscription behavior.
////
//// Relationships:
//// - Uses `test/tasks_helpers.gleam` for task lifecycle setup.
//// - Uses `saar/bridge/http_client` SSE client for subscriptions.

import gleam/http
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should
import saar/bridge/http_client
import tasks_helpers
import test_assertions

pub fn main() {
  gleeunit.main()
}

pub fn subscribe_first_event_is_task_snapshot() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-deferred-subscribe"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred_slow", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-deferred-subscribe",
      "hi",
    )

  resp.status |> should.equal(202)
  let task_id = tasks_helpers.decode_task_id(resp.body)

  let conn =
    http_client.open_sse(
      http.Get,
      base_url <> "/tasks/" <> task_id <> "/subscribe",
      tasks_helpers.auth_headers(),
      option.None,
      1000,
    )
    |> test_assertions.assert_ok

  let data = tasks_helpers.wait_for_sse_data(conn, 60)
  should.equal(string.contains(data, "\"state\":\"running\""), True)
  http_client.close_sse(conn)
}

pub fn subscribe_closes_on_terminal_state() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-deferred-subscribe-close"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-deferred-subscribe-close",
      "hi",
    )

  resp.status |> should.equal(202)
  let task_id = tasks_helpers.decode_task_id(resp.body)

  let conn =
    http_client.open_sse(
      http.Get,
      base_url <> "/tasks/" <> task_id <> "/subscribe",
      tasks_helpers.auth_headers(),
      option.None,
      1000,
    )
    |> test_assertions.assert_ok

  let _ = tasks_helpers.wait_for_sse_data(conn, 60)
  let terminal = tasks_helpers.wait_for_sse_data(conn, 120)
  should.equal(string.contains(terminal, "\"state\":\"completed\""), True)
  tasks_helpers.wait_for_sse_close(conn, 120)
}

pub fn subscribe_after_completion_returns_terminal_snapshot_immediately() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-deferred-subscribe-done"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-deferred-subscribe-done",
      "hi",
    )

  resp.status |> should.equal(202)
  let task_id = tasks_helpers.decode_task_id(resp.body)

  let _ = tasks_helpers.wait_task_state(base_url, task_id, "completed", 40)

  let conn =
    http_client.open_sse(
      http.Get,
      base_url <> "/tasks/" <> task_id <> "/subscribe",
      tasks_helpers.auth_headers(),
      option.None,
      1000,
    )
    |> test_assertions.assert_ok

  let snapshot = tasks_helpers.wait_for_sse_data(conn, 60)
  should.equal(string.contains(snapshot, "\"state\":\"completed\""), True)
  tasks_helpers.wait_for_sse_close(conn, 60)
}

pub fn subscribe_missing_task_returns_404() {
  let base_url = tasks_helpers.start_saar()

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/tasks/missing-task/subscribe",
      tasks_helpers.auth_headers(),
      option.None,
      1000,
      1024 * 1024,
    )
    |> test_assertions.assert_ok

  resp.status |> should.equal(404)
}
