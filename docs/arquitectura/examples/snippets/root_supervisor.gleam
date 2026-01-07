// Extracted reference snippet (v0)
// Source: arquitectura/actores.md:1138
// Purpose: documentation-only; may not compile as-is.

import gleam/erlang/process.{type Name, type Subject} as process
import gleam/dict.{type Dict}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor.{type Supervisor} as supervisor
import gleam/otp/supervision
import gleam/result
import sad/core/agent as agent
import sad/core/agent_manager
import sad/core/artifact_registry
import sad/core/port_pool_actor
import sad/core/profiles
import sad/core/registry
import sad/bridge/bridge
import sad/gateway/http_server
import sad/app_state.{type AppState}
import sad/core/messages.{
  type AgentManagerMsg, type ArtifactRegistryMsg, type RegistryMsg, type ProfilesMsg, type PortPoolMsg,
  type StartArgs,
}
import sad/types.{type Profile, type ProfileId}

/// Nombres de procesos (átomos) a crear una única vez en el arranque.
///
/// IMPORTANTE: `process.new_name` genera átomos; debe ejecutarse solo en startup,
/// nunca dentro de un loop ni en procesos reiniciables.
pub type RootNames {
  RootNames(
    registry: Name(RegistryMsg),
    artifact_registry: Name(ArtifactRegistryMsg),
    port_pool: Name(PortPoolMsg),
    profiles: Name(ProfilesMsg),
    agent_factory: Name(factory_supervisor.Message(StartArgs, agent.AgentRef)),
    agent_manager: Name(AgentManagerMsg),
  )
}

pub fn new_names() -> RootNames {
  RootNames(
    registry: process.new_name("sad_registry"),
    artifact_registry: process.new_name("sad_artifact_registry"),
    port_pool: process.new_name("sad_port_pool"),
    profiles: process.new_name("sad_profiles"),
    agent_factory: process.new_name("sad_agent_factory"),
    agent_manager: process.new_name("sad_agent_manager"),
  )
}

/// Referencia al supervisor raíz.
pub opaque type SupervisorRef {
  SupervisorRef(
    supervisor: Supervisor,
    registry: Subject(RegistryMsg),
    artifact_registry: Subject(ArtifactRegistryMsg),
    port_pool: Subject(PortPoolMsg),
    profiles: Subject(ProfilesMsg),
    agent_manager: Subject(AgentManagerMsg),
  )
}

/// Arranca el árbol de supervisión completo.
pub fn start(app_state: AppState, names: RootNames) -> actor.StartResult(SupervisorRef) {
  // El supervisor raíz es estático: siempre tiene los mismos hijos.
  // Orden importa: Registry/ArtifactRegistry/PortPool antes del subtree dependiente (manager + factory + http).
  let RootNames(registry_name, artifact_registry_name, port_pool_name, profiles_name, agent_factory_name, agent_manager_name) = names

  // Subjects deterministas vía nombre (no requieren descubrir PIDs ni "which_children").
  let registry_subject = process.named_subject(registry_name)
  let artifact_registry_subject = process.named_subject(artifact_registry_name)
  let port_pool_subject = process.named_subject(port_pool_name)
  let profiles_subject = process.named_subject(profiles_name)
  let agent_manager_subject = process.named_subject(agent_manager_name)

  // Referencia al supervisor de factory vía nombre (evita pasar PIDs).
  let agent_factory = factory_supervisor.get_by_name(agent_factory_name)

  let deps = agent_manager.ManagerDeps(
    registry_subject,
    artifact_registry_subject,
    bridge.default_bridge(),
    agent_factory,
  )

  let spec =
    supervisor.new(supervisor.RestForOne)
    |> supervisor.restart_tolerance(intensity: 5, period: 60)
    |> supervisor.add(registry_child_spec(registry_name))
    |> supervisor.add(artifact_registry_child_spec(artifact_registry_name))
    |> supervisor.add(port_pool_child_spec(port_pool_name, app_state.config.port_range_min, app_state.config.port_range_max))
    |> supervisor.add(profiles_child_spec(profiles_name, app_state.initial_profiles))
    |> supervisor.add(agent_manager_child_spec(app_state, deps, agent_manager_name))
    |> supervisor.add(agent_factory_child_spec(app_state, artifact_registry_subject, port_pool_subject, agent_factory_name))
    |> supervisor.add(http_server_child_spec(app_state, agent_manager_subject))

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
      ),
    )
  })
}

fn registry_child_spec(
  name: Name(RegistryMsg),
) -> supervision.ChildSpecification(Subject(RegistryMsg)) {
  supervision.worker(fn() { registry.start(name) })
}

fn artifact_registry_child_spec(
  name: Name(ArtifactRegistryMsg),
) -> supervision.ChildSpecification(Subject(ArtifactRegistryMsg)) {
  supervision.worker(fn() { artifact_registry.start(name) })
}

fn port_pool_child_spec(
  name: Name(PortPoolMsg),
  min_port: Int,
  max_port: Int,
) -> supervision.ChildSpecification(Subject(PortPoolMsg)) {
  supervision.worker(fn() { port_pool_actor.start(name, min_port, max_port) })
}

fn profiles_child_spec(
  name: Name(ProfilesMsg),
  initial_profiles: Dict(ProfileId, Profile),
) -> supervision.ChildSpecification(Subject(ProfilesMsg)) {
  supervision.worker(fn() { profiles.start(name, initial_profiles) })
}

fn agent_factory_child_spec(
  app_state: AppState,
  artifact_registry: Subject(ArtifactRegistryMsg),
  port_pool: Subject(PortPoolMsg),
  name: Name(factory_supervisor.Message(StartArgs, agent.AgentRef)),
) -> supervision.ChildSpecification(factory_supervisor.Supervisor(StartArgs, agent.AgentRef)) {
  let agent_deps = agent.AgentDeps(
    artifact_registry: artifact_registry,
    port_pool: port_pool,
    bridge: bridge.default_bridge(),
  )

  factory_supervisor.worker_child(fn(args: StartArgs) { agent.start_link(args, agent_deps, 10_000) })
  |> factory_supervisor.restart_strategy(supervision.Temporary)
  |> factory_supervisor.named(name)
  |> factory_supervisor.supervised
}

fn agent_manager_child_spec(
  app_state: AppState,
  deps: agent_manager.ManagerDeps,
  name: Name(AgentManagerMsg),
) -> supervision.ChildSpecification(Subject(AgentManagerMsg)) {
  supervision.worker(fn() { agent_manager.start(app_state, deps, name) })
  |> supervision.timeout(-1)
}

fn http_server_child_spec(
  app_state: AppState,
  agent_manager_subject: Subject(AgentManagerMsg),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() { http_server.start(app_state.config, agent_manager_subject) })
}

/// Obtiene referencia al registry.
pub fn registry(ref: SupervisorRef) -> Subject(RegistryMsg) {
  ref.registry
}

/// Obtiene referencia al ArtifactRegistry.
pub fn artifact_registry(ref: SupervisorRef) -> Subject(ArtifactRegistryMsg) {
  ref.artifact_registry
}

/// Obtiene referencia al ProfilesActor.
pub fn profiles(ref: SupervisorRef) -> Subject(ProfilesMsg) {
  ref.profiles
}

/// Obtiene referencia al AgentManagerActor.
pub fn agent_manager(ref: SupervisorRef) -> Subject(AgentManagerMsg) {
  ref.agent_manager
}
