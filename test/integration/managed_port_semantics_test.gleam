import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/otp/actor
import gleeunit
import gleeunit/should
import port_helpers
import runner_fixtures
import sad/app_state
import sad/bridge/http_client
import sad/bridge/runner
import sad/core/agent
import sad/otp/safe_call
import sad/core/messages
import sad/core/root_supervisor
import sad/core/supervisor_names
import sad/decoders
import sad/net/tcp_listener
import sad/types/agent as types_agent
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/input as types_input
import sad/types/profile as types_profile
import sad/types/runner as types_runner
import simplifile
import test_assertions

const host = "127.0.0.1"

pub fn main() {
  gleeunit.main()
}

pub fn managed_port_exhaustion_transitions_to_failed_test() {
  port_helpers.ensure_wrapper_path()

  let port = pick_free_port()
  let cfg = config_with_port_range(port)

  let manager = start_root(cfg)
  let profile = echo_server_profile_managed_port()

  let assert Ok(id1) = types_core.instance_id("inst-exhaust-1")
  let assert Ok(id2) = types_core.instance_id("inst-exhaust-2")

  let a1 = start_instance(manager, profile, id1, cfg)
  wait_for_phase(a1, types_agent.ReadyContinuous, 200)

  let a2 = start_instance(manager, profile, id2, cfg)
  wait_for_failure_reason(a2, types_agent.PortPoolExhausted, 200)
  Nil
}

pub fn managed_port_in_use_transitions_to_failed_test() {
  port_helpers.ensure_wrapper_path()

  let port = pick_free_port()
  let cfg = config_with_port_range(port)

  // Occupy the port to force `types_agent.PortInUse`.
  let assert Ok(#(listener, _)) = tcp_listener.listen(host, port)

  let manager = start_root(cfg)
  let profile = echo_server_profile_managed_port()

  let assert Ok(id1) = types_core.instance_id("inst-inuse-1")

  let a1 = start_instance(manager, profile, id1, cfg)
  wait_for_failure_reason(a1, types_agent.PortInUse, 200)

  tcp_listener.close(listener)
  Nil
}

pub fn managed_port_bind_failed_transitions_to_failed_test() {
  port_helpers.ensure_wrapper_path()

  let port = pick_free_port()

  let cfg =
    config_with_port_range(port)
    |> config_with_managed_host("invalid-host")

  let manager = start_root(cfg)
  let profile = echo_server_profile_managed_port()

  let assert Ok(id1) = types_core.instance_id("inst-bindfail-1")

  let a1 = start_instance(manager, profile, id1, cfg)
  wait_for_failure_reason(a1, types_agent.PortBindFailed, 200)
  Nil
}

pub fn port_injected_into_env_test() {
  port_helpers.ensure_wrapper_path()

  let #(server, port, _trace_id) =
    start_echo_server_with_runtime(types_runner.ManagedPort(
      host_env_var: Some("TEST_HOST"),
      port_env_var: Some("TEST_PORT"),
    ))

  let url = "http://" <> host <> ":" <> int.to_string(port) <> "/env"

  let resp =
    http_client.request_sync_string(http.Get, url, dict.new(), None, 1000, 4096)
    |> test_assertions.assert_ok

  runner.stop_server(server)

  let assert Ok(dynamic_env) = json.parse(resp.body, decode.dynamic)

  let decoder = {
    use sad_host <- decode.field("SAD_HOST", decode.optional(decode.string))
    use sad_port <- decode.field("SAD_PORT", decode.optional(decode.string))
    use test_host <- decode.field("TEST_HOST", decode.optional(decode.string))
    use test_port <- decode.field("TEST_PORT", decode.optional(decode.string))
    decode.success(#(sad_host, sad_port, test_host, test_port))
  }

  let assert Ok(#(
    Some(sad_host),
    Some(sad_port),
    Some(test_host),
    Some(test_port),
  )) = decode.run(dynamic_env, decoder)

  sad_host |> should.equal(host)
  test_host |> should.equal(host)
  sad_port |> should.equal(int.to_string(port))
  test_port |> should.equal(int.to_string(port))
}

pub fn base_url_interpolation_uses_runner_host_port_test() {
  port_helpers.ensure_wrapper_path()

  let port = pick_free_port()
  let cfg = config_with_port_range(port)

  let manager = start_root(cfg)
  let profile = echo_server_profile_managed_port()

  let assert Ok(id1) = types_core.instance_id("inst-base-url-1")

  let a1 = start_instance(manager, profile, id1, cfg)
  wait_for_phase(a1, types_agent.ReadyContinuous, 200)

  // If base_url interpolation is correct, the server is reachable on the assigned port.
  let url = "http://" <> host <> ":" <> int.to_string(port) <> "/health"

  let resp =
    http_client.request_sync_string(http.Get, url, dict.new(), None, 1000, 1024)
    |> test_assertions.assert_ok

  resp.status |> should.equal(200)
}

pub fn managed_port_in_use_fails_fast_test() {
  port_helpers.ensure_wrapper_path()

  let port = pick_free_port()
  let cfg = config_with_port_range(port)

  // Occupy the port to force `types_agent.PortInUse`.
  let assert Ok(#(listener, _)) = tcp_listener.listen(host, port)

  let manager = start_root(cfg)
  let profile = echo_server_profile_managed_port()

  let assert Ok(id1) = types_core.instance_id("inst-fast-inuse-1")

  let a1 = start_instance(manager, profile, id1, cfg)
  // Expect a fast transition: no prolonged retries.
  wait_for_failure_reason(a1, types_agent.PortInUse, 30)

  tcp_listener.close(listener)
  Nil
}

pub fn managed_port_race_fails_fast_test() {
  port_helpers.ensure_wrapper_path()

  let port = pick_free_port()
  let cfg = config_with_port_range(port)

  let manager = start_root(cfg)
  let profile = echo_server_profile_managed_port()

  let assert Ok(id1) = types_core.instance_id("inst-race-1")

  // Try to occupy the port concurrently with provisioning.
  let occupied = process.new_subject()
  let _ = process.spawn(fn() { occupy_port_with_retries(port, occupied, 200) })

  let a1 = start_instance(manager, profile, id1, cfg)

  // We accept either outcome as long as it resolves quickly:
  // - ReadyContinuous when no race happens
  // - Failed with PortInUse/PortBindFailed when the race is hit
  wait_for_ready_or_failed_reason_any(
    a1,
    types_agent.ReadyContinuous,
    types_agent.PortInUse,
    types_agent.PortBindFailed,
    200,
  )

  case process.receive(occupied, 0) {
    Ok(listener) -> tcp_listener.close(listener)
    Error(_) -> Nil
  }

  Nil
}

fn start_root(
  cfg: types_config.SadConfig,
) -> process.Subject(messages.AgentManagerMsg) {
  let cfg = types_config.SadConfig(..cfg, server_port: 0)

  let names = supervisor_names.new_names()
  let state = app_state.AppState(config: cfg, initial_profiles: dict.new())

  let assert Ok(actor.Started(..)) = root_supervisor.start(state, names)

  let supervisor_names.RootNames(_, _, _, _, agent_manager_name, _) = names
  process.named_subject(agent_manager_name)
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
      workspace: "./workspaces/test",
      config: cfg,
      artifact_registry: artifact_registry,
    )

  safe_call.call_unwrap_result(manager, 30_000, fn(reply_to) {
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
    0 -> panic as "Timed out waiting for phase"

    _ -> {
      let status = agent.status(agent_ref, 1000) |> test_assertions.assert_ok
      case status.phase == phase {
        True -> Nil
        False -> {
          process.sleep(20)
          wait_for_phase(agent_ref, phase, attempts - 1)
        }
      }
    }
  }
}

fn wait_for_failure_reason(
  agent_ref: agent.AgentRef,
  expected: types_agent.FailureReason,
  attempts: Int,
) -> Nil {
  case attempts {
    0 -> panic as "Timed out waiting for failure reason"

    _ -> {
      let status = agent.status(agent_ref, 1000) |> test_assertions.assert_ok

      case status.phase {
        types_agent.Failed(reason) ->
          case reason == expected {
            True -> Nil
            False -> {
              process.sleep(20)
              wait_for_failure_reason(agent_ref, expected, attempts - 1)
            }
          }

        _ -> {
          process.sleep(20)
          wait_for_failure_reason(agent_ref, expected, attempts - 1)
        }
      }
    }
  }
}

fn wait_for_ready_or_failed_reason_any(
  agent_ref: agent.AgentRef,
  ready_phase: types_agent.AgentPhase,
  expected_a: types_agent.FailureReason,
  expected_b: types_agent.FailureReason,
  attempts: Int,
) -> Nil {
  case attempts {
    0 -> panic as "Timed out waiting for ready/failed"

    _ -> {
      let status = agent.status(agent_ref, 1000) |> test_assertions.assert_ok

      case status.phase == ready_phase {
        True -> Nil
        False ->
          case status.phase {
            types_agent.Failed(reason) ->
              case reason == expected_a || reason == expected_b {
                True -> Nil
                False -> panic as types_agent.failure_reason_to_string(reason)
              }

            _ -> {
              process.sleep(20)
              wait_for_ready_or_failed_reason_any(
                agent_ref,
                ready_phase,
                expected_a,
                expected_b,
                attempts - 1,
              )
            }
          }
      }
    }
  }
}

fn occupy_port_with_retries(
  port: Int,
  reply_to: process.Subject(tcp_listener.Listener),
  attempts: Int,
) -> Nil {
  case attempts {
    0 -> Nil

    _ ->
      case tcp_listener.listen(host, port) {
        Ok(#(listener, _)) -> {
          process.send(reply_to, listener)
          Nil
        }

        Error(_) -> {
          process.sleep(1)
          occupy_port_with_retries(port, reply_to, attempts - 1)
        }
      }
  }
}

fn pick_free_port() -> Int {
  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)
  tcp_listener.close(listener)
  port
}

fn config_with_port_range(port: Int) -> types_config.SadConfig {
  let cfg0 = types_config.default_sad_config()

  let types_config.SadConfig(runner: runner0, timeouts: timeouts0, ..) = cfg0

  let runner =
    types_config.RunnerSystemConfig(
      ..runner0,
      port_range_min: port,
      port_range_max: port,
      managed_port_host: host,
    )

  // Keep these tests fast.
  let timeouts = types_config.SadTimeouts(..timeouts0, shutdown_timeout_ms: 250)

  types_config.SadConfig(..cfg0, runner: runner, timeouts: timeouts)
}

fn config_with_managed_host(
  cfg0: types_config.SadConfig,
  managed_host: String,
) -> types_config.SadConfig {
  let types_config.SadConfig(runner: runner0, ..) = cfg0
  let runner =
    types_config.RunnerSystemConfig(..runner0, managed_port_host: managed_host)
  types_config.SadConfig(..cfg0, runner: runner)
}

fn echo_server_profile_managed_port() -> types_profile.Profile {
  let assert Ok(raw) =
    simplifile.read("./test/fixtures/source_local/profiles/echo_server.json")

  let assert Ok(profile0) = json.parse(raw, decoders.profile_decoder())

  let types_profile.Profile(runner: runner0, ..) = profile0

  let runtime =
    types_runner.ManagedPort(host_env_var: None, port_env_var: None)

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

fn start_echo_server_with_runtime(
  runtime: types_runner.RuntimeConfig,
) -> #(runner.ServerHandle, Int, types_core.TraceId) {
  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)
  tcp_listener.close(listener)

  let config = types_config.default_sad_config()
  let input = base_input_with_runtime(runtime)

  let env = port_helpers.base_env(500, [])

  let server =
    runner.start_server(
      "python3",
      ["./test/fixtures/source_local/runners/echo_server.py"],
      env,
      ".",
      input,
      config,
      Some(port),
    )
    |> test_assertions.assert_ok

  port_helpers.wait_for_http_200(
    "http://" <> host <> ":" <> int.to_string(port) <> "/health",
    40,
    25,
  )

  #(server, port, input.context.trace_id)
}

fn base_input_with_runtime(
  runtime: types_runner.RuntimeConfig,
) -> types_input.SadInput {
  let base_input =
    runner_fixtures.base_input(
      runner_fixtures.default_chat_payload(),
      types_runner.ArtifactConfig(include: [], exclude: []),
    )

  types_input.SadInput(
    ..base_input,
    runner_def: types_runner.Runner(..base_input.runner_def, runtime: runtime),
  )
}
