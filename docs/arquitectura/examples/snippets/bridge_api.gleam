// Ubicación: sad/bridge/bridge.gleam
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{type Option}
import sad/core/agent.{type AgentRef}
import sad/core/messages.{type ArtifactRegistryMsg, type InteractionHandle}
import sad/streams/sink.{type StreamSink}
import sad/types.{
  type AgentRequest, type AgentResource, type InstanceId, type Profile,
  type ResolvedParams, type SadConfig,
}

/// Contexto mínimo que el bridge necesita para ejecutar IO.
/// No contiene `Bridge` para evitar tipos recursivos.
pub type BridgeCtx {
  BridgeCtx(
    profile: Profile,
    instance_id: InstanceId,
    params: ResolvedParams,
    workspace: String,
    assigned_port: Option(Int),
    config: SadConfig,
    artifact_registry: Subject(ArtifactRegistryMsg),
  )
}

/// Fachada inyectable del bridge (Ports & Adapters).
pub type Bridge {
  Bridge(
    /// Provisioning (spawn de worker que terminará en `agent.internal_provisioning_done(...)`).
    start_provisioning: fn(BridgeCtx, AgentRef) -> Pid,
    /// Interacción (spawn de worker que terminará en `agent.internal_interaction_done(...)`).
    start_interaction: fn(
      BridgeCtx,
      AgentRequest,
      AgentRef,
      Int,
      Bool,
      Option(StreamSink),
    ) ->
      Pid,
    /// Cancela interacción matando el worker BEAM (no señales directas al OS).
    cancel_interaction: fn(InteractionHandle) -> Nil,
    /// Stop del servidor continuous (si aplica).
    stop_server: fn(AgentResource) -> Nil,
  )
}

/// Implementación por defecto (producción): delega en `runner.gleam` y `client.gleam`.
pub fn default_bridge() -> Bridge {
  Bridge(
    start_provisioning: runner.start_provisioning,
    start_interaction: fn(ctx, req, agent, timeout_ms, streaming, sink) {
      case ctx.profile.interface {
        RunnerInterface(_) ->
          runner.start_interaction(ctx, req, agent, timeout_ms, streaming, sink)
        HttpInterface(_, _, _, _) ->
          client.start_interaction(ctx, req, agent, timeout_ms, streaming, sink)
      }
    },
    cancel_interaction: runner.cancel_interaction,
    stop_server: runner.stop_server,
  )
}
