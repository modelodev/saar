fn handle_stop_instance(
  state: AgentRuntimeState,
  reason: StopReason,
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  // Stop es idempotente y no limpia workspace ni artefactos.
  // Delete (en el supervisor/gateway) encadena stop + cleanup posterior.
  // 1. Cancelar interacción en curso si existe
  case state.mode {
    Idle -> Nil
    Busy(in_flight) -> {
      let InFlight(req, reply_channel, handle) = in_flight
      
      // Limpiar monitor
      process.demonitor_process(interaction_handle_monitor(handle))
      
      // Cancelar el worker
      let AgentDeps(_artifact_registry, _port_pool, bridge) = state.deps
      bridge.cancel_interaction(handle)
      
      // Responder error al cliente (ReplyChannel es alias de Subject)
      let err = InteractionError(InfraError, "Agent shutting down", req.trace_id)
      process.send(reply_channel, Error(err))
    }
  }
  
  // 2. Detener servidor continuous si existe
  case state.state {
    ReadyContinuous(_, resource) -> {
      let AgentDeps(_artifact_registry, port_pool, bridge) = state.deps
      bridge.stop_server(resource)
      // Libera puerto reservado (idempotente) al completar el stop.
      // En v0, el `managed_port` se reasigna al hacer StartInstance.
      port_pool_api.release(port_pool, state.instance_id, state.config.call_timeout_ms)
    }
    _ -> Nil
  }

  // 3. Marcar la instancia como detenida (permanece en registry).
  // No termina el proceso BEAM del actor: la instancia sigue existiendo.
  let params = get_params(state.state)
    |> option.unwrap(dict.new())
  let new_state =
    AgentRuntimeState(..state, state: agent_stopped(params), mode: Idle, assigned_port: None)
  actor.continue(new_state)
}
