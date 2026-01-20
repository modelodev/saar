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

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/json
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
  let task_id = decode_task_id(resp.body)

  let conn =
    http_client.open_sse(
      http.Get,
      base_url <> "/tasks/" <> task_id <> "/subscribe",
      tasks_helpers.auth_headers(),
      option.None,
      1000,
    )
    |> test_assertions.assert_ok

  let data = wait_for_sse_data(conn, 60)
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
  let task_id = decode_task_id(resp.body)

  let conn =
    http_client.open_sse(
      http.Get,
      base_url <> "/tasks/" <> task_id <> "/subscribe",
      tasks_helpers.auth_headers(),
      option.None,
      1000,
    )
    |> test_assertions.assert_ok

  let _ = wait_for_sse_data(conn, 60)
  let terminal = wait_for_sse_data(conn, 120)
  should.equal(string.contains(terminal, "\"state\":\"completed\""), True)
  wait_for_sse_close(conn, 120)
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
  let task_id = decode_task_id(resp.body)

  let _ = wait_task_state(base_url, task_id, "completed", 40)

  let conn =
    http_client.open_sse(
      http.Get,
      base_url <> "/tasks/" <> task_id <> "/subscribe",
      tasks_helpers.auth_headers(),
      option.None,
      1000,
    )
    |> test_assertions.assert_ok

  let snapshot = wait_for_sse_data(conn, 60)
  should.equal(string.contains(snapshot, "\"state\":\"completed\""), True)
  wait_for_sse_close(conn, 60)
}

fn wait_for_sse_data(
  conn: http_client.SseConnection,
  attempts: Int,
) -> String {
  case attempts {
    0 -> panic as "Timed out waiting for SSE data"

    _ ->
      case http_client.sse_receive(conn, 200) {
        http_client.SseTimeout -> wait_for_sse_data(conn, attempts - 1)
        http_client.SseClosed -> panic as "SSE closed before data"
        http_client.SseData(data) -> data
      }
  }
}

fn wait_for_sse_close(conn: http_client.SseConnection, attempts: Int) -> Nil {
  case attempts {
    0 -> panic as "Timed out waiting for SSE close"

    _ ->
      case http_client.sse_receive(conn, 200) {
        http_client.SseTimeout -> wait_for_sse_close(conn, attempts - 1)
        http_client.SseClosed -> Nil
        http_client.SseData(_) -> wait_for_sse_close(conn, attempts - 1)
      }
  }
}

fn wait_task_state(
  base_url: String,
  task_id: String,
  expected_state: String,
  attempts: Int,
) -> String {
  case attempts {
    0 -> panic as "Timed out waiting for task state"

    _ -> {
      let resp = tasks_helpers.get_task(base_url, task_id)
      let state = decode_task_state(resp.body)

      case state == expected_state {
        True -> resp.body
        False -> {
          process.sleep(50)
          wait_task_state(base_url, task_id, expected_state, attempts - 1)
        }
      }
    }
  }
}

fn decode_task_id(body: String) -> String {
  let dynamic_body = parse_dynamic(body)
  let decoder = {
    use task_id <- decode.field("task_id", decode.string)
    decode.success(task_id)
  }
  decode.run(dynamic_body, decoder) |> test_assertions.assert_ok
}

fn decode_task_state(body: String) -> String {
  let dynamic_body = parse_dynamic(body)
  let decoder = {
    use state <- decode.field("state", decode.string)
    decode.success(state)
  }
  decode.run(dynamic_body, decoder) |> test_assertions.assert_ok
}

fn parse_dynamic(body: String) {
  json.parse(body, decode.dynamic) |> test_assertions.assert_ok
}
