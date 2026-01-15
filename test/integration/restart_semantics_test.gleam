import agent_helpers
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/option
import gleam/otp/actor
import gleeunit
import gleeunit/should
import port_helpers
import sad/app_state
import sad/core/agent
import sad/core/messages
import sad/core/root_supervisor
import sad/core/supervisor_names
import sad/decoders
import sad/net/tcp_listener
import sad/otp/safe_call
import sad/types/agent as types_agent
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/profile as types_profile
import sad/types/runner as types_runner
import simplifile
import test_assertions

pub fn main() {
  gleeunit.main()
}

/// Verifies crash-only recovery behavior:
/// after deleting an instance and restarting AgentManager, the system can start
/// a new managed-port instance without getting stuck.
///
/// This test does not assert that a specific OS port becomes free immediately
/// (external runners can be flaky), but it does assert we never end up in
/// `types_agent.PortPoolExhausted` due to leaked reservations.
pub fn manager_restart_does_not_orphan_port_pool_reservations_test() {
  port_helpers.ensure_wrapper_path()

  let base_port = pick_free_port()

  let cfg =
    agent_helpers.default_config()
    |> config_with_port_range(base_port, base_port + 20)

  let names = supervisor_names.new_names()
  let state = app_state.AppState(config: cfg, initial_profiles: dict.new())

  let assert Ok(actor.Started(..)) = root_supervisor.start(state, names)

  let supervisor_names.RootNames(
    _registry_name,
    _artifact_registry_name,
    _port_pool_name,
    _profiles_name,
    agent_manager_name,
    _agent_factory_name,
    _gateway_shutdown_name,
  ) = names

  let manager = process.named_subject(agent_manager_name)

  let profile = echo_server_profile_managed_port()

  let assert Ok(i1) = types_core.instance_id("inst-restart-pp-1")
  let a1 = start_instance(manager, profile, i1, cfg)
  wait_for_phase(a1, types_agent.ReadyContinuous, 400)

  safe_call.call_unwrap_result(manager, 5000, fn(reply_to) {
    messages.Cmd(messages.DeleteAgent(i1, reply_to))
  })
  |> test_assertions.assert_ok

  // Crash the manager and ensure it comes back.
  // Note: This uses `process.kill`, so OTP may print supervisor reports (expected).
  let assert Ok(pid_before) = process.subject_owner(manager)
  process.kill(pid_before)
  process.sleep(200)
  let assert Ok(pid_after) = process.subject_owner(manager)
  pid_after |> should.not_equal(pid_before)

  // Try to start again; we must not get stuck in types_agent.PortPoolExhausted.
  start_until_ready_continuous(manager, profile, cfg, 20)

  Nil
}

fn pick_free_port() -> Int {
  let assert Ok(#(listener, port)) = tcp_listener.listen("127.0.0.1", 0)
  tcp_listener.close(listener)
  port
}

fn config_with_port_range(
  cfg: types_config.SadConfig,
  min_port: Int,
  max_port: Int,
) -> types_config.SadConfig {
  let types_config.SadConfig(runner: runner_cfg, ..) = cfg

  let next_runner =
    types_config.RunnerSystemConfig(
      ..runner_cfg,
      port_range_min: min_port,
      port_range_max: max_port,
      managed_port_host: "127.0.0.1",
    )

  types_config.SadConfig(..cfg, runner: next_runner)
}

fn echo_server_profile_managed_port() -> types_profile.Profile {
  let assert Ok(raw) =
    simplifile.read("./test/fixtures/source_local/profiles/echo_server.json")

  let assert Ok(profile0) = json.parse(raw, decoders.profile_decoder())

  let types_profile.Profile(runner: runner0, ..) = profile0

  let runtime =
    types_runner.ManagedPort(
      host_env_var: option.None,
      port_env_var: option.None,
    )

  let runner1 =
    types_runner.Runner(
      ..runner0,
      tool_config: types_runner.ToolConfigScript(
        "./test/fixtures/source_local/runners/echo_server.py",
      ),
      runtime: runtime,
    )

  types_profile.Profile(..profile0, runner: runner1)
}

fn start_until_ready_continuous(
  manager: process.Subject(messages.AgentManagerMsg),
  profile: types_profile.Profile,
  cfg: types_config.SadConfig,
  retries: Int,
) -> Nil {
  case retries {
    0 -> panic as "exhausted retries starting managed-port instance"

    _ -> {
      let raw = "inst-restart-pp-2-" <> int.to_string(retries)
      let assert Ok(instance_id) = types_core.instance_id(raw)

      let agent_ref = start_instance(manager, profile, instance_id, cfg)

      case
        wait_for_ready_or_failure(agent_ref, types_agent.ReadyContinuous, 1200)
      {
        Ok(Nil) -> Nil

        Error(option.Some(types_agent.PortPoolExhausted)) ->
          panic as "port_pool_exhausted after manager restart"

        Error(_) -> {
          let _ =
            safe_call.call_unwrap_result(manager, 5000, fn(reply_to) {
              messages.Cmd(messages.DeleteAgent(instance_id, reply_to))
            })

          process.sleep(250)
          start_until_ready_continuous(manager, profile, cfg, retries - 1)
        }
      }
    }
  }
}

fn wait_for_ready_or_failure(
  agent_ref: agent.AgentRef,
  expected_phase: types_agent.AgentPhase,
  attempts: Int,
) -> Result(Nil, option.Option(types_agent.FailureReason)) {
  case attempts {
    0 ->
      case agent.status(agent_ref, 1000) {
        Ok(status) -> Error(types_agent.failure_reason_from_phase(status.phase))
        Error(_) -> Error(option.None)
      }

    _ ->
      case agent.status(agent_ref, 1000) {
        Ok(status) ->
          case status.phase == expected_phase {
            True -> Ok(Nil)

            False ->
              case status.phase {
                types_agent.Failed(reason) -> Error(option.Some(reason))
                _ -> {
                  process.sleep(25)
                  wait_for_ready_or_failure(
                    agent_ref,
                    expected_phase,
                    attempts - 1,
                  )
                }
              }
          }

        Error(_) -> {
          process.sleep(25)
          wait_for_ready_or_failure(agent_ref, expected_phase, attempts - 1)
        }
      }
  }
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

  safe_call.call_unwrap_result(manager, 5000, fn(reply_to) {
    messages.Cmd(messages.StartAgent(args, reply_to))
  })
  |> test_assertions.assert_ok
}

fn wait_for_phase(
  agent_ref: agent.AgentRef,
  phase: types_agent.AgentPhase,
  attempts: Int,
) -> Nil {
  case attempts {
    0 -> panic as "timeout waiting for phase"

    _ ->
      case agent.status(agent_ref, 1000) {
        Ok(status) ->
          case status.phase == phase {
            True -> Nil
            False -> {
              process.sleep(25)
              wait_for_phase(agent_ref, phase, attempts - 1)
            }
          }

        Error(_) -> {
          process.sleep(25)
          wait_for_phase(agent_ref, phase, attempts - 1)
        }
      }
  }
}
