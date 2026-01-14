import agent_helpers
import filepath
import gleam/dict
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/otp/actor
import gleeunit
import gleeunit/should
import port_helpers
import sad/app_state
import sad/core/agent
import sad/core/artifact_registry_protocol
import sad/core/boundary_call
import sad/core/messages
import sad/core/root_supervisor
import sad/core/supervisor_names
import sad/decoders
import sad/net/tcp_listener
import sad/types/agent as types_agent
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/profile as types_profile
import sad/types/runner as types_runner
import sad/workspace
import simplifile
import test_assertions

const host = "127.0.0.1"

pub fn main() {
  gleeunit.main()
}

pub fn stop_releases_managed_port_test() {
  port_helpers.ensure_wrapper_path()

  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)
  let cfg = config_with_port_range(port)

  let #(names, manager, _registry, artifact_registry) = start_root(cfg)
  tcp_listener.close(listener)

  let profile = echo_server_profile_managed_port()

  let assert Ok(id1) = types_core.instance_id("inst-stop-1")
  let assert Ok(id2) = types_core.instance_id("inst-stop-2")

  let a1 = start_instance(manager, artifact_registry, profile, id1, cfg)
  wait_for_phase(a1, types_agent.ReadyContinuous, 400)

  boundary_call.call_unwrap_result(manager, 5000, fn(reply_to) {
    messages.StopAgent(id1, reply_to)
  })
  |> test_assertions.assert_ok

  let a2 = start_instance(manager, artifact_registry, profile, id2, cfg)
  wait_for_phase(a2, types_agent.ReadyContinuous, 400)

  let _ = names
  Nil
}

pub fn delete_purges_artifacts_and_workspace_test() {
  let cfg = config_with_workspace_dir("./build/test-workspaces/delete")

  let #(names, manager, _registry, artifact_registry) = start_root(cfg)

  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-del-1")

  let _agent_ref =
    start_instance(manager, artifact_registry, profile, instance_id, cfg)

  let workspace_dir = workspace_for(cfg, instance_id)
  let file_path = filepath.join(workspace_dir, "artifact.txt")

  let assert Ok(_) = simplifile.create_directory_all(workspace_dir)
  let assert Ok(_) = simplifile.write(to: file_path, contents: "hello")

  let assert Ok(path) = workspace.workspace_path_validate("artifact.txt")

  let artifact_id =
    boundary_call.call(artifact_registry, 1000, fn(reply_to) {
      artifact_registry_protocol.RegisterArtifact(
        path,
        "text/plain",
        instance_id,
        reply_to,
      )
    })
    |> test_assertions.assert_ok

  boundary_call.call_unwrap_result(manager, 5000, fn(reply_to) {
    messages.DeleteAgent(instance_id, reply_to)
  })
  |> test_assertions.assert_ok

  boundary_call.call(artifact_registry, 1000, fn(reply_to) {
    artifact_registry_protocol.LookupArtifact(artifact_id, reply_to)
  })
  |> should.equal(Ok(None))

  case simplifile.read(file_path) {
    Ok(_) -> panic as "Expected artifact file to be removed"
    Error(simplifile.Enoent) -> Nil
    Error(_) -> Nil
  }

  // Cleanup is recursive.
  case simplifile.delete_all(paths: [workspace_dir]) {
    Ok(_) -> Nil
    Error(simplifile.Enoent) -> Nil
    Error(_) -> Nil
  }

  let _ = names
  Nil
}

pub fn delete_cleanup_failure_returns_500_test() {
  let cfg = config_with_workspace_dir("/dev/null")

  let #(_names, manager, _registry, artifact_registry) = start_root(cfg)

  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-del-fail-1")

  let _ = start_instance(manager, artifact_registry, profile, instance_id, cfg)

  let assert Ok(path) = workspace.workspace_path_validate("x.txt")

  let _artifact_id =
    boundary_call.call(artifact_registry, 1000, fn(reply_to) {
      artifact_registry_protocol.RegisterArtifact(
        path,
        "text/plain",
        instance_id,
        reply_to,
      )
    })
    |> test_assertions.assert_ok

  case
    boundary_call.call_unwrap_result(manager, 5000, fn(reply_to) {
      messages.DeleteAgent(instance_id, reply_to)
    })
  {
    Error(boundary_call.ActorError(messages.CleanupFailed(_))) -> Nil
    _ -> panic as "Expected cleanup failure"
  }
}

pub fn delete_cleanup_failure_still_purges_artifacts_test() {
  let cfg = config_with_workspace_dir("/dev/null")

  let #(_names, manager, _registry, artifact_registry) = start_root(cfg)

  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-del-fail-2")

  let _ = start_instance(manager, artifact_registry, profile, instance_id, cfg)

  let assert Ok(path) = workspace.workspace_path_validate("x.txt")

  let artifact_id =
    boundary_call.call(artifact_registry, 1000, fn(reply_to) {
      artifact_registry_protocol.RegisterArtifact(
        path,
        "text/plain",
        instance_id,
        reply_to,
      )
    })
    |> test_assertions.assert_ok

  let _ =
    boundary_call.call_unwrap_result(manager, 5000, fn(reply_to) {
      messages.DeleteAgent(instance_id, reply_to)
    })

  boundary_call.call(artifact_registry, 1000, fn(reply_to) {
    artifact_registry_protocol.LookupArtifact(artifact_id, reply_to)
  })
  |> should.equal(Ok(None))
}

fn start_root(
  cfg: types_config.SadConfig,
) -> #(
  supervisor_names.RootNames,
  process.Subject(messages.AgentManagerMsg),
  process.Subject(messages.RegistryMsg),
  process.Subject(artifact_registry_protocol.ArtifactRegistryMsg),
) {
  let cfg = types_config.SadConfig(..cfg, server_port: 0)

  let names = supervisor_names.new_names()
  let state = app_state.AppState(config: cfg, initial_profiles: dict.new())

  let assert Ok(actor.Started(..)) = root_supervisor.start(state, names)

  let supervisor_names.RootNames(
    registry_name,
    artifact_registry_name,
    _,
    _,
    agent_manager_name,
    _,
  ) = names

  #(
    names,
    process.named_subject(agent_manager_name),
    process.named_subject(registry_name),
    process.named_subject(artifact_registry_name),
  )
}

fn start_instance(
  manager: process.Subject(messages.AgentManagerMsg),
  artifact_registry: process.Subject(
    artifact_registry_protocol.ArtifactRegistryMsg,
  ),
  profile: types_profile.Profile,
  instance_id: types_core.InstanceId,
  cfg: types_config.SadConfig,
) -> agent.AgentRef {
  let args =
    messages.StartArgs(
      profile: profile,
      instance_id: instance_id,
      params: dict.new(),
      workspace: "./workspaces/test",
      config: cfg,
      artifact_registry: artifact_registry,
    )

  boundary_call.call_unwrap_result(manager, 5000, fn(reply_to) {
    messages.StartAgent(args, reply_to)
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

      case status.phase {
        types_agent.Failed ->
          case status.failure_reason {
            Some(reason) ->
              panic as types_agent.failure_reason_to_string(reason)
            None -> panic as "Agent entered Failed"
          }

        _ ->
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

  // Keep stop tests fast.
  let timeouts = types_config.SadTimeouts(..timeouts0, shutdown_timeout_ms: 250)

  types_config.SadConfig(..cfg0, runner: runner, timeouts: timeouts)
}

fn config_with_workspace_dir(dir: String) -> types_config.SadConfig {
  let cfg0 = types_config.default_sad_config()
  let types_config.SadConfig(storage: storage0, ..) = cfg0

  let storage =
    types_config.StorageConfig(..storage0, workspaces_directory: dir)
  types_config.SadConfig(..cfg0, storage: storage)
}

fn workspace_for(
  cfg: types_config.SadConfig,
  instance_id: types_core.InstanceId,
) -> String {
  let types_config.SadConfig(storage: storage, ..) = cfg
  let types_config.StorageConfig(workspaces_directory: base, ..) = storage
  workspace.workspace_for_instance(base, instance_id)
}

fn echo_server_profile_managed_port() -> types_profile.Profile {
  let assert Ok(raw) =
    simplifile.read("./test/fixtures/source_local/profiles/echo_server.json")

  let assert Ok(profile0) = json.parse(raw, decoders.profile_decoder())

  let types_profile.Profile(runner: runner0, ..) = profile0

  let runtime =
    types_runner.RuntimeConfig(
      mode: types_runner.ManagedPort,
      port_env_var: None,
      host_env_var: None,
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
