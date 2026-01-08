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
      let #(state, selector) = case state.mode {
        Idle -> #(state, state.selector)
        Busy(in_flight) -> {
          let InFlight(req, reply_channel, handle) = in_flight
          let monitor = interaction_handle_monitor(handle)
          
          // Limpiar monitor y selector
          process.demonitor_process(monitor)
          let new_selector = state.selector
            |> process.deselect_specific_monitor(monitor)
          
          // Responder error al cliente (ReplyChannel es alias de Subject)
          let err = InteractionError(
            InfraError,
            "Server died unexpectedly with exit code " <> int.to_string(exit_code),
            req.trace_id,
          )
          process.send(reply_channel, Error(err))
          
          #(AgentRuntimeState(..state, mode: Idle, selector: new_selector), new_selector)
        }
      }
      
      // Solo marcar Failed si estaba ReadyContinuous
      case state.state {
        ReadyContinuous(_, _resource) -> {
          // Libera el puerto reservado (idempotente) si existía.
          case state.assigned_port {
            Some(_) -> {
              let AgentDeps(_artifact_registry, port_pool, _registry, _bridge) = state.deps
              port_pool_api.release(port_pool, state.instance_id, state.config.call_timeout_ms)
            }
            None -> Nil
          }
          
          // Transitar a Failed (estado unificado)
          let reason = "Server exited with code " <> int.to_string(exit_code)
          let new_state = AgentRuntimeState(
            ..state,
            state: agent_failed(reason),
            assigned_port: None,
          )
          let AgentDeps(_artifact_registry, _port_pool, registry, _bridge) = state.deps
          registry_api.update_status(registry, state.instance_id, to_status_view(new_state))
          
          actor.continue(new_state)
          |> actor.with_selector(selector)
        }
        _ -> {
          actor.continue(state)
          |> actor.with_selector(selector)
        }
      }
    }
  }
}
