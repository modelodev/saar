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
//// - Uses the core message protocols (`sad/core/messages`) and crash-only `process.call`.
//// - Boundary layers should call this actor via `sad/otp/safe_call`.
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
import sad/bridge/http_client
import sad/bridge/port_owner

import sad/core/agent
import sad/core/artifact_registry_protocol
import sad/core/messages
import sad/core/provisioning_policy
import sad/net/port_check
import sad/params
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
  artifact_registry: process.Subject(
    artifact_registry_protocol.ArtifactRegistryMsg,
  ),
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
    artifact_registry: process.Subject(
      artifact_registry_protocol.ArtifactRegistryMsg,
    ),
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

    messages.StartExistingAgent(instance_id, reply_to) ->
      handle_start_existing_agent(state, instance_id, reply_to)

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
  let State(
    config: config,
    profiles: profiles,
    artifact_registry: artifact_registry,
    ..,
  ) = state

  let profile_out =
    process.call(profiles, call_timeout_ms(config), fn(reply) {
      messages.GetProfile(profile_id, reply)
    })

  case profile_out {
    None -> {
      process.send(reply_to, Error(messages.ProfileNotFound(profile_id)))
      actor.continue(state)
    }

    Some(profile) ->
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
              artifact_registry: artifact_registry,
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

  let keys = profile_config_param_keys(parameters)
  let config_values = types_config.config_values_for_keys(config, keys)

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

fn profile_config_param_keys(
  parameters: dict.Dict(String, types_profile.Parameter),
) -> List(String) {
  parameters
  |> dict.to_list
  |> list.flat_map(fn(entry) {
    let #(param_name, param) = entry

    case param {
      types_profile.ConfigParam(key, _, _) -> [key]
      _ -> {
        let _ = param_name
        []
      }
    }
  })
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

  let messages.StartArgs(
    profile: profile,
    instance_id: instance_id,
    workspace: workspace_dir,
    ..,
  ) = args

  case simplifile.create_directory_all(workspace_dir) {
    Error(err) -> {
      process.send(
        reply_to,
        Error(messages.InitFailed(
          "workspace_create_failed: " <> string.inspect(err),
        )),
      )
      actor.continue(state)
    }

    Ok(_) -> {
      case factory_supervisor.start_child(factory, args) {
        Error(err) -> {
          process.send(reply_to, Error(start_error_from_actor_start_error(err)))
          actor.continue(state)
        }

        Ok(actor.Started(data: agent_ref, ..)) -> {
          let status = initial_status(profile, instance_id)

          let register_out =
            process.call(registry, registry_timeout_ms(config), fn(reply_to) {
              messages.Register(status, agent_ref, reply_to)
            })

          case register_out {
            Ok(_) -> {
              // Transition to Provisioning quickly, then provision asynchronously.
              agent.start_instance(agent_ref)

              process.send(
                registry,
                messages.UpdateStatus(
                  instance_id,
                  types_agent.AgentStatusView(
                    ..status,
                    phase: types_agent.Provisioning,
                  ),
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

            Error(registry_err) -> {
              agent.terminate(agent_ref, agent.SupervisorCleanup)
              process.send(
                reply_to,
                Error(messages.RegistrationFailed(registry_err)),
              )
              actor.continue(state)
            }
          }
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

  let current_status =
    process.call(registry, registry_timeout_ms(config), fn(reply_to) {
      messages.LookupStatusByInstanceId(instance_id, reply_to)
    })

  case current_status {
    None -> {
      process.send(reply_to, Ok(Nil))
      actor.continue(state)
    }

    Some(status) -> {
      let found =
        process.call(registry, registry_timeout_ms(config), fn(reply_to) {
          messages.LookupByInstanceId(instance_id, reply_to)
        })

      case found {
        Some(agent_ref) -> {
          agent.stop_instance(agent_ref, agent.UserRequested)
        }

        None -> Nil
      }

      // For managed ports, block briefly until the OS port is free before releasing.
      // This prevents flakiness when starting the next instance immediately.
      case status.assigned_port {
        Some(port) ->
          wait_for_port_free(config, managed_port_host(config), port)
        None -> Nil
      }

      let stopped_status =
        types_agent.AgentStatusView(
          ..status,
          phase: types_agent.Stopped,
          mode: types_agent.RunIdle,
          assigned_port: None,
          failure_reason: None,
        )

      process.send(registry, messages.UpdateStatus(instance_id, stopped_status))

      let _ =
        process.call(port_pool, call_timeout_ms(config), fn(reply_to) {
          messages.Release(instance_id, reply_to)
        })

      process.send(reply_to, Ok(Nil))
      actor.continue(state)
    }
  }
}

fn handle_start_existing_agent(
  state: State,
  instance_id: types_core.InstanceId,
  reply_to: process.Subject(Result(Nil, Nil)),
) -> actor.Next(State, messages.AgentManagerMsg) {
  let State(
    config: config,
    registry: registry,
    artifact_registry: artifact_registry,
    port_pool: port_pool,
    ..,
  ) = state

  let found =
    process.call(registry, registry_timeout_ms(config), fn(reply_to) {
      messages.LookupByInstanceId(instance_id, reply_to)
    })

  case found {
    None -> {
      process.send(reply_to, Ok(Nil))
      actor.continue(state)
    }

    Some(agent_ref) -> {
      agent.start_instance(agent_ref)

      let _ =
        process.spawn(fn() {
          case
            agent.internal_start_snapshot(
              agent_ref,
              agent.status_timeout_ms(config),
            )
          {
            Error(_) -> {
              agent.internal_provisioning_done(
                agent_ref,
                Error(types_agent.StartSnapshotFailed),
              )
              update_registry_status_best_effort(config, registry, agent_ref)
            }

            Ok(snapshot) -> {
              let agent.StartSnapshot(
                profile: profile,
                instance_id: snap_instance_id,
                params: params,
                workspace: workspace,
                config: snap_config,
              ) = snapshot

              let args =
                messages.StartArgs(
                  profile: profile,
                  instance_id: snap_instance_id,
                  params: params,
                  workspace: workspace,
                  config: snap_config,
                  artifact_registry: artifact_registry,
                )

              let outcome = provision(snap_config, port_pool, args)
              agent.internal_provisioning_done(agent_ref, outcome)
              update_registry_status_best_effort(
                snap_config,
                registry,
                agent_ref,
              )
            }
          }
        })

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

  // Lookup is best-effort: instances may already be gone, but deletion should
  // still purge artifacts and clean up the workspace.
  let found =
    process.call(registry, registry_timeout_ms(config), fn(reply_to) {
      messages.LookupByInstanceId(instance_id, reply_to)
    })

  case found {
    Some(agent_ref) -> {
      agent.stop_instance(agent_ref, agent.Deleted)
      agent.terminate(agent_ref, agent.Deleted)
    }
    None -> Nil
  }

  let _ =
    process.call(artifact_registry, call_timeout_ms(config), fn(reply_to) {
      artifact_registry_protocol.PurgeByInstance(instance_id, reply_to)
    })

  process.send(registry, messages.UnregisterByInstanceId(instance_id))

  let _ =
    process.call(port_pool, call_timeout_ms(config), fn(reply_to) {
      messages.Release(instance_id, reply_to)
    })

  case cleanup_workspace(config, instance_id) {
    Ok(_) -> process.send(reply_to, Ok(Nil))
    Error(reason) ->
      process.send(reply_to, Error(messages.CleanupFailed(reason)))
  }

  actor.continue(state)
}

fn handle_list_agents(
  state: State,
  reply_to: process.Subject(List(types_agent.InstanceSummary)),
) -> actor.Next(State, messages.AgentManagerMsg) {
  let State(config: config, registry: registry, ..) = state

  let items =
    process.call(registry, registry_timeout_ms(config), fn(reply_to) {
      messages.ListAll(reply_to)
    })

  process.send(reply_to, items)

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
    agent.internal_provisioning_done(agent_ref, outcome)
    update_registry_status_best_effort(config, registry, agent_ref)
  })
}

fn provision(
  config: types_config.SadConfig,
  port_pool: process.Subject(messages.PortPoolMsg),
  args: messages.StartArgs,
) -> Result(#(agent.AgentState, Option(Int)), types_agent.FailureReason) {
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
) -> Result(#(agent.AgentState, Option(Int)), types_agent.FailureReason) {
  let types_runner.RuntimeConfig(mode: mode, ..) = profile.runner.runtime

  case mode {
    types_runner.NoNetwork -> Error(types_agent.NoNetwork)

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
        http_client.request_sync_string(
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
) -> Result(#(agent.AgentState, Option(Int)), types_agent.FailureReason) {
  provision_continuous_managed_port_retry(
    config,
    port_pool_subject,
    profile,
    instance_id,
    params,
    5,
    None,
  )
}

fn provision_continuous_managed_port_retry(
  config: types_config.SadConfig,
  port_pool_subject: process.Subject(messages.PortPoolMsg),
  profile: types_profile.Profile,
  instance_id: types_core.InstanceId,
  params: types_input.ResolvedParams,
  remaining: Int,
  last_failure: Option(types_agent.FailureReason),
) -> Result(#(agent.AgentState, Option(Int)), types_agent.FailureReason) {
  case remaining {
    0 ->
      case last_failure {
        Some(reason) -> Error(reason)
        None -> Error(types_agent.PortBindFailed)
      }

    _ -> {
      let host = managed_port_host(config)

      let attempt =
        attempt_provision_continuous_managed_port(
          config,
          port_pool_subject,
          profile,
          instance_id,
          params,
          host,
        )
        |> result.map(fn(pair) {
          let #(state, port) = pair
          #(state, Some(port))
        })

      case
        provisioning_policy.retry_step_with_last(
          attempt,
          remaining,
          last_failure,
        )
      {
        provisioning_policy.Done(outcome) -> outcome

        provisioning_policy.Retry(
          remaining: next_remaining,
          last_failure: next_last,
        ) ->
          provision_continuous_managed_port_retry(
            config,
            port_pool_subject,
            profile,
            instance_id,
            params,
            next_remaining,
            next_last,
          )
      }
    }
  }
}

fn attempt_provision_continuous_managed_port(
  config: types_config.SadConfig,
  port_pool_subject: process.Subject(messages.PortPoolMsg),
  profile: types_profile.Profile,
  instance_id: types_core.InstanceId,
  params: types_input.ResolvedParams,
  host: String,
) -> Result(#(agent.AgentState, Int), types_agent.FailureReason) {
  use port <- result.try(allocate_port(
    config,
    port_pool_subject,
    instance_id,
    host,
  ))

  // Port availability is checked once by the port pool allocation.
  process.sleep(20)

  case start_port_owner(config, profile, instance_id, params, port) {
    Ok(owner) ->
      case wait_for_health_ready(profile.interface, host, port, config) {
        Ok(_) -> {
          let resource = agent.port_owner_resource(owner)
          Ok(#(agent.agent_ready_continuous(params, resource), port))
        }

        Error(_) -> {
          let _ = port_owner.stop(owner, 1000)
          release_port_best_effort(config, port_pool_subject, instance_id)
          Error(types_agent.PortBindFailed)
        }
      }

    Error(reason) -> {
      release_port_best_effort(config, port_pool_subject, instance_id)
      Error(reason)
    }
  }
}

fn allocate_port(
  config: types_config.SadConfig,
  port_pool_subject: process.Subject(messages.PortPoolMsg),
  instance_id: types_core.InstanceId,
  host: String,
) -> Result(Int, types_agent.FailureReason) {
  let out =
    process.call(port_pool_subject, call_timeout_ms(config), fn(reply_to) {
      messages.AllocateChecked(host, instance_id, reply_to)
    })

  case out {
    Ok(port) -> Ok(port)
    Error(err) -> Error(provisioning_policy.from_port_pool_error(err))
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
) -> Result(port_owner.PortOwnerRef, types_agent.FailureReason) {
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
    Error(actor.InitFailed(reason)) ->
      Error(provisioning_policy.from_port_owner_start_reason(reason))
    Error(_) -> Error(types_agent.StartServerFailed)
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
    process.call(port_pool_subject, call_timeout_ms(config), fn(reply_to) {
      messages.Release(instance_id, reply_to)
    })
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
      process.send(registry, messages.UpdateStatus(status.instance_id, status))
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
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(err) -> Error(string.inspect(err))
  }
}
