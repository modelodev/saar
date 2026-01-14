// Extracted reference snippet (v0)
// Source: arquitectura/actores.md:664
// Purpose: documentation-only; may not compile as-is.

import sad/types

fn to_status_view(state: AgentRuntimeState) -> types.AgentStatusView {
  let phase = case state.state {
    Created(_) -> types.Created
    Provisioning(_) -> types.Provisioning
    ReadyTransient(_) -> types.ReadyTransient
    ReadyContinuous(_, _) -> types.ReadyContinuous
    Stopped(_) -> types.Stopped
    Failed(_) -> types.Failed
  }

  let mode = case state.mode {
    Idle -> types.RunIdle
    Busy(_) -> types.RunBusy
  }

  types.AgentStatusView(
    profile_id: state.profile.meta.id,
    instance_id: state.instance_id,
    lifecycle: state.lifecycle,
    phase: phase,
    mode: mode,
    assigned_port: state.assigned_port,
    failure_reason: get_failure_reason(state.state),
  )
}

fn handle_get_status(
  state: AgentRuntimeState,
  reply_to: Subject(types.AgentStatusView),
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  process.send(reply_to, to_status_view(state))
  actor.continue(state)
}

fn handle_get_info(
  state: AgentRuntimeState,
  reply_to: Subject(types.AgentInfoView),
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  let info =
    types.AgentInfoView(
      meta: state.profile.meta,
      runner: state.profile.runner,
      interface: state.profile.interface,
      status: to_status_view(state),
    )
  process.send(reply_to, info)
  actor.continue(state)
}

fn handle_attach_logs(
  state: AgentRuntimeState,
  subscriber: Subject(LogEvent),
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  // Takeover: enviar buffer actual al nuevo suscriptor (preservar metadata completa)
  deque.to_list(state.log_buffer.lines)
  |> list.each(fn(event) { process.send(subscriber, event) })

  // Reemplazar suscriptor
  let new_state = AgentRuntimeState(..state, log_subscriber: Some(subscriber))
  actor.continue(new_state)
}

fn handle_ingest_log(
  state: AgentRuntimeState,
  event: LogEvent,
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  let LogEvent(_source, line, _ts, _trace, _maybe_ctx) = event
  let bytes = string.byte_size(line)

  // Añadir al buffer con truncado automático
  let new_buffer =
    append_log(state.log_buffer, event, state.config.log_buffer_bytes)

  // Reenviar a suscriptor si existe
  case state.log_subscriber {
    Some(sub) -> process.send(sub, event)
    None -> Nil
  }

  let new_state = AgentRuntimeState(..state, log_buffer: new_buffer)
  actor.continue(new_state)
}
