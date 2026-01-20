////
//// Mission: validate A2A task operations for deferred interactions.
////
//// Responsibilities:
//// - Cover non-blocking `message:send` returning a working task.
//// - Validate A2A task get/cancel/subscribe flows.
////
//// Non-responsibilities:
//// - Validating native `/tasks` APIs.
//// - Validating streaming interaction SSE for A2A messages.
////
//// Relationships:
//// - Uses `test/tasks_helpers.gleam` for server setup.
//// - Uses `saar/bridge/http_client` for HTTP and SSE calls.

import gleam/dict
import gleam/dynamic.{type Dynamic}
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

pub fn a2a_send_non_blocking_returns_working_task() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-a2a-deferred"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    post_a2a_send(
      base_url,
      instance_id,
      "msg-a2a-deferred",
      "hi",
      "conv-a2a-deferred",
    )

  resp.status |> should.equal(200)
  let task_id = decode_task_id_from_result(resp.body)
  let state = decode_task_state_from_result(resp.body)
  should.equal(state, "working")
  string.length(task_id) |> should.not_equal(0)
}

pub fn a2a_get_task_working_then_completed_after_delay() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-a2a-get-task"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred_slow", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    post_a2a_send(
      base_url,
      instance_id,
      "msg-a2a-get-task",
      "hi",
      "conv-a2a-get-task",
    )

  resp.status |> should.equal(200)
  let task_id = decode_task_id_from_result(resp.body)

  let running = get_a2a_task(base_url, instance_id, task_id)
  decode_task_state(running.body) |> should.equal("working")

  let _ = wait_a2a_task_state(base_url, instance_id, task_id, "completed", 40)
  Nil
}

pub fn a2a_get_task_returns_terminal_state() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-a2a-terminal"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    post_a2a_send(
      base_url,
      instance_id,
      "msg-a2a-terminal",
      "hi",
      "conv-a2a-terminal",
    )

  resp.status |> should.equal(200)
  let task_id = decode_task_id_from_result(resp.body)

  let body =
    wait_a2a_task_state(base_url, instance_id, task_id, "completed", 40)
  decode_task_state(body) |> should.equal("completed")
}

pub fn a2a_cancel_task_moves_to_cancelled() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-a2a-cancel"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred_slow", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    post_a2a_send(
      base_url,
      instance_id,
      "msg-a2a-cancel",
      "hi",
      "conv-a2a-cancel",
    )

  resp.status |> should.equal(200)
  let task_id = decode_task_id_from_result(resp.body)

  let cancel_resp = cancel_a2a_task(base_url, instance_id, task_id)
  cancel_resp.status |> should.equal(200)
  decode_task_state(cancel_resp.body) |> should.equal("cancelled")

  let get_resp = get_a2a_task(base_url, instance_id, task_id)
  decode_task_state(get_resp.body) |> should.equal("cancelled")
}

pub fn a2a_subscribe_first_event_is_task_snapshot() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-a2a-subscribe"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred_slow", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    post_a2a_send(
      base_url,
      instance_id,
      "msg-a2a-subscribe",
      "hi",
      "conv-a2a-subscribe",
    )

  resp.status |> should.equal(200)
  let task_id = decode_task_id_from_result(resp.body)

  let conn =
    http_client.open_sse(
      http.Post,
      a2a_task_subscribe_url(base_url, instance_id, task_id),
      tasks_helpers.auth_headers(),
      option.None,
      1000,
    )
    |> test_assertions.assert_ok

  let data = wait_for_sse_data(conn, 60)
  should.equal(string.contains(data, "\"state\":\"working\""), True)
  http_client.close_sse(conn)
}

pub fn a2a_subscribe_closes_on_terminal_state() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-a2a-subscribe-close"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    post_a2a_send(
      base_url,
      instance_id,
      "msg-a2a-subscribe-close",
      "hi",
      "conv-a2a-subscribe-close",
    )

  resp.status |> should.equal(200)
  let task_id = decode_task_id_from_result(resp.body)

  let conn =
    http_client.open_sse(
      http.Post,
      a2a_task_subscribe_url(base_url, instance_id, task_id),
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

fn post_a2a_send(
  base_url: String,
  instance_id: String,
  message_id: String,
  text: String,
  context_id: String,
) -> http_client.HttpResponse {
  let url = base_url <> "/instances/" <> instance_id <> "/a2a/message:send"

  let body =
    "{"
    <> "\"message\":{"
    <> "\"messageId\":\""
    <> message_id
    <> "\","
    <> "\"role\":\"user\","
    <> "\"parts\":[{\"text\":\""
    <> text
    <> "\"}]"
    <> "},"
    <> "\"context\":{"
    <> "\"contextId\":\""
    <> context_id
    <> "\"}"
    <> "}"

  http_client.request_sync_string(
    http.Post,
    url,
    tasks_helpers.auth_headers()
      |> dict.insert("content-type", "application/json"),
    option.Some(body),
    5000,
    1024 * 1024,
  )
  |> test_assertions.assert_ok
}

fn get_a2a_task(
  base_url: String,
  instance_id: String,
  task_id: String,
) -> http_client.HttpResponse {
  http_client.request_sync_string(
    http.Get,
    base_url <> "/instances/" <> instance_id <> "/a2a/tasks/" <> task_id,
    tasks_helpers.auth_headers(),
    option.None,
    2000,
    1024 * 1024,
  )
  |> test_assertions.assert_ok
}

fn cancel_a2a_task(
  base_url: String,
  instance_id: String,
  task_id: String,
) -> http_client.HttpResponse {
  http_client.request_sync_string(
    http.Post,
    base_url
      <> "/instances/"
      <> instance_id
      <> "/a2a/tasks/"
      <> task_id
      <> ":cancel",
    tasks_helpers.auth_headers(),
    option.None,
    2000,
    1024 * 1024,
  )
  |> test_assertions.assert_ok
}

fn a2a_task_subscribe_url(
  base_url: String,
  instance_id: String,
  task_id: String,
) -> String {
  base_url
  <> "/instances/"
  <> instance_id
  <> "/a2a/tasks/"
  <> task_id
  <> ":subscribe"
}

fn wait_a2a_task_state(
  base_url: String,
  instance_id: String,
  task_id: String,
  expected_state: String,
  attempts: Int,
) -> String {
  case attempts {
    0 -> panic as "Timed out waiting for task state"

    _ -> {
      let resp = get_a2a_task(base_url, instance_id, task_id)
      let state = decode_task_state(resp.body)

      case state == expected_state {
        True -> resp.body
        False -> {
          process.sleep(50)
          wait_a2a_task_state(
            base_url,
            instance_id,
            task_id,
            expected_state,
            attempts - 1,
          )
        }
      }
    }
  }
}

fn wait_for_sse_data(conn: http_client.SseConnection, attempts: Int) -> String {
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

fn decode_task_id_from_result(body: String) -> String {
  let dynamic_body = parse_dynamic(body)
  let decoder = {
    use result <- decode.field("result", decode.dynamic)
    decode.success(result)
  }

  let result = decode.run(dynamic_body, decoder) |> test_assertions.assert_ok

  let id_decoder = {
    use id <- decode.field("id", decode.string)
    decode.success(id)
  }

  decode.run(result, id_decoder) |> test_assertions.assert_ok
}

fn decode_task_state_from_result(body: String) -> String {
  let dynamic_body = parse_dynamic(body)
  let decoder = {
    use result <- decode.field("result", decode.dynamic)
    decode.success(result)
  }

  let result = decode.run(dynamic_body, decoder) |> test_assertions.assert_ok
  decode_task_state_from_dynamic(result)
}

fn decode_task_state(body: String) -> String {
  let dynamic_body = parse_dynamic(body)
  decode_task_state_from_dynamic(dynamic_body)
}

fn decode_task_state_from_dynamic(dynamic_body: Dynamic) -> String {
  let decoder = {
    use status <- decode.field("status", decode.dynamic)
    decode.success(status)
  }

  let status = decode.run(dynamic_body, decoder) |> test_assertions.assert_ok

  let state_decoder = {
    use state <- decode.field("state", decode.string)
    decode.success(state)
  }

  decode.run(status, state_decoder) |> test_assertions.assert_ok
}

fn parse_dynamic(body: String) -> Dynamic {
  json.parse(body, decode.dynamic) |> test_assertions.assert_ok
}
