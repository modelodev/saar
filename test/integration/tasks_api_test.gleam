import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should
import tasks_helpers
import test_assertions

pub fn main() {
  gleeunit.main()
}

pub fn post_deferred_returns_202_and_task_id() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-deferred-202"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-deferred-202",
      "hi",
    )

  resp.status |> should.equal(202)

  let task_id = decode_task_id(resp.body)
  string.length(task_id) |> should.not_equal(0)
}

pub fn post_deferred_when_busy_returns_422_agent_busy() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-deferred-busy"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred_slow", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp1 =
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-deferred-busy-1",
      "hi",
    )

  resp1.status |> should.equal(202)
  let task_id = decode_task_id(resp1.body)

  let resp2 =
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-deferred-busy-2",
      "hi",
    )

  resp2.status |> should.equal(422)
  should.equal(string.contains(resp2.body, "\"kind\":\"agent_error\""), True)

  let _ = tasks_helpers.delete_task(base_url, task_id)
  Nil
}

pub fn get_task_404_when_missing() {
  let base_url = tasks_helpers.start_saar()

  let resp = tasks_helpers.get_task_raw(base_url, "missing-task")

  resp.status |> should.equal(404)
}

pub fn get_task_running_then_completed_after_delay() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-deferred-running"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-deferred-running",
      "hi",
    )

  resp.status |> should.equal(202)
  let task_id = decode_task_id(resp.body)

  let running = tasks_helpers.get_task(base_url, task_id)
  let running_state = decode_task_state(running.body)
  running_state |> should.equal("running")

  let _ = wait_task_state(base_url, task_id, "completed", 40)
  Nil
}

pub fn get_task_eventually_completed_contains_result() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-deferred-completed"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-deferred-completed",
      "hello",
    )

  resp.status |> should.equal(202)
  let task_id = decode_task_id(resp.body)

  let body = wait_task_state(base_url, task_id, "completed", 40)
  let result_present = decode_task_result_present(body)
  result_present |> should.equal(True)
}

pub fn get_task_completed_includes_artifacts() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-deferred-artifacts"
  tasks_helpers.create_agent(base_url, "artifact_gen_deferred", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "generate",
      "trace-deferred-artifacts",
      "hello",
    )

  resp.status |> should.equal(202)
  let task_id = decode_task_id(resp.body)

  let body = wait_task_state(base_url, task_id, "completed", 40)
  should.equal(string.contains(body, "report.pdf"), True)
}

pub fn task_failed_state_when_agent_errors() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-deferred-error"
  tasks_helpers.create_agent(base_url, "error_cli_deferred", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-deferred-error",
      "hi",
    )

  resp.status |> should.equal(202)
  let task_id = decode_task_id(resp.body)

  let body = wait_task_state(base_url, task_id, "failed", 40)
  let err_kind = decode_task_error_kind(body)
  err_kind |> should.equal(option.Some("agent_error"))
}

pub fn delete_task_terminal_removes_task() {
  let base_url = tasks_helpers.start_saar()

  let instance_id = "inst-deferred-delete"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-deferred-delete",
      "hi",
    )

  resp.status |> should.equal(202)
  let task_id = decode_task_id(resp.body)

  let _ = wait_task_state(base_url, task_id, "completed", 40)

  let delete_resp = tasks_helpers.delete_task(base_url, task_id)
  delete_resp.status |> should.equal(204)

  let after_delete = tasks_helpers.get_task_raw(base_url, task_id)
  after_delete.status |> should.equal(404)
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

fn decode_task_result_present(body: String) -> Bool {
  let dynamic_body = parse_dynamic(body)
  let decoder = {
    use result <- decode.field("result", decode.optional(decode.dynamic))
    decode.success(result)
  }
  case decode.run(dynamic_body, decoder) |> test_assertions.assert_ok {
    option.Some(_) -> True
    option.None -> False
  }
}

fn decode_task_error_kind(body: String) -> option.Option(String) {
  let dynamic_body = parse_dynamic(body)
  let decoder = {
    use err <- decode.field("error", decode.optional(decode.dynamic))
    decode.success(err)
  }

  case decode.run(dynamic_body, decoder) |> test_assertions.assert_ok {
    option.None -> option.None
    option.Some(err_dyn) -> {
      let err_decoder = {
        use kind <- decode.field("kind", decode.string)
        decode.success(kind)
      }

      decode.run(err_dyn, err_decoder)
      |> test_assertions.assert_ok
      |> option.Some
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

fn parse_dynamic(body: String) {
  json.parse(body, decode.dynamic) |> test_assertions.assert_ok
}
