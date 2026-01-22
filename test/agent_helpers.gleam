import gleam/dict
import gleam/erlang/process
import gleam/option
import gleam/otp/actor
import saar/core/agent
import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/enums as types_enums
import saar/types/profile as types_profile
import saar/types/runner as types_runner

pub fn workspace_root() -> String {
  "./workspaces/test"
}

pub fn default_config() -> types_config.SaarConfig {
  // Use an ephemeral port in tests to avoid collisions.
  types_config.SaarConfig(..types_config.default_saar_config(), server_port: 0)
}

pub fn with_call_timeout_ms(
  cfg: types_config.SaarConfig,
  ms: Int,
) -> types_config.SaarConfig {
  let types_config.SaarConfig(timeouts: timeouts, ..) = cfg
  let next_timeouts = types_config.SaarTimeouts(..timeouts, call_timeout_ms: ms)
  types_config.SaarConfig(..cfg, timeouts: next_timeouts)
}

pub fn with_log_buffer_bytes(
  cfg: types_config.SaarConfig,
  bytes: Int,
) -> types_config.SaarConfig {
  let types_config.SaarConfig(limits: limits, ..) = cfg
  let next_limits = types_config.SaarLimits(..limits, log_buffer_bytes: bytes)
  types_config.SaarConfig(..cfg, limits: next_limits)
}

pub fn test_profile(
  lifecycle: types_enums.Lifecycle,
  caps: dict.Dict(String, types_profile.RunnerCapability),
) -> types_profile.Profile {
  types_profile.Profile(
    meta: types_profile.ProfileMeta(
      id: types_core.profile_id("p"),
      name: option.None,
      lifecycle: lifecycle,
      description: "test",
    ),
    parameters: dict.new(),
    runner: types_runner.Runner(
      type_: "test",
      tool_config: types_runner.ToolConfigScript(""),
      runtime: types_runner.default_runtime_config(),
      env_map: dict.new(),
      args: [],
      artifact_config: types_runner.default_artifact_config(),
      exec_path: option.None,
    ),
    interface: types_profile.RunnerInterface(capabilities: caps),
  )
}

pub fn start_agent(
  profile: types_profile.Profile,
  instance_id: types_core.InstanceId,
  config: types_config.SaarConfig,
  deps: agent.AgentDeps,
) -> agent.AgentRef {
  let artifact_registry = process.new_subject()

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      workspace_root(),
      config,
      artifact_registry,
      deps,
      1000,
    )

  agent_ref
}
