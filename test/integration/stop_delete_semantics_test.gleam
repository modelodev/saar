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
import saar/app_state
import saar/core/agent
import saar/core/artifact_registry_protocol
import saar/core/messages
import saar/core/root_supervisor
import saar/core/supervisor_names
import saar/decoders
import saar/net/tcp_listener
import saar/otp/safe_call
import saar/streams/sink
import saar/types/agent as types_agent
import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/enums as types_enums
import saar/types/input as types_input
import saar/types/output as types_output
import saar/types/profile as types_profile
import saar/types/runner as types_runner
import saar/workspace
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

  safe_call.call_unwrap_result(manager, 5000, fn(reply_to) {
    messages.Cmd(messages.StopAgent(id1, reply_to))
  })
  |> test_assertions.assert_ok

  let a2 = start_instance(manager, artifact_registry, profile, id2, cfg)
  wait_for_phase(a2, types_agent.ReadyContinuous, 400)

  let _ = names
  Nil
}

pub fn stop_does_not_purge_artifacts_test() {
  let cfg = config_with_workspace_dir("./build/test-workspaces/stop")
  let #(_names, manager, _registry, artifact_registry) = start_root(cfg)

  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-stop-artifacts-1")

  let _agent_ref =
    start_instance(manager, artifact_registry, profile, instance_id, cfg)

  let workspace_dir = workspace_for(cfg, instance_id)
  let file_path = filepath.join(workspace_dir, "artifact.txt")

  let assert Ok(_) = simplifile.create_directory_all(workspace_dir)
  let assert Ok(_) = simplifile.write(to: file_path, contents: "hello")

  let assert Ok(path) = workspace.workspace_path_validate("artifact.txt")

  let artifact_id =
    safe_call.call(artifact_registry, 1000, fn(reply_to) {
      artifact_registry_protocol.RegisterArtifact(
        path,
        "text/plain",
        instance_id,
        reply_to,
      )
    })
    |> test_assertions.assert_ok

  safe_call.call_unwrap_result(manager, 5000, fn(reply_to) {
    messages.Cmd(messages.StopAgent(instance_id, reply_to))
  })
  |> test_assertions.assert_ok

  // Artifacts remain accessible in the registry.
  let assert Ok(Some(_entry)) =
    safe_call.call(artifact_registry, 1000, fn(reply_to) {
      artifact_registry_protocol.LookupArtifact(artifact_id, reply_to)
    })

  // Workspace is not deleted by stop.
  simplifile.read(file_path) |> should.be_ok
}

pub fn stop_clears_assigned_port_test() {
  port_helpers.ensure_wrapper_path()

  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)
  let cfg = config_with_port_range(port)

  let #(_names, manager, _registry, artifact_registry) = start_root(cfg)
  tcp_listener.close(listener)

  let profile = echo_server_profile_managed_port()

  let assert Ok(instance_id) = types_core.instance_id("inst-stop-port-1")

  let agent_ref =
    start_instance(manager, artifact_registry, profile, instance_id, cfg)
  wait_for_phase(agent_ref, types_agent.ReadyContinuous, 400)

  let status0 = agent.status(agent_ref, 1000) |> test_assertions.assert_ok
  status0.assigned_port |> should.not_equal(None)

  safe_call.call_unwrap_result(manager, 5000, fn(reply_to) {
    messages.Cmd(messages.StopAgent(instance_id, reply_to))
  })
  |> test_assertions.assert_ok

  let status1 = agent.status(agent_ref, 1000) |> test_assertions.assert_ok
  status1.phase |> should.equal(types_agent.Stopped)
  status1.assigned_port |> should.equal(None)
}

pub fn start_after_stop_restores_assigned_port_test() {
  port_helpers.ensure_wrapper_path()

  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)
  let cfg = config_with_port_range(port)

  let #(_names, manager, _registry, artifact_registry) = start_root(cfg)
  tcp_listener.close(listener)

  let profile = echo_server_profile_managed_port()

  let assert Ok(instance_id) = types_core.instance_id("inst-stop-start-port-1")

  let agent_ref =
    start_instance(manager, artifact_registry, profile, instance_id, cfg)
  wait_for_phase(agent_ref, types_agent.ReadyContinuous, 400)

  safe_call.call_unwrap_result(manager, 5000, fn(reply_to) {
    messages.Cmd(messages.StopAgent(instance_id, reply_to))
  })
  |> test_assertions.assert_ok

  wait_for_phase(agent_ref, types_agent.Stopped, 200)

  safe_call.call_unwrap_result(manager, 5000, fn(reply_to) {
    messages.Cmd(messages.StartExistingAgent(instance_id, reply_to))
  })
  |> test_assertions.assert_ok

  wait_for_phase(agent_ref, types_agent.ReadyContinuous, 400)

  let status = agent.status(agent_ref, 1000) |> test_assertions.assert_ok
  status.assigned_port |> should.not_equal(None)
}

pub fn delete_nonexistent_is_ok_test() {
  let cfg =
    config_with_workspace_dir("./build/test-workspaces/delete-nonexistent")
  let #(_names, manager, _registry, _artifact_registry) = start_root(cfg)

  let assert Ok(instance_id) = types_core.instance_id("inst-missing")

  safe_call.call_unwrap_result(manager, 5000, fn(reply_to) {
    messages.Cmd(messages.DeleteAgent(instance_id, reply_to))
  })
  |> should.equal(Ok(Nil))
}

pub fn stop_while_interaction_inflight_client_sees_cancelled_test() {
  port_helpers.ensure_wrapper_path()

  let cfg = config_with_workspace_dir("./build/test-workspaces/stop-inflight")
  let #(_names, manager, _registry, artifact_registry) = start_root(cfg)

  let profile = echo_cli_profile_with_delay_and_timeout(250, 2000)

  let assert Ok(instance_id) = types_core.instance_id("inst-stop-inflight-1")

  let agent_ref =
    start_instance(manager, artifact_registry, profile, instance_id, cfg)
  wait_for_phase(agent_ref, types_agent.ReadyTransient, 400)

  let trace_id = types_core.trace_id("trace-stop-inflight")
  let out = process.new_subject()

  let _ =
    process.spawn(fn() {
      process.send(
        out,
        interact_echo(agent_ref, profile.meta.id, instance_id, trace_id),
      )
    })

  process.sleep(20)

  safe_call.call_unwrap_result(manager, 5000, fn(reply_to) {
    messages.Cmd(messages.StopAgent(instance_id, reply_to))
  })
  |> test_assertions.assert_ok

  let assert Ok(result) = process.receive(out, 2000)

  case result {
    Ok(_) -> panic as "Expected cancelled"

    Error(types_output.InteractionError(kind: kind, message: message, ..)) -> {
      kind |> should.equal(types_enums.AgentError)
      message |> should.equal("cancelled")
    }
  }
}

pub fn stop_while_interaction_inflight_cleans_worker_test() {
  port_helpers.ensure_wrapper_path()

  let cfg =
    config_with_workspace_dir("./build/test-workspaces/stop-inflight-clean")
  let #(_names, manager, _registry, artifact_registry) = start_root(cfg)

  let profile = echo_cli_profile_with_delay_and_timeout(250, 2000)

  let assert Ok(instance_id) = types_core.instance_id("inst-stop-inflight-2")

  let agent_ref =
    start_instance(manager, artifact_registry, profile, instance_id, cfg)
  wait_for_phase(agent_ref, types_agent.ReadyTransient, 400)

  let out = process.new_subject()

  let _ =
    process.spawn(fn() {
      let trace_id = types_core.trace_id("trace-stop-clean-1")
      process.send(
        out,
        interact_echo(agent_ref, profile.meta.id, instance_id, trace_id),
      )
    })

  process.sleep(20)

  safe_call.call_unwrap_result(manager, 5000, fn(reply_to) {
    messages.Cmd(messages.StopAgent(instance_id, reply_to))
  })
  |> test_assertions.assert_ok

  let _ = process.receive(out, 2000)

  // Avoid racing StartExisting against a still-stopping agent.
  wait_for_phase(agent_ref, types_agent.Stopped, 200)

  safe_call.call_unwrap_result(manager, 5000, fn(reply_to) {
    messages.Cmd(messages.StartExistingAgent(instance_id, reply_to))
  })
  |> test_assertions.assert_ok

  wait_for_phase(agent_ref, types_agent.ReadyTransient, 400)

  let trace_id = types_core.trace_id("trace-stop-clean-2")
  interact_echo(agent_ref, profile.meta.id, instance_id, trace_id)
  |> should.be_ok
}

pub fn delete_while_interaction_inflight_client_sees_cancelled_test() {
  port_helpers.ensure_wrapper_path()

  let cfg = config_with_workspace_dir("./build/test-workspaces/delete-inflight")
  let #(_names, manager, _registry, artifact_registry) = start_root(cfg)

  let profile = echo_cli_profile_with_delay_and_timeout(250, 2000)

  let assert Ok(instance_id) = types_core.instance_id("inst-del-inflight-1")

  let agent_ref =
    start_instance(manager, artifact_registry, profile, instance_id, cfg)
  wait_for_phase(agent_ref, types_agent.ReadyTransient, 400)

  let out = process.new_subject()

  let _ =
    process.spawn(fn() {
      let trace_id = types_core.trace_id("trace-del-inflight")
      process.send(
        out,
        interact_echo(agent_ref, profile.meta.id, instance_id, trace_id),
      )
    })

  process.sleep(20)

  let _ =
    safe_call.call_unwrap_result(manager, 5000, fn(reply_to) {
      messages.Cmd(messages.DeleteAgent(instance_id, reply_to))
    })

  let assert Ok(result) = process.receive(out, 2000)

  case result {
    Ok(_) -> panic as "Expected cancelled"

    Error(types_output.InteractionError(kind: kind, message: message, ..)) -> {
      kind |> should.equal(types_enums.AgentError)
      message |> should.equal("cancelled")
    }
  }
}

pub fn delete_while_interaction_inflight_cleans_everything_test() {
  port_helpers.ensure_wrapper_path()

  let cfg =
    config_with_workspace_dir("./build/test-workspaces/delete-inflight-clean")
  let #(_names, manager, registry, artifact_registry) = start_root(cfg)

  let profile = echo_cli_profile_with_delay_and_timeout(250, 2000)

  let assert Ok(instance_id) = types_core.instance_id("inst-del-inflight-2")

  let agent_ref =
    start_instance(manager, artifact_registry, profile, instance_id, cfg)
  wait_for_phase(agent_ref, types_agent.ReadyTransient, 400)

  let workspace_dir = workspace_for(cfg, instance_id)
  let file_path = filepath.join(workspace_dir, "artifact.txt")

  let assert Ok(_) = simplifile.create_directory_all(workspace_dir)
  let assert Ok(_) = simplifile.write(to: file_path, contents: "hello")

  let assert Ok(path) = workspace.workspace_path_validate("artifact.txt")

  let artifact_id =
    safe_call.call(artifact_registry, 1000, fn(reply_to) {
      artifact_registry_protocol.RegisterArtifact(
        path,
        "text/plain",
        instance_id,
        reply_to,
      )
    })
    |> test_assertions.assert_ok

  let out = process.new_subject()

  let _ =
    process.spawn(fn() {
      let trace_id = types_core.trace_id("trace-del-clean")
      process.send(
        out,
        interact_echo(agent_ref, profile.meta.id, instance_id, trace_id),
      )
    })

  process.sleep(20)

  let _ =
    safe_call.call_unwrap_result(manager, 5000, fn(reply_to) {
      messages.Cmd(messages.DeleteAgent(instance_id, reply_to))
    })

  let _ = process.receive(out, 2000)

  safe_call.call(artifact_registry, 1000, fn(reply_to) {
    artifact_registry_protocol.LookupArtifact(artifact_id, reply_to)
  })
  |> should.equal(Ok(None))

  // Registry entry is removed.
  safe_call.call(registry, 1000, fn(reply_to) {
    messages.LookupByInstanceId(instance_id, reply_to)
  })
  |> should.equal(Ok(None))

  // Workspace dir is removed.
  case simplifile.read(file_path) {
    Ok(_) -> panic as "Expected workspace to be removed"
    Error(simplifile.Enoent) -> Nil
    Error(_) -> Nil
  }
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
    safe_call.call(artifact_registry, 1000, fn(reply_to) {
      artifact_registry_protocol.RegisterArtifact(
        path,
        "text/plain",
        instance_id,
        reply_to,
      )
    })
    |> test_assertions.assert_ok

  safe_call.call_unwrap_result(manager, 5000, fn(reply_to) {
    messages.Cmd(messages.DeleteAgent(instance_id, reply_to))
  })
  |> test_assertions.assert_ok

  safe_call.call(artifact_registry, 1000, fn(reply_to) {
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
    safe_call.call(artifact_registry, 1000, fn(reply_to) {
      artifact_registry_protocol.RegisterArtifact(
        path,
        "text/plain",
        instance_id,
        reply_to,
      )
    })
    |> test_assertions.assert_ok

  case
    safe_call.call_unwrap_result(manager, 5000, fn(reply_to) {
      messages.Cmd(messages.DeleteAgent(instance_id, reply_to))
    })
  {
    Error(safe_call.ActorError(messages.CleanupFailed(_))) -> Nil
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
    safe_call.call(artifact_registry, 1000, fn(reply_to) {
      artifact_registry_protocol.RegisterArtifact(
        path,
        "text/plain",
        instance_id,
        reply_to,
      )
    })
    |> test_assertions.assert_ok

  let _ =
    safe_call.call_unwrap_result(manager, 5000, fn(reply_to) {
      messages.Cmd(messages.DeleteAgent(instance_id, reply_to))
    })

  safe_call.call(artifact_registry, 1000, fn(reply_to) {
    artifact_registry_protocol.LookupArtifact(artifact_id, reply_to)
  })
  |> should.equal(Ok(None))
}

fn start_root(
  cfg: types_config.SaarConfig,
) -> #(
  supervisor_names.RootNames,
  process.Subject(messages.AgentManagerMsg),
  process.Subject(messages.RegistryMsg),
  process.Subject(artifact_registry_protocol.ArtifactRegistryMsg),
) {
  let cfg = types_config.SaarConfig(..cfg, server_port: 0)

  let names = supervisor_names.new_names()
  let state = app_state.AppState(config: cfg, initial_profiles: dict.new())

  let assert Ok(actor.Started(..)) = root_supervisor.start(state, names)

  let supervisor_names.RootNames(
    registry_name,
    artifact_registry_name,
    _,
    _,
    _,
    agent_manager_name,
    _,
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
  cfg: types_config.SaarConfig,
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
    0 -> panic as "Timed out waiting for phase"
    _ -> {
      let status = agent.status(agent_ref, 1000) |> test_assertions.assert_ok

      case status.phase {
        types_agent.Failed(reason) ->
          panic as types_agent.failure_reason_to_string(reason)

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

fn config_with_port_range(port: Int) -> types_config.SaarConfig {
  let cfg0 = types_config.default_saar_config()

  let types_config.SaarConfig(runner: runner0, timeouts: timeouts0, ..) = cfg0

  let runner =
    types_config.RunnerSystemConfig(
      ..runner0,
      port_range_min: port,
      port_range_max: port,
      managed_port_host: host,
    )

  // Keep stop tests fast.
  let timeouts =
    types_config.SaarTimeouts(..timeouts0, shutdown_timeout_ms: 250)

  types_config.SaarConfig(..cfg0, runner: runner, timeouts: timeouts)
}

fn config_with_workspace_dir(dir: String) -> types_config.SaarConfig {
  let cfg0 = types_config.default_saar_config()
  let types_config.SaarConfig(storage: storage0, ..) = cfg0

  let storage =
    types_config.StorageConfig(..storage0, workspaces_directory: dir)
  types_config.SaarConfig(..cfg0, storage: storage)
}

fn workspace_for(
  cfg: types_config.SaarConfig,
  instance_id: types_core.InstanceId,
) -> String {
  let types_config.SaarConfig(storage: storage, ..) = cfg
  let types_config.StorageConfig(workspaces_directory: base, ..) = storage
  workspace.workspace_for_instance(base, instance_id)
}

fn echo_server_profile_managed_port() -> types_profile.Profile {
  let assert Ok(raw) =
    simplifile.read("./test/fixtures/source_local/profiles/echo_server.json")

  let assert Ok(profile0) = json.parse(raw, decoders.profile_decoder())

  let types_profile.Profile(runner: runner0, ..) = profile0

  let runtime = types_runner.ManagedPort(host_env_var: None, port_env_var: None)

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

fn echo_cli_profile_with_delay_and_timeout(
  delay_ms: Int,
  call_timeout_ms: Int,
) -> types_profile.Profile {
  let assert Ok(raw) =
    simplifile.read("./test/fixtures/source_local/profiles/echo_cli.json")

  let assert Ok(profile0) = json.parse(raw, decoders.profile_decoder())

  let types_profile.Profile(
    parameters: params0,
    runner: runner0,
    interface: interface0,
    ..,
  ) = profile0

  let params =
    dict.insert(
      params0,
      "delay_ms",
      types_profile.FixedParam(types_core.IntVal(delay_ms)),
    )

  let runner =
    types_runner.Runner(
      ..runner0,
      tool_config: types_runner.ToolConfigScript(
        "../../test/fixtures/source_local/runners/echo_cli.py",
      ),
    )

  let interface = case interface0 {
    types_profile.RunnerInterface(capabilities: caps0) -> {
      let assert Ok(cap0) = dict.get(caps0, "echo")

      let types_profile.RunnerCapability(
        input_schema: schema,
        description: description,
        streaming: streaming,
        response_mode: response_mode,
        files: files,
        ..,
      ) = cap0

      let cap =
        types_profile.RunnerCapability(
          input_schema: schema,
          description: description,
          streaming: streaming,
          response_mode: response_mode,
          limits: Some(
            types_profile.CapabilityLimits(call_timeout_ms: Some(
              call_timeout_ms,
            )),
          ),
          files: files,
        )

      types_profile.RunnerInterface(capabilities: dict.insert(
        caps0,
        "echo",
        cap,
      ))
    }

    other -> other
  }

  types_profile.Profile(
    ..profile0,
    parameters: params,
    runner: runner,
    interface: interface,
  )
}

fn interact_echo(
  agent_ref: agent.AgentRef,
  profile_id: types_core.ProfileId,
  instance_id: types_core.InstanceId,
  trace_id: types_core.TraceId,
) -> Result(types_output.InteractionResult, types_output.InteractionError) {
  let ctx = types_input.RequestContext(trace_id: trace_id, extra: dict.new())

  let inputs =
    types_input.PayloadChat(
      [types_input.ChatMessage(role: "user", content: "hi")],
      dict.new(),
    )

  let req =
    agent.AgentRequest(
      profile_id: profile_id,
      instance_id: instance_id,
      capability: "echo",
      inputs: inputs,
      context: ctx,
    )

  agent.interact(agent_ref, req, sink.NonStreaming, 5000)
}
