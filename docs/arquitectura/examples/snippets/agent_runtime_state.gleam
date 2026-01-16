/// Buffer de logs con política drop-oldest.
/// Las líneas se almacenan en orden cronológico [oldest, ..., newest].
/// Se guarda el LogEvent completo para conservar ts_ms y trace_id.
pub type LogBuffer {
  LogBuffer(lines: Deque(LogEvent), total_bytes: Int)
}

// SaarConfig está definido en tipos.md §8.1
// Es el SSOT para la configuración del sistema.
//
// Importar como:
//   import saar/types.{
//     type SaarConfig,
//     resolve_call_timeout,
//   }

/// Estado completo del actor en runtime.
/// Usa ActorMode (ADT) en lugar de Option(InFlight).
pub type AgentRuntimeState {
  AgentRuntimeState(
    profile: Profile,
    instance_id: InstanceId,
    lifecycle: Lifecycle,
    workspace: String,
    /// Estado unificado: Created → Provisioning → Ready → Stopped → (Failed si error)
    state: AgentState,
    /// Modo operativo: Idle o Busy(InFlight)
    /// ADT explícito que hace imposible estados inválidos
    mode: ActorMode,
    log_buffer: LogBuffer,
    log_subscriber: Option(Subject(LogEvent)),
    config: SaarConfig,
    /// Dependencias internas (inyectadas por AgentManagerActor).
    /// El core depende de un record (`Bridge`) en lugar de módulos concretos del bridge.
    deps: AgentDeps,
    /// Selector actual del actor.
    /// Se actualiza dinámicamente para añadir/quitar monitores de workers.
    selector: Selector(AgentMsg),
    /// Puerto asignado para agentes continuous (None para transient).
    assigned_port: Option(Int),
  )
}
