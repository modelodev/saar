////
//// Mission: start and hold the SAD core OTP supervision tree.
////
//// Responsibilities:
//// - Define the canonical child start order.
//// - Configure `RestForOne` restart semantics and restart tolerance.
//// - Provide stable access to named core subjects.
////
//// Non-responsibilities:
//// - Implementing AgentActor/AgentManager business logic.
//// - Parsing configuration or performing startup IO.
////
//// Relationships:
//// - Uses `sad/core/supervisor_names` for stable process names.
//// - Starts the SSOT actors: registry, profiles, artifact registry, port pool.

import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor.{type Supervisor} as supervisor
import gleam/otp/supervision
import gleam/result
import sad/app_state
import sad/core/agent
import sad/core/agent_factory_supervisor
import sad/core/agent_manager
import sad/core/artifact_registry
import sad/core/messages
import sad/core/port_pool_actor
import sad/core/profiles
import sad/core/registry
import sad/core/supervisor_names
import sad/gateway/http_server
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/profile as types_profile

/// Reference to the started core supervisor tree.
pub opaque type SupervisorRef {
  SupervisorRef(
    supervisor: Supervisor,
    registry: process.Subject(messages.RegistryMsg),
    artifact_registry: process.Subject(messages.ArtifactRegistryMsg),
    port_pool: process.Subject(messages.PortPoolMsg),
    profiles: process.Subject(messages.ProfilesMsg),
    agent_manager: process.Subject(messages.AgentManagerMsg),
    agent_factory: factory_supervisor.Supervisor(
      messages.StartArgs,
      agent.AgentRef,
    ),
  )
}

/// Starts the full core supervision tree.
///
/// The child order is canonical and must remain stable:
/// Registry -> ArtifactRegistry -> PortPoolActor -> ProfilesActor -> AgentManagerActor -> AgentFactorySupervisor -> HttpServer.
pub fn start(
  state: app_state.AppState,
  names: supervisor_names.RootNames,
) -> actor.StartResult(SupervisorRef) {
  let supervisor_names.RootNames(
    registry_name,
    artifact_registry_name,
    port_pool_name,
    profiles_name,
    agent_manager_name,
    agent_factory_name,
  ) = names

  let registry_subject = process.named_subject(registry_name)
  let artifact_registry_subject = process.named_subject(artifact_registry_name)
  let port_pool_subject = process.named_subject(port_pool_name)
  let profiles_subject = process.named_subject(profiles_name)
  let agent_manager_subject = process.named_subject(agent_manager_name)

  let agent_factory = factory_supervisor.get_by_name(agent_factory_name)

  let app_state.AppState(config: config, initial_profiles: initial_profiles) =
    state
  let types_config.SadConfig(runner: runner_cfg, ..) = config
  let types_config.RunnerSystemConfig(
    port_range_min: min_port,
    port_range_max: max_port,
    ..,
  ) = runner_cfg

  let spec =
    supervisor.new(supervisor.RestForOne)
    |> supervisor.restart_tolerance(intensity: 5, period: 60)
    |> supervisor.add(registry_child_spec(registry_name))
    |> supervisor.add(artifact_registry_child_spec(artifact_registry_name))
    |> supervisor.add(port_pool_child_spec(port_pool_name, min_port, max_port))
    |> supervisor.add(profiles_child_spec(profiles_name, initial_profiles))
    |> supervisor.add(agent_manager_child_spec(
      agent_manager_name,
      config,
      registry_subject,
      artifact_registry_subject,
      port_pool_subject,
      profiles_subject,
      agent_factory,
    ))
    |> supervisor.add(agent_factory_child_spec(agent_factory_name))
    |> supervisor.add(http_server_child_spec(
      config,
      registry_subject,
      profiles_subject,
      agent_manager_subject,
    ))

  supervisor.start(spec)
  |> result.map(fn(started) {
    actor.Started(
      pid: started.pid,
      data: SupervisorRef(
        supervisor: started.data,
        registry: registry_subject,
        artifact_registry: artifact_registry_subject,
        port_pool: port_pool_subject,
        profiles: profiles_subject,
        agent_manager: agent_manager_subject,
        agent_factory: agent_factory,
      ),
    )
  })
}

fn registry_child_spec(
  name: process.Name(messages.RegistryMsg),
) -> supervision.ChildSpecification(process.Subject(messages.RegistryMsg)) {
  supervision.worker(fn() { registry.start(name) })
}

fn artifact_registry_child_spec(
  name: process.Name(messages.ArtifactRegistryMsg),
) -> supervision.ChildSpecification(
  process.Subject(messages.ArtifactRegistryMsg),
) {
  supervision.worker(fn() { artifact_registry.start(name) })
}

fn port_pool_child_spec(
  name: process.Name(messages.PortPoolMsg),
  min_port: Int,
  max_port: Int,
) -> supervision.ChildSpecification(process.Subject(messages.PortPoolMsg)) {
  supervision.worker(fn() { port_pool_actor.start(name, min_port, max_port) })
}

fn profiles_child_spec(
  name: process.Name(messages.ProfilesMsg),
  initial_profiles: Dict(types_core.ProfileId, types_profile.Profile),
) -> supervision.ChildSpecification(process.Subject(messages.ProfilesMsg)) {
  supervision.worker(fn() { profiles.start(name, initial_profiles) })
}

fn agent_manager_child_spec(
  name: process.Name(messages.AgentManagerMsg),
  config: types_config.SadConfig,
  registry: process.Subject(messages.RegistryMsg),
  artifact_registry: process.Subject(messages.ArtifactRegistryMsg),
  port_pool: process.Subject(messages.PortPoolMsg),
  profiles_subject: process.Subject(messages.ProfilesMsg),
  agent_factory: factory_supervisor.Supervisor(
    messages.StartArgs,
    agent.AgentRef,
  ),
) -> supervision.ChildSpecification(process.Subject(messages.AgentManagerMsg)) {
  supervision.worker(fn() {
    agent_manager.start(
      name,
      config,
      registry,
      artifact_registry,
      port_pool,
      profiles_subject,
      agent_factory,
    )
  })
  |> supervision.timeout(-1)
}

fn agent_factory_child_spec(
  name: process.Name(
    factory_supervisor.Message(messages.StartArgs, agent.AgentRef),
  ),
) -> supervision.ChildSpecification(
  factory_supervisor.Supervisor(messages.StartArgs, agent.AgentRef),
) {
  supervision.supervisor(fn() { agent_factory_supervisor.start(name) })
}

fn http_server_child_spec(
  config: types_config.SadConfig,
  registry: process.Subject(messages.RegistryMsg),
  profiles: process.Subject(messages.ProfilesMsg),
  agent_manager: process.Subject(messages.AgentManagerMsg),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    http_server.start(config, registry, profiles, agent_manager)
  })
}

/// Returns the named registry subject.
pub fn registry(ref: SupervisorRef) -> process.Subject(messages.RegistryMsg) {
  ref.registry
}

/// Returns the named artifact registry subject.
pub fn artifact_registry(
  ref: SupervisorRef,
) -> process.Subject(messages.ArtifactRegistryMsg) {
  ref.artifact_registry
}

/// Returns the named profiles subject.
pub fn profiles(ref: SupervisorRef) -> process.Subject(messages.ProfilesMsg) {
  ref.profiles
}

/// Returns the named port pool subject.
pub fn port_pool(ref: SupervisorRef) -> process.Subject(messages.PortPoolMsg) {
  ref.port_pool
}

/// Returns the named agent manager subject.
pub fn agent_manager(
  ref: SupervisorRef,
) -> process.Subject(messages.AgentManagerMsg) {
  ref.agent_manager
}

/// Returns the factory supervisor handle.
pub fn agent_factory(
  ref: SupervisorRef,
) -> factory_supervisor.Supervisor(messages.StartArgs, agent.AgentRef) {
  ref.agent_factory
}
