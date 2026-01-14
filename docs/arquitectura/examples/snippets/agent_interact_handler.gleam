// Extracted reference snippet (v0)
// Source: arquitectura/actores.md:350
// Purpose: documentation-only; may not compile as-is.

fn handle_interact(
  state: AgentRuntimeState,
  req: AgentRequest,
  stream_sink: Option(StreamSink),
  reply_to: Subject(Result(InteractionResult, InteractionError)),
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  // Primero verificar si el agente está en estado válido
  case is_failed(state.state) {
    True -> {
      let reason =
        get_failure_reason(state.state)
        |> option.unwrap("unknown")
      let err =
        InteractionError(InfraError, "Agent failed: " <> reason, req.trace_id)
      process.send(reply_to, Error(err))
      actor.continue(state)
    }
    False -> handle_interact_by_mode(state, req, stream_sink, reply_to)
  }
}

fn handle_interact_by_mode(
  state: AgentRuntimeState,
  req: AgentRequest,
  stream_sink: Option(StreamSink),
  reply_to: Subject(Result(InteractionResult, InteractionError)),
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  case state.mode {
    // Ya hay una interacción en curso
    Busy(_) -> {
      let err = InteractionError(AgentError, "Agent is busy", req.trace_id)
      process.send(reply_to, Error(err))
      actor.continue(state)
    }

    // Disponible para nueva interacción
    Idle -> {
      case is_ready(state.state) {
        False -> {
          let err =
            InteractionError(InfraError, "Agent not ready", req.trace_id)
          process.send(reply_to, Error(err))
          actor.continue(state)
        }
        True -> start_interaction(state, req, stream_sink, reply_to)
      }
    }
  }
}

fn start_interaction(
  state: AgentRuntimeState,
  req: AgentRequest,
  stream_sink: Option(StreamSink),
  reply_to: ReplyChannel,
  // ReplyChannel es alias de Subject(Result(...))
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  let self = process.self()

  // Determinar si el caller pidió streaming (tiene sink) y si la capability lo soporta.
  let capability_streaming =
    is_streaming_capability(state.profile.interface, req.capability)
  let streaming = option.is_some(stream_sink) && capability_streaming
  // Resolver timeout efectivo (config default + capability limits) en el actor.
  let timeout_ms =
    resolve_call_timeout_for(
      state.config,
      state.profile.interface,
      req.capability,
    )

  // Construir contexto mínimo para el bridge (sin `Bridge` para evitar tipos recursivos).
  let params =
    get_params(state.state)
    |> option.unwrap(dict.new())
  let AgentDeps(artifact_registry, _port_pool, registry, bridge) = state.deps
  let ctx =
    BridgeCtx(
      profile: state.profile,
      instance_id: state.instance_id,
      params: params,
      workspace: state.workspace,
      assigned_port: state.assigned_port,
      config: state.config,
      artifact_registry: artifact_registry,
    )

  // Ejecutar interacción vía Bridge (inyectable).
  let worker_pid =
    bridge.start_interaction(ctx, req, self, timeout_ms, streaming, stream_sink)

  // Monitorear el worker para detectar crashes
  let monitor = process.monitor(worker_pid)

  // Actualizar selector para escuchar el monitor
  let new_selector =
    state.selector
    |> process.select_specific_monitor(monitor, WorkerDown)

  let handle = interaction_handle(worker_pid, monitor)
  let in_flight = InFlight(req, reply_to, handle)
  // reply_to es directamente el Subject
  let new_state =
    AgentRuntimeState(..state, mode: Busy(in_flight), selector: new_selector)

  // Actualizar cache de status (mode -> RunBusy)
  registry_api.update_status(
    registry,
    state.instance_id,
    to_status_view(new_state),
  )

  actor.continue(new_state)
  |> actor.with_selector(new_selector)
}

/// Determina si una capability tiene streaming habilitado.
fn is_streaming_capability(
  interface: Interface,
  capability_name: String,
) -> Bool {
  case interface {
    HttpInterface(_, _, _, capabilities) -> {
      case dict.get(capabilities, capability_name) {
        Ok(cap) -> cap.streaming
        Error(_) -> False
      }
    }
    RunnerInterface(capabilities) -> {
      case dict.get(capabilities, capability_name) {
        Ok(cap) -> cap.streaming
        Error(_) -> False
      }
    }
  }
}
