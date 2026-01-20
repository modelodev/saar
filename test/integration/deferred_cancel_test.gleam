import gleam/dict
import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/option
import gleeunit
import gleeunit/should
import saar/bridge/http_client
import tasks_helpers
import test_assertions

pub fn main() {
  gleeunit.main()
}

pub fn delete_task_running_cancels_task_state_cancelled() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-deferred-cancel"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred_slow", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-deferred-cancel",
      "hi",
    )

  resp.status |> should.equal(202)
  let task_id = decode_task_id(resp.body)

  let cancel_resp = delete_task(base_url, task_id)
  cancel_resp.status |> should.equal(200)
  decode_task_state(cancel_resp.body) |> should.equal("cancelled")

  let get_resp = get_task(base_url, task_id)
  decode_task_state(get_resp.body) |> should.equal("cancelled")
}

fn post_deferred(
  base_url: String,
  instance_id: String,
  capability: String,
  trace_id: String,
  content: String,
) -> http_client.HttpResponse {
  let body =
    "{"
    <> "\"capability\":\""
    <> capability
    <> "\","
    <> "\"inputs\":{\"messages\":[{\"role\":\"user\",\"content\":\""
    <> content
    <> "\"}]},"
    <> "\"context\":{\"trace_id\":\""
    <> trace_id
    <> "\"}"
    <> "}"

  http_client.request_sync_string(
    http.Post,
    base_url <> "/agents/" <> instance_id <> "/interact",
    dict.insert(tasks_helpers.auth_headers(), "content-type", "application/json"),
    option.Some(body),
    5000,
    1024 * 1024,
  )
  |> test_assertions.assert_ok
}

fn delete_task(base_url: String, task_id: String) -> http_client.HttpResponse {
  http_client.request_sync_string(
    http.Delete,
    base_url <> "/tasks/" <> task_id,
    tasks_helpers.auth_headers(),
    option.None,
    2000,
    1024 * 1024,
  )
  |> test_assertions.assert_ok
}

fn get_task(base_url: String, task_id: String) -> http_client.HttpResponse {
  http_client.request_sync_string(
    http.Get,
    base_url <> "/tasks/" <> task_id,
    tasks_helpers.auth_headers(),
    option.None,
    2000,
    1024 * 1024,
  )
  |> test_assertions.assert_ok
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
