fn handle_worker_down(
  state: AgentRuntimeState,
  down: process.Down,
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  case state.mode {
    // No estamos esperando ningún worker, ignorar
    Idle -> actor.continue(state)

    // Verificar si es nuestro worker el que murió
    Busy(in_flight) -> {
      let InFlight(req, reply_channel, handle) = in_flight
      let worker_pid = interaction_handle_pid(handle)

      // Verificar que el Down es del worker que estamos esperando
      case down {
        process.ProcessDown(pid: down_pid, ..) if down_pid == worker_pid -> {
          // Limpiar monitor
          process.demonitor_process(interaction_handle_monitor(handle))
          let new_selector =
            state.selector
            |> process.deselect_specific_monitor(interaction_handle_monitor(
              handle,
            ))

          // Responder error al cliente (ReplyChannel es alias de Subject)
          let err =
            InteractionError(
              InfraError,
              "Worker process died unexpectedly",
              req.trace_id,
            )
          process.send(reply_channel, Error(err))

          // Volver a Idle
          let new_state =
            AgentRuntimeState(..state, mode: Idle, selector: new_selector)
          let AgentDeps(_artifact_registry, _port_pool, registry, _bridge) =
            state.deps
          registry_api.update_status(
            registry,
            state.instance_id,
            to_status_view(new_state),
          )

          actor.continue(new_state)
          |> actor.with_selector(new_selector)
        }

        // Down de otro proceso, ignorar
        _ -> actor.continue(state)
      }
    }
  }
}
