import gleam/otp/actor
import saar/bridge/bridge.{type Bridge, type BridgeCtx, BridgeCtx}
import saar/core/messages.{
  type ArtifactRegistryMsg, type PortPoolMsg, type RegistryMsg, type StartArgs,
}

/// Dependencias internas del agente.
/// v0: bridge + registry status cache + artefactos + port_pool.
pub type AgentDeps {
  AgentDeps(
    artifact_registry: Subject(ArtifactRegistryMsg),
    port_pool: Subject(PortPoolMsg),
    registry: Subject(RegistryMsg),
    bridge: Bridge,
  )
}

/// Arranca un agente como actor OTP (proceso BEAM).
/// En v0, los agentes se crean desde `AgentManagerActor` vía `AgentFactorySupervisor` con `start_link`.
pub fn start_link(
  args: StartArgs,
  deps: AgentDeps,
  init_timeout_ms: Int,
) -> actor.StartResult(AgentRef) {
  let builder =
    actor.new_with_initialiser(init_timeout_ms, fn(self) {
      // Init debe ser rápido: el provisioning pesado ocurre en un worker del bridge.
      // Si init falla, `start_link` falla y el supervisor responde `StartError`.
      todo
    })
    |> actor.on_message(handle_message)

  actor.start_link(builder)
}

/// Inicializa el estado del actor.
/// Los parámetros ya vienen resueltos; aquí NO se hace provisioning (init rápido).
fn init_state(
  args: StartArgs,
  deps: AgentDeps,
  base_selector: Selector(AgentMsg),
) -> Result(AgentRuntimeState, String) {
  let StartArgs(profile, instance_id, params, workspace, config) = args

  Ok(AgentRuntimeState(
    profile: profile,
    instance_id: instance_id,
    lifecycle: profile.meta.lifecycle,
    workspace: workspace,
    // `POST /sys/agents` responde 201 con estado provisioning:
    // la creación del actor fue OK y el provisioning empieza asíncronamente.
    state: agent_provisioning(params),
    mode: Idle,
    // Siempre empieza en Idle
    log_buffer: LogBuffer(deque.new(), 0),
    log_subscriber: None,
    config: config,
    deps: deps,
    selector: base_selector,
    assigned_port: None,
  ))
}
