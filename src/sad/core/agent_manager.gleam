////
//// Mission: coordinate instance lifecycle operations across core actors.
////
//// Responsibilities:
//// - Start new agents under `sad/core/agent_factory_supervisor`.
//// - Register/unregister instances in `sad/core/registry`.
//// - Drive asynchronous provisioning and report the outcome into the AgentActor.
//// - Implement stop/delete semantics and ensure managed ports are released.
////
//// Non-responsibilities:
//// - Acting as an instance SSOT (that is `sad/core/registry`).
//// - Resolving parameters (StartArgs contain resolved params and profile snapshots).
//// - Exposing HTTP endpoints (gateway responsibility).
////
//// Relationships:
//// - Started under `sad/core/root_supervisor`.
//// - Uses `sad/core/registry_api`, `sad/core/port_pool_api`, and `sad/core/artifact_registry_api`.
//// - Spawns AgentActor children via a named `factory_supervisor`.

import envoy
import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/result
import gleam/string
import sad/bridge/client
import sad/bridge/port_owner

import sad/core/agent
import sad/core/agent_internal
import sad/core/artifact_registry_api
import sad/core/messages
import sad/core/port_pool_api
import sad/core/profiles_api
import sad/core/registry_api
import sad/net/port_check
import sad/params
import sad/port_pool
import sad/types/agent as types_agent
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/input as types_input
import sad/types/profile as types_profile
import sad/types/runner as types_runner
import sad/workspace
import simplifile

pub fn start(
  name: process.Name(messages.AgentManagerMsg),
  config: types_config.SadConfig,
  registry: process.Subject(messages.RegistryMsg),
  artifact_registry: process.Subject(messages.ArtifactRegistryMsg),
  port_pool: process.Subject(messages.PortPoolMsg),
  profiles: process.Subject(messages.ProfilesMsg),
  agent_factory: factory_supervisor.Supervisor(
    messages.StartArgs,
    agent.AgentRef,
  ),
) -> actor.StartResult(process.Subject(messages.AgentManagerMsg)) {
  actor.new(State(
    config: config,
    registry: registry,
    artifact_registry: artifact_registry,
    port_pool: port_pool,
    profiles: profiles,
    agent_factory: agent_factory,
  ))
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

type State {
  State(
    config: types_config.SadConfig,
    registry: process.Subject(messages.RegistryMsg),
    artifact_registry: process.Subject(messages.ArtifactRegistryMsg),
    port_pool: process.Subject(messages.PortPoolMsg),
    profiles: process.Subject(messages.ProfilesMsg),
    agent_factory: factory_supervisor.Supervisor(
      messages.StartArgs,
      agent.AgentRef,
    ),
  )
}

fn handle_message(
  state: State,
  msg: messages.AgentManagerMsg,
) -> actor.Next(State, messages.AgentManagerMsg) {
  case msg {
    messages.CreateAgent(profile_id, instance_id, init_params, reply_to) ->
      handle_create_agent(state, profile_id, instance_id, init_params, reply_to)

    messages.StartAgent(args, reply_to) ->
      handle_start_agent(state, args, reply_to)

    messages.StopAgent(instance_id, reply_to) ->
      handle_stop_agent(state, instance_id, reply_to)

    messages.DeleteAgent(instance_id, reply_to) ->
      handle_delete_agent(state, instance_id, reply_to)

    messages.DeleteWorkerDone(_instance_id, _result) -> actor.continue(state)

    messages.DeleteWorkerDown(_down) -> actor.continue(state)

    messages.ListAgents(reply_to) -> handle_list_agents(state, reply_to)
  }
}

fn handle_create_agent(
  state: State,
  profile_id: types_core.ProfileId,
  instance_id: types_core.InstanceId,
  init_params: dict.Dict(String, types_core.Value),
  reply_to: process.Subject(Result(agent.AgentRef, messages.StartError)),
) -> actor.Next(State, messages.AgentManagerMsg) {
  let State(config: config, profiles: profiles, ..) = state

  let profile_out =
    profiles_api.get_profile(profiles, profile_id, call_timeout_ms(config))

  case profile_out {
    Error(err) -> {
      process.send(
        reply_to,
        Error(messages.StartChildFailed(
          "profiles_call_failed:" <> string.inspect(err),
        )),
      )
      actor.continue(state)
    }

    Ok(None) -> {
      process.send(reply_to, Error(messages.ProfileNotFound(profile_id)))
      actor.continue(state)
    }

    Ok(Some(profile)) ->
      case resolve_params_for_profile(profile, config, init_params) {
        Error(err) -> {
          process.send(reply_to, Error(err))
          actor.continue(state)
        }

        Ok(resolved) -> {
          let types_config.SadConfig(storage: storage, ..) = config
          let types_config.StorageConfig(workspaces_directory: base_dir, ..) =
            storage

          let args =
            messages.StartArgs(
              profile: profile,
              instance_id: instance_id,
              params: resolved,
              workspace: workspace.workspace_for_instance(base_dir, instance_id),
              config: config,
            )

          handle_start_agent(state, args, reply_to)
        }
      }
  }
}

fn resolve_params_for_profile(
  profile: types_profile.Profile,
  config: types_config.SadConfig,
  init_params: dict.Dict(String, types_core.Value),
) -> Result(types_input.ResolvedParams, messages.StartError) {
  let types_profile.Profile(parameters: parameters, ..) = profile

  // TODO(S13): map SadConfig into ConfigParam values.
  let _ = config
  let config_values = dict.new()

  case
    params.resolve_params(parameters, config_values, envoy.get, init_params)
  {
    Ok(resolved) -> Ok(resolved)

    Error(errors) ->
      Error(messages.ParamResolutionFailed(
        "param_resolution_failed:" <> string.inspect(errors),
      ))
  }
}

fn handle_start_agent(
  state: State,
  args: messages.StartArgs,
  reply_to: process.Subject(Result(agent.AgentRef, messages.StartError)),
) -> actor.Next(State, messages.AgentManagerMsg) {
  let State(
    config: config,
    registry: registry,
    port_pool: port_pool,
    agent_factory: factory,
    ..,
  ) = state

  let messages.StartArgs(profile: profile, instance_id: instance_id, ..) = args

  case factory_supervisor.start_child(factory, args) {
    Error(err) -> {
      process.send(reply_to, Error(start_error_from_actor_start_error(err)))
      actor.continue(state)
    }

    Ok(actor.Started(data: agent_ref, ..)) -> {
      let status = initial_status(profile, instance_id)

      case
        registry_api.register(
          registry,
          status,
          agent_ref,
          registry_timeout_ms(config),
        )
      {
        Ok(_) -> {
          // Transition to Provisioning quickly, then provision asynchronously.
          agent.start_instance(agent_ref)
          registry_api.update_status(
            registry,
            instance_id,
            types_agent.AgentStatusView(
              ..status,
              phase: types_agent.Provisioning,
            ),
          )

          start_provisioning_worker(
            config,
            port_pool,
            registry,
            args,
            agent_ref,
          )

          process.send(reply_to, Ok(agent_ref))
          actor.continue(state)
        }

        Error(registry_api.ActorError(registry_err)) -> {
          agent.terminate(agent_ref, agent.SupervisorCleanup)
          process.send(
            reply_to,
            Error(messages.RegistrationFailed(registry_err)),
          )
          actor.continue(state)
        }

        Error(registry_api.CallFailed(call_err)) -> {
          agent.terminate(agent_ref, agent.SupervisorCleanup)
          process.send(
            reply_to,
            Error(messages.StartChildFailed(
              "registry_call_failed:" <> string.inspect(call_err),
            )),
          )
          actor.continue(state)
        }
      }
    }
  }
}

fn initial_status(
  profile: types_profile.Profile,
  instance_id: types_core.InstanceId,
) -> types_agent.AgentStatusView {
  types_agent.AgentStatusView(
    profile_id: profile.meta.id,
    instance_id: instance_id,
    lifecycle: profile.meta.lifecycle,
    phase: types_agent.Created,
    mode: types_agent.RunIdle,
    assigned_port: None,
    failure_reason: None,
  )
}

fn handle_stop_agent(
  state: State,
  instance_id: types_core.InstanceId,
  reply_to: process.Subject(Result(Nil, messages.StopError)),
) -> actor.Next(State, messages.AgentManagerMsg) {
  let State(config: config, registry: registry, port_pool: port_pool, ..) =
    state

  case
    registry_api.lookup_by_instance_id(
      registry,
      instance_id,
      registry_timeout_ms(config),
    )
  {
    Ok(None) | Error(_) -> {
      process.send(reply_to, Ok(Nil))
      actor.continue(state)
    }

    Ok(Some(agent_ref)) -> {
      let maybe_status =
        agent.status(agent_ref, agent.status_timeout_ms(config))

      agent.stop_instance(agent_ref, agent.UserRequested)

      // For managed ports, block briefly until the OS port is free before releasing.
      // This prevents flakiness when starting the next instance immediately.
      case maybe_status {
        Ok(status) ->
          case status.assigned_port {
            Some(port) ->
              wait_for_port_free(config, managed_port_host(config), port)
            None -> Nil
          }

        Error(_) -> Nil
      }

      let _ =
        port_pool_api.release(port_pool, instance_id, call_timeout_ms(config))
      update_registry_status_best_effort(config, registry, agent_ref)

      process.send(reply_to, Ok(Nil))
      actor.continue(state)
    }
  }
}

fn handle_delete_agent(
  state: State,
  instance_id: types_core.InstanceId,
  reply_to: process.Subject(Result(Nil, messages.DeleteError)),
) -> actor.Next(State, messages.AgentManagerMsg) {
  let State(
    config: config,
    registry: registry,
    artifact_registry: artifact_registry,
    port_pool: port_pool,
    ..,
  ) = state

  case
    registry_api.lookup_by_instance_id(
      registry,
      instance_id,
      registry_timeout_ms(config),
    )
  {
    Ok(None) | Error(_) -> {
      process.send(reply_to, Ok(Nil))
      actor.continue(state)
    }

    Ok(Some(agent_ref)) -> {
      agent.stop_instance(agent_ref, agent.Deleted)
      agent.terminate(agent_ref, agent.Deleted)

      let _ =
        artifact_registry_api.purge_by_instance(
          artifact_registry,
          instance_id,
          call_timeout_ms(config),
        )

      registry_api.unregister_by_instance_id(registry, instance_id)
      let _ =
        port_pool_api.release(port_pool, instance_id, call_timeout_ms(config))

      case cleanup_workspace(config, instance_id) {
        Ok(_) -> process.send(reply_to, Ok(Nil))
        Error(reason) ->
          process.send(reply_to, Error(messages.CleanupFailed(reason)))
      }

      actor.continue(state)
    }
  }
}

fn handle_list_agents(
  state: State,
  reply_to: process.Subject(List(types_agent.InstanceSummary)),
) -> actor.Next(State, messages.AgentManagerMsg) {
  let State(config: config, registry: registry, ..) = state

  case registry_api.list_all(registry, registry_timeout_ms(config)) {
    Ok(items) -> process.send(reply_to, items)
    Error(_) -> process.send(reply_to, [])
  }

  actor.continue(state)
}

fn registry_timeout_ms(cfg: types_config.SadConfig) -> Int {
  let types_config.SadConfig(timeouts: timeouts, ..) = cfg
  let types_config.SadTimeouts(registry_timeout_ms: registry_timeout_ms, ..) =
    timeouts
  registry_timeout_ms
}

fn call_timeout_ms(cfg: types_config.SadConfig) -> Int {
  let types_config.SadConfig(timeouts: timeouts, ..) = cfg
  let types_config.SadTimeouts(call_timeout_ms: call_timeout_ms, ..) = timeouts
  call_timeout_ms
}

fn start_error_from_actor_start_error(
  err: actor.StartError,
) -> messages.StartError {
  case err {
    actor.InitFailed(reason) -> messages.InitFailed(reason)
    actor.InitTimeout -> messages.StartChildFailed("init_timeout")
    actor.InitExited(exit) ->
      messages.StartChildFailed("init_exited:" <> string.inspect(exit))
  }
}

fn start_provisioning_worker(
  config: types_config.SadConfig,
  port_pool: process.Subject(messages.PortPoolMsg),
  registry: process.Subject(messages.RegistryMsg),
  args: messages.StartArgs,
  agent_ref: agent.AgentRef,
) -> process.Pid {
  process.spawn(fn() {
    let outcome = provision(config, port_pool, args)
    agent_internal.provisioning_done(agent_ref, outcome)
    update_registry_status_best_effort(config, registry, agent_ref)
  })
}

fn provision(
  config: types_config.SadConfig,
  port_pool: process.Subject(messages.PortPoolMsg),
  args: messages.StartArgs,
) -> Result(#(agent.AgentState, Option(Int)), String) {
  let messages.StartArgs(
    profile: profile,
    instance_id: instance_id,
    params: params,
    ..,
  ) = args

  case profile.meta.lifecycle {
    types_enums.Transient -> Ok(#(agent.agent_ready_transient(params), None))

    types_enums.Continuous ->
      provision_continuous(config, port_pool, profile, instance_id, params)
  }
}

fn provision_continuous(
  config: types_config.SadConfig,
  port_pool: process.Subject(messages.PortPoolMsg),
  profile: types_profile.Profile,
  instance_id: types_core.InstanceId,
  params: types_input.ResolvedParams,
) -> Result(#(agent.AgentState, Option(Int)), String) {
  let types_runner.RuntimeConfig(mode: mode, ..) = profile.runner.runtime

  case mode {
    types_runner.NoNetwork -> Error("PORT_BIND_FAILED")

    types_runner.ManagedPort ->
      provision_continuous_managed_port(
        config,
        port_pool,
        profile,
        instance_id,
        params,
      )
  }
}

fn wait_for_health_ready(
  interface: types_profile.Interface,
  host: String,
  port: Int,
  config: types_config.SadConfig,
) -> Result(Nil, Nil) {
  case http_health_check(interface) {
    None -> Ok(Nil)

    Some(#(headers, types_profile.HealthCheck(path, method, expect))) -> {
      let #(attempts, request_timeout_ms, max_bytes) =
        health_wait_settings(config)
      wait_for_http_status(
        headers,
        host,
        port,
        path,
        method,
        expect,
        attempts,
        request_timeout_ms,
        max_bytes,
      )
    }
  }
}

fn http_health_check(
  interface: types_profile.Interface,
) -> Option(#(dict.Dict(String, String), types_profile.HealthCheck)) {
  case interface {
    types_profile.HttpInterface(_, headers, Some(health), _) ->
      Some(#(headers, health))

    _ -> None
  }
}

fn health_wait_settings(cfg: types_config.SadConfig) -> #(Int, Int, Int) {
  let types_config.SadConfig(timeouts: timeouts, limits: limits, ..) = cfg
  let types_config.SadLimits(max_http_response_bytes: max_bytes, ..) = limits

  // Keep provisioning snappy in tests and v0.
  let _ = timeouts
  #(40, 200, max_bytes)
}

fn wait_for_http_status(
  headers: dict.Dict(String, String),
  host: String,
  port: Int,
  path: String,
  method: types_profile.HttpMethod,
  expect: List(Int),
  attempts: Int,
  request_timeout_ms: Int,
  max_bytes: Int,
) -> Result(Nil, Nil) {
  case attempts {
    0 -> Error(Nil)

    _ -> {
      let url = "http://" <> host <> ":" <> int.to_string(port) <> path

      let out =
        client.request_sync(
          http_method(method),
          url,
          headers,
          None,
          request_timeout_ms,
          max_bytes,
        )

      case out {
        Ok(resp) ->
          case list.contains(expect, resp.status) {
            True -> Ok(Nil)
            False -> {
              process.sleep(25)
              wait_for_http_status(
                headers,
                host,
                port,
                path,
                method,
                expect,
                attempts - 1,
                request_timeout_ms,
                max_bytes,
              )
            }
          }

        Error(_) -> {
          process.sleep(25)
          wait_for_http_status(
            headers,
            host,
            port,
            path,
            method,
            expect,
            attempts - 1,
            request_timeout_ms,
            max_bytes,
          )
        }
      }
    }
  }
}

fn http_method(method: types_profile.HttpMethod) -> http.Method {
  case method {
    types_profile.HttpGet -> http.Get
    types_profile.HttpPost -> http.Post
    types_profile.HttpPut -> http.Put
    types_profile.HttpDelete -> http.Delete
  }
}

fn provision_continuous_managed_port(
  config: types_config.SadConfig,
  port_pool_subject: process.Subject(messages.PortPoolMsg),
  profile: types_profile.Profile,
  instance_id: types_core.InstanceId,
  params: types_input.ResolvedParams,
) -> Result(#(agent.AgentState, Option(Int)), String) {
  let host = managed_port_host(config)

  use port <- result.try(allocate_port(
    config,
    port_pool_subject,
    instance_id,
    host,
  ))

  case port_check.check_available(host, port) {
    Ok(_) -> Ok(Nil)

    Error(port_pool.CheckPortInUse) -> {
      release_port_best_effort(config, port_pool_subject, instance_id)
      Error("PORT_IN_USE")
    }

    Error(_) -> {
      release_port_best_effort(config, port_pool_subject, instance_id)
      Error("PORT_BIND_FAILED")
    }
  }
  |> result.try(fn(_) {
    process.sleep(20)

    case start_port_owner(config, profile, instance_id, params, port) {
      Ok(owner) ->
        case wait_for_health_ready(profile.interface, host, port, config) {
          Ok(_) -> {
            let resource = agent.port_owner_resource(owner)
            Ok(#(agent.agent_ready_continuous(params, resource), Some(port)))
          }

          Error(_) -> {
            let _ = port_owner.stop(owner, 1000)
            release_port_best_effort(config, port_pool_subject, instance_id)
            Error("PORT_BIND_FAILED")
          }
        }

      Error(_) -> {
        let reason = case port_check.check_available(host, port) {
          Error(port_pool.CheckPortInUse) -> "PORT_IN_USE"
          _ -> "PORT_BIND_FAILED"
        }

        release_port_best_effort(config, port_pool_subject, instance_id)
        Error(reason)
      }
    }
  })
}

fn allocate_port(
  config: types_config.SadConfig,
  port_pool_subject: process.Subject(messages.PortPoolMsg),
  instance_id: types_core.InstanceId,
  host: String,
) -> Result(Int, String) {
  case
    port_pool_api.allocate_checked(
      port_pool_subject,
      host,
      instance_id,
      call_timeout_ms(config),
    )
  {
    Error(_) -> Error("PORT_BIND_FAILED")

    Ok(Ok(port)) -> Ok(port)

    Ok(Error(err)) -> Error(port_pool_error_to_failure_reason(err))
  }
}

fn port_pool_error_to_failure_reason(err: port_pool.PortPoolError) -> String {
  case err {
    port_pool.PoolExhausted -> "PORT_POOL_EXHAUSTED"
    port_pool.PortInUse -> "PORT_IN_USE"
    port_pool.BindCheckFailed(_) -> "PORT_BIND_FAILED"
    port_pool.NoAvailablePortAfterRetries(_) -> "PORT_POOL_EXHAUSTED"
    _ -> "PORT_BIND_FAILED"
  }
}

fn managed_port_host(config: types_config.SadConfig) -> String {
  let types_config.SadConfig(runner: runner_cfg, ..) = config
  let types_config.RunnerSystemConfig(managed_port_host: host, ..) = runner_cfg
  host
}

fn start_port_owner(
  config: types_config.SadConfig,
  profile: types_profile.Profile,
  instance_id: types_core.InstanceId,
  params: types_input.ResolvedParams,
  port: Int,
) -> Result(port_owner.PortOwnerRef, String) {
  let #(runner_path, runner_args) = runner_command(profile.runner, config)
  let input = provisioning_input(profile, instance_id, params)

  case
    port_owner.start_link(
      runner_path,
      runner_args,
      runner_env(),
      ".",
      input,
      config,
      Some(port),
      call_timeout_ms(config),
    )
  {
    Ok(actor.Started(data: owner, ..)) -> Ok(owner)
    Error(_) -> Error("START_SERVER_FAILED")
  }
}

fn runner_env() -> List(#(String, String)) {
  let path_env = case envoy.get("PATH") {
    Ok(path) -> [#("PATH", path)]
    Error(_) -> []
  }

  // Keep test/dev behavior aligned with `test/port_helpers.base_env/2`.
  let force_fallback = case envoy.get("SAD_WRAPPER_FORCE_FALLBACK") {
    Ok(value) -> value
    Error(_) -> "1"
  }

  list.append(path_env, [#("SAD_WRAPPER_FORCE_FALLBACK", force_fallback)])
}

fn runner_command(
  runner_def: types_runner.Runner,
  config: types_config.SadConfig,
) -> #(String, List(String)) {
  let types_config.SadConfig(runner: runner_cfg, ..) = config
  let types_config.RunnerSystemConfig(python_bin: python_bin, ..) = runner_cfg

  case runner_def.tool_config {
    types_runner.ToolConfigScript(script) -> #(python_bin, [
      script,
      ..runner_def.args
    ])

    types_runner.ToolConfigPackage(package, command, with_packages) -> {
      let args = list.append([package, ..with_packages], runner_def.args)
      #(command, args)
    }
  }
}

fn provisioning_input(
  profile: types_profile.Profile,
  instance_id: types_core.InstanceId,
  params: types_input.ResolvedParams,
) -> types_input.SadInput {
  let trace_raw = "provision-" <> types_core.instance_id_to_string(instance_id)
  let trace_id = types_core.trace_id(trace_raw)

  types_input.SadInput(
    meta: types_input.SadInputMeta(
      spec_version: "v0",
      profile_id: profile.meta.id,
      instance_id: Some(instance_id),
      mode: profile.meta.lifecycle,
    ),
    params: params,
    input: types_input.PayloadChat([], dict.new()),
    context: types_input.RequestContext(trace_id: trace_id, extra: dict.new()),
    helpers: None,
    runner_def: profile.runner,
  )
}

fn release_port_best_effort(
  config: types_config.SadConfig,
  port_pool_subject: process.Subject(messages.PortPoolMsg),
  instance_id: types_core.InstanceId,
) -> Nil {
  let _ =
    port_pool_api.release(
      port_pool_subject,
      instance_id,
      call_timeout_ms(config),
    )
  Nil
}

fn update_registry_status_best_effort(
  config: types_config.SadConfig,
  registry: process.Subject(messages.RegistryMsg),
  agent_ref: agent.AgentRef,
) -> Nil {
  let timeout_ms = agent.status_timeout_ms(config)

  case agent.status(agent_ref, timeout_ms) {
    Ok(status) ->
      registry_api.update_status(registry, status.instance_id, status)
    Error(_) -> Nil
  }
}

fn wait_for_port_free(
  cfg: types_config.SadConfig,
  host: String,
  port: Int,
) -> Nil {
  let types_config.SadConfig(timeouts: timeouts, ..) = cfg
  let types_config.SadTimeouts(shutdown_timeout_ms: shutdown_timeout_ms, ..) =
    timeouts

  // The wrapper may take up to `2 * shutdown_timeout_ms` to stop (SIGTERM + SIGKILL).
  // Keep the synchronous call bounded for typical API timeouts.
  let max_wait_ms = int.min(shutdown_timeout_ms * 2 + 250, 4500)
  let attempts = int.max(max_wait_ms / 25, 1)
  wait_for_port_free_loop(host, port, attempts)
}

fn wait_for_port_free_loop(host: String, port: Int, attempts: Int) -> Nil {
  case attempts {
    0 -> Nil
    _ ->
      case port_check.check_available(host, port) {
        Ok(_) -> Nil
        Error(_) -> {
          process.sleep(25)
          wait_for_port_free_loop(host, port, attempts - 1)
        }
      }
  }
}

fn cleanup_workspace(
  config: types_config.SadConfig,
  instance_id: types_core.InstanceId,
) -> Result(Nil, String) {
  let types_config.SadConfig(storage: storage, ..) = config
  let types_config.StorageConfig(workspaces_directory: base_dir, ..) = storage

  let path = workspace.workspace_for_instance(base_dir, instance_id)

  case simplifile.delete_all(paths: [path]) {
    Ok(_) -> Ok(Nil)
    Error(err) -> Error(string.inspect(err))
  }
}
