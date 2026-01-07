fn handle_server_died(
  state: AgentRuntimeState,
  exit_code: Int,
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  // Solo aplica a agentes continuous
  case state.lifecycle {
    Transient -> {
      // No debería ocurrir, ignorar
      actor.continue(state)
    }
    Continuous -> {
      // Si hay interacción en curso, responder error
      let state = case state.mode {
        Idle -> state
        Busy(in_flight) -> {
          let InFlight(req, reply_channel, handle) = in_flight
          
          // Limpiar monitor del worker
          process.demonitor_process(interaction_handle_monitor(handle))
          
          // Responder error al cliente (ReplyChannel es alias de Subject)
          let err = InteractionError(
            InfraError,
            "Server died unexpectedly with exit code " <> int.to_string(exit_code),
            req.trace_id,
          )
          process.send(reply_channel, Error(err))
          
          AgentRuntimeState(..state, mode: Idle)
        }
      }
      
      // Transitar a Failed (estado unificado)
      let reason = "Server exited with code " <> int.to_string(exit_code)
      let new_state = AgentRuntimeState(
        ..state,
        state: agent_failed(reason),
      )
      
      actor.continue(new_state)
    }
  }
}
