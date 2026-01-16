////
//// Mission: host the dynamic factory supervisor used to spawn AgentActor processes.
////
//// Responsibilities:
//// - Start a named `factory_supervisor` for agent instances.
//// - Configure child restart policy (`Temporary` for v0).
//// - Provide the template used to start `saar/core/agent` instances.
////
//// Non-responsibilities:
//// - Coordinating registry or profile state (handled by `saar/core/agent_manager`).
//// - Performing provisioning or IO.
////
//// Relationships:
//// - Started under `saar/core/root_supervisor`.
//// - Used by `saar/core/agent_manager` via `factory_supervisor.get_by_name`.

import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/supervision
import saar/core/agent
import saar/core/messages
import saar/types/config as types_config

pub fn start(
  name: process.Name(
    factory_supervisor.Message(messages.StartArgs, agent.AgentRef),
  ),
) -> actor.StartResult(
  factory_supervisor.Supervisor(messages.StartArgs, agent.AgentRef),
) {
  let template = fn(args: messages.StartArgs) {
    let messages.StartArgs(
      profile: profile,
      instance_id: instance_id,
      params: params,
      workspace: workspace,
      config: config,
      artifact_registry: artifact_registry,
    ) = args

    agent.start_link(
      profile,
      instance_id,
      params,
      workspace,
      config,
      artifact_registry,
      agent.default_deps(),
      agent_init_timeout_ms(config),
    )
  }

  factory_supervisor.worker_child(template)
  |> factory_supervisor.restart_strategy(supervision.Temporary)
  |> factory_supervisor.named(name)
  |> factory_supervisor.start
}

fn agent_init_timeout_ms(cfg: types_config.SaarConfig) -> Int {
  let types_config.SaarConfig(timeouts: timeouts, ..) = cfg
  let types_config.SaarTimeouts(registry_timeout_ms: registry_timeout_ms, ..) =
    timeouts
  registry_timeout_ms
}
