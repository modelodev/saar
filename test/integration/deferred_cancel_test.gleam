import gleam/dynamic/decode
import gleam/erlang/process
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
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-deferred-cancel",
      "hi",
    )

  resp.status |> should.equal(202)
  let task_id = decode_task_id(resp.body)

  let cancel_resp = tasks_helpers.delete_task(base_url, task_id)
  cancel_resp.status |> should.equal(200)
  decode_task_state(cancel_resp.body) |> should.equal("cancelled")

  let get_resp = tasks_helpers.get_task(base_url, task_id)
  decode_task_state(get_resp.body) |> should.equal("cancelled")
}

pub fn stop_instance_cancels_running_task_state_cancelled() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-deferred-stop"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred_slow", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-deferred-stop",
      "hi",
    )

  resp.status |> should.equal(202)
  let task_id = decode_task_id(resp.body)

  let _ = stop_instance(base_url, instance_id)
  let _ = wait_task_state(base_url, task_id, "cancelled", 40)
  Nil
}

pub fn delete_instance_cancels_running_task_state_cancelled() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-deferred-delete-instance"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred_slow", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-deferred-delete-instance",
      "hi",
    )

  resp.status |> should.equal(202)
  let task_id = decode_task_id(resp.body)

  let _ = delete_instance(base_url, instance_id)
  let _ = wait_task_state(base_url, task_id, "cancelled", 40)
  Nil
}

fn stop_instance(base_url: String, instance_id: String) -> Nil {
  http_client.request_sync_string(
    http.Post,
    base_url <> "/sys/agents/" <> instance_id <> "/stop",
    tasks_helpers.auth_headers(),
    option.None,
    2000,
    1024 * 1024,
  )
  |> test_assertions.assert_ok
  |> fn(resp) { resp.status |> should.equal(202) }

  Nil
}

fn delete_instance(base_url: String, instance_id: String) -> Nil {
  http_client.request_sync_string(
    http.Delete,
    base_url <> "/sys/agents/" <> instance_id,
    tasks_helpers.auth_headers(),
    option.None,
    2000,
    1024 * 1024,
  )
  |> test_assertions.assert_ok
  |> fn(resp) { resp.status |> should.equal(200) }

  Nil
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
