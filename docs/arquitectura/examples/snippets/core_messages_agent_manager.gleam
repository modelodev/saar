// Extracted reference snippet (v0)
// Source: arquitectura/tipos.md:144
// Purpose: documentation-only; may not compile as-is.

// Ubicación: sad/core/messages.gleam
import gleam/otp/actor
import sad/core/agent as agent

/// Argumentos para crear un agente.
pub type StartArgs {
  StartArgs(
    /// Snapshot del perfil en el momento de creación (v0).
    /// `POST /sys/reload-profiles` solo afecta a nuevas instancias.
    profile: Profile,
    instance_id: InstanceId,
    params: ResolvedParams,  // YA RESUELTOS
    workspace: String,
    config: SadConfig,
  )
}

/// Protocolo del manager de instancias (AgentManagerActor).
pub type AgentManagerMsg {
  // Gestión de instancias
  StartAgent(StartArgs, Subject(Result(agent.AgentRef, StartError)))
  /// Detiene una instancia sin eliminarla: para proceso y transita a `AgentState.Stopped`.
  /// No limpia workspace ni purga artefactos; la instancia sigue existiendo.
  StopAgent(InstanceKey, Subject(Result(Nil, StopError)))
  /// Elimina una instancia: stop + cleanup de workspace + purge artefactos + release port + unregister + terminate.
  /// Semántica: idempotente solo para "no existe" (Ok). Si existe y el cleanup falla, responde `DeleteError`.
  DeleteAgent(InstanceKey, Subject(Result(Nil, DeleteError)))
  ListAgents(Subject(List(InstanceKey)))
}

/// Errores al crear un agente.
pub type StartError {
  InitFailed(String)
  RegistrationFailed(RegistryError)
  ProfileNotFound(ProfileId)
  ParamResolutionFailed(String)
  StartChildFailed(actor.StartError)
}

/// Errores al detener un agente.
pub type StopError {
  AgentNotFound
  StopTimeout
}

/// Errores al eliminar un agente.
/// Nota: en v0, `delete` es idempotente solo para "no existe" (Ok). Si existe y falla el cleanup, responde error.
pub type DeleteError {
  DeleteTimeout
  CleanupFailed(String)
}
