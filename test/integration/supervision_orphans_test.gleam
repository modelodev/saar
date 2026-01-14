import agent_helpers
import gleam/dict
import gleam/erlang/process
import gleam/otp/actor
import gleeunit
import gleeunit/should
import sad/app_state
import sad/core/agent
import sad/core/boundary_call
import sad/core/messages
import sad/core/root_supervisor
import sad/core/supervisor_names
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/profile as types_profile
import test_assertions

pub fn main() {
  gleeunit.main()
}

pub fn registry_crash_rest_for_one_kills_and_restarts_subtree_test() {
  let cfg = agent_helpers.default_config()
  let names = supervisor_names.new_names()
  let state = app_state.AppState(config: cfg, initial_profiles: dict.new())

  let assert Ok(actor.Started(..)) = root_supervisor.start(state, names)

  let supervisor_names.RootNames(registry_name, _, _, _, agent_manager_name, _) =
    names

  let registry_subject = process.named_subject(registry_name)
  let manager_subject = process.named_subject(agent_manager_name)

  let assert Ok(manager_pid_before) = process.subject_owner(manager_subject)

  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-orphans-1")

  let agent_ref = start_instance(manager_subject, profile, instance_id, cfg)

  let agent_monitor = process.monitor(agent.pid(agent_ref))

  // Crash the registry; RestForOne must restart later children (including manager and agents).
  // Note: This uses `process.kill`, so OTP may print supervisor reports (expected).
  let assert Ok(registry_pid) = process.subject_owner(registry_subject)
  process.kill(registry_pid)

  let selector =
    process.new_selector()
    |> process.select_specific_monitor(agent_monitor, fn(down) { down })

  let assert Ok(process.ProcessDown(..)) =
    process.selector_receive(selector, 2000)

  process.sleep(50)

  let assert Ok(manager_pid_after) = process.subject_owner(manager_subject)
  manager_pid_after |> should.not_equal(manager_pid_before)
}

pub fn killing_agent_manager_actor_kills_agents_test() {
  let cfg = agent_helpers.default_config()
  let names = supervisor_names.new_names()
  let state = app_state.AppState(config: cfg, initial_profiles: dict.new())

  let assert Ok(actor.Started(..)) = root_supervisor.start(state, names)

  let supervisor_names.RootNames(_, _, _, _, agent_manager_name, _) = names

  let manager_subject = process.named_subject(agent_manager_name)

  let assert Ok(manager_pid) = process.subject_owner(manager_subject)

  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-orphans-2")

  let agent_ref = start_instance(manager_subject, profile, instance_id, cfg)

  let agent_monitor = process.monitor(agent.pid(agent_ref))

  // Note: This uses `process.kill`, so OTP may print supervisor reports (expected).
  process.kill(manager_pid)

  let selector =
    process.new_selector()
    |> process.select_specific_monitor(agent_monitor, fn(down) { down })

  let assert Ok(process.ProcessDown(..)) =
    process.selector_receive(selector, 2000)
  Nil
}

fn start_instance(
  manager: process.Subject(messages.AgentManagerMsg),
  profile: types_profile.Profile,
  instance_id: types_core.InstanceId,
  cfg: types_config.SadConfig,
) -> agent.AgentRef {
  let artifact_registry = process.new_subject()

  let args =
    messages.StartArgs(
      profile: profile,
      instance_id: instance_id,
      params: dict.new(),
      workspace: agent_helpers.workspace_root(),
      config: cfg,
      artifact_registry: artifact_registry,
    )

  boundary_call.call_unwrap_result(manager, 5000, fn(reply_to) {
    messages.StartAgent(args, reply_to)
  })
  |> test_assertions.assert_ok
}
