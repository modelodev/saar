import gleam/string
import gleeunit
import gleeunit/should
import saar/types/config as types_config
import tasks_helpers

pub fn main() {
  gleeunit.main()
}

pub fn create_task_when_max_tasks_reached_returns_infra_error() {
  let cfg0 = tasks_helpers.load_cfg0()
  let cfg1 = cfg_with_max_tasks(cfg0, 1)
  let base_url = tasks_helpers.start_saar_with_cfg(cfg1)

  let instance_id = "inst-tasks-max"
  tasks_helpers.create_agent(base_url, "echo_cli_deferred", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp1 =
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-max-tasks-1",
      "hi",
    )

  resp1.status |> should.equal(202)

  let resp2 =
    tasks_helpers.post_deferred(
      base_url,
      instance_id,
      "echo",
      "trace-max-tasks-2",
      "hi",
    )

  resp2.status |> should.equal(500)
  should.equal(string.contains(resp2.body, "max tasks reached"), True)
}

fn cfg_with_max_tasks(
  cfg0: types_config.SaarConfig,
  max_tasks: Int,
) -> types_config.SaarConfig {
  let types_config.SaarConfig(limits: limits, ..) = cfg0
  let next_limits = types_config.SaarLimits(..limits, max_tasks: max_tasks)
  types_config.SaarConfig(..cfg0, limits: next_limits)
}
