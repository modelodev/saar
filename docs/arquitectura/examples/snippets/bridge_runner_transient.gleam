// Extracted reference snippet (v0)
// Source: arquitectura/bridge.md:899
// Purpose: documentation-only; may not compile as-is.

// En saar/bridge/runner.gleam
import saar/bridge/bridge.{type BridgeCtx}
import saar/streams/sink as stream_sink
import saar/streams/sink.{type StreamSink}

/// Lanza worker que ejecuta el runner y envía mensajes al actor.
/// Retorna el PID del worker para que el actor lo monitoree.
/// Si streaming=true, emite eventos genéricos incrementales.
pub fn start_interaction(
  ctx: BridgeCtx,
  req: AgentRequest,
  agent: AgentRef,
  timeout_ms: Int,
  streaming: Bool,
  stream_sink_option: Option(StreamSink),
) -> Pid {
  // Worker BEAM de IO: usar unlinked para que fallos externos no tumben al actor.
  process.spawn_unlinked(fn() {
    run_interaction_worker(
      ctx,
      req,
      agent,
      timeout_ms,
      streaming,
      stream_sink_option,
    )
  })
}

/// Timeout efectivo resuelto por el actor (config + capability limits).
/// Fail-fast (v0) — contrato JSONL del runner:
/// - JSON válido bajo límites (`max_stdout_bytes`, límite por línea/evento)
/// - `t` conocido (`log`/`chunk`/`result`/`provision_result`)
/// - forma mínima por evento
/// Ante violación: terminar inmediatamente el port/wrapper y devolver `ContractViolation` (no intentar “recuperar”).
/// Worker interno que:
/// 1. Abre port, envía JSON
/// 2. Lee STDOUT (único canal capturado) como stream de eventos JSONL:
///    - `t="log"` -> `agent.internal_ingest_log` con metadata (ts_ms, trace_id, instance_id)
///    - `t="chunk"` (si streaming=true) -> `ContentChunk`
///    - `t="result"` -> resultado final (`RunnerResponse`)
/// 4. En streaming, envía batches al `saar/streams/sink.StreamSink` (gateway); siempre notifica `interaction_done` al actor
fn run_interaction_worker(
  ctx: BridgeCtx,
  req: AgentRequest,
  agent: AgentRef,
  timeout_ms: Int,
  streaming: Bool,
  stream_sink_option: Option(StreamSink),
) -> Nil {
  // Los params ya están resueltos en ctx.params.
  let input = build_input_from_request(ctx, req)
  let control_line =
    json.object([
      #("t", json.string("input")),
      #("payload", saar_input_to_json(input)),
    ])
    |> json.to_string

  // Abrir port
  let port = open_runner_port(ctx.profile.runner, ctx.workspace)

  // Enviar JSONL de control por stdin (no cerrar; permite stop posterior)
  port.send(port, control_line <> "\n")

  // El streaming de interacción se entrega solo vía StreamSink (no pasa por el actor).
  // Si no hay StreamSink (modo non-streaming), el worker solo emitirá InteractionDone al actor.
  let stream_cfg = ctx.config.interaction_stream
  let sink = case streaming {
    True -> stream_sink_option
    False -> None
  }
  let artifact_registry = ctx.artifact_registry

  // Batching: empezar el stream con StreamStarted y dejar que el loop lo flushee.
  let pending_events = case sink {
    Some(_) -> [stream_started(req.trace_id)]
    None -> []
  }
  let pending_bytes = 0

  // Loop de lectura con contexto de streaming (tipos genéricos)
  // Usamos List(String) para acumular chunks y evitar O(n²) de concatenación
  let stream_ctx = new_stream_context(req.trace_id, ctx.instance_id)
  let max_size = ctx.config.max_stdout_bytes
  // Timeout hard (deadline absoluta). El timeout efectivo lo resuelve el actor
  // (config default + capability limits) y se pasa al bridge como `timeout_ms`.
  let deadline_ms = now_ms() + timeout_ms
  interaction_read_loop(
    port,
    agent,
    stream_ctx,
    sink,
    stream_cfg,
    pending_events,
    pending_bytes,
    None,
    0,
    max_size,
    deadline_ms,
  )
}

fn flush_pending(
  sink: Option(StreamSink),
  cfg: InteractionStreamConfig,
  pending_events: List(StreamEvent),
  pending_bytes: Int,
) -> #(Option(StreamSink), List(StreamEvent), Int) {
  case sink {
    None -> #(None, [], 0)
    Some(s) -> {
      case pending_events {
        [] -> #(Some(s), [], 0)
        _ -> {
          case
            stream_sink.push_batch(
              s,
              list.reverse(pending_events),
              cfg.push_timeout_ms,
            )
          {
            Ok(_) -> #(Some(s), [], 0)
            Error(_) -> #(None, [], 0)
            // disconnect/timeout => discard
          }
        }
      }
    }
  }
}

fn finalize_interaction(
  agent: AgentRef,
  sink: Option(StreamSink),
  stream_cfg: InteractionStreamConfig,
  result: Result(InteractionResult, InteractionError),
) -> Nil {
  case sink {
    Some(sink) ->
      stream_sink.finish(sink, result, stream_cfg.push_timeout_ms) |> ignore
    None -> Nil
  }
  agent.internal_interaction_done(agent, result)
}

fn abort_interaction_with_error(
  port: Port,
  agent: AgentRef,
  sink: Option(StreamSink),
  stream_cfg: InteractionStreamConfig,
  err: InteractionError,
) -> Nil {
  port.close(port)
  finalize_interaction(agent, sink, stream_cfg, Error(err))
}

/// Nota idiomática (Gleam/BEAM): en implementación, este loop debe usar `process.Selector`
/// dentro del worker para multiplexar:
/// - eventos del port (stdout/exit),
/// - timeouts (call_timeout_ms / watchdog),
/// - y (si aplica) señales de stop internas del worker.
///
/// Esto mantiene el IO dentro del worker (bridge) y evita races/duplicación de `receive`.
type WorkerEvt {
  FromPort(PortEvent)
  FlushTick
  TimedOut
}

fn interaction_read_loop(
  port: Port,
  agent: AgentRef,
  ctx: StreamContext,
  sink: Option(StreamSink),
  stream_cfg: InteractionStreamConfig,
  pending_events: List(StreamEvent),
  pending_bytes: Int,
  result: Option(RunnerResponse),
  out_size: Int,
  max_size: Int,
  deadline_ms: Int,
) -> Nil {
  let selector =
    process.new_selector()
    // PortEvent: data/exit (source: port). SAAR no depende de stderr (fuera de contrato).
    |> port.select(port, fn(ev) { FromPort(ev) })

  // `selector_receive` devuelve `Error(Nil)` en timeout; lo usamos para:
  // - flush periódico (intervalo) y
  // - deadline absoluto (timeout hard).
  let remaining_ms = int.max(0, deadline_ms - now_ms())
  let within_ms = int.min(stream_cfg.flush_interval_ms, remaining_ms)
  let evt = case process.selector_receive(selector, within_ms) {
    Ok(ev) -> ev
    Error(Nil) ->
      case now_ms() >= deadline_ms {
        True -> TimedOut
        False -> FlushTick
      }
  }

  case evt {
    FlushTick -> {
      let #(sink, pending_events, pending_bytes) =
        flush_pending(sink, stream_cfg, pending_events, pending_bytes)
      interaction_read_loop(
        port,
        agent,
        ctx,
        sink,
        stream_cfg,
        pending_events,
        pending_bytes,
        result,
        out_size,
        max_size,
        deadline_ms,
      )
    }

    TimedOut -> {
      // Timeout: cerrar port (EOF al wrapper) y reportar InfraError.
      abort_interaction_with_error(
        port,
        agent,
        sink,
        stream_cfg,
        InteractionError(InfraError, "Interaction timed out", ctx.trace_id),
      )
    }

    FromPort(PortStdout(line)) -> {
      // Contrato runner (v0): STDOUT es JSONL (1 evento JSON por línea).
      // Eventos esperados:
      // - {"t":"log","message":"...","level":"info"} (opcional)
      // - {"t":"chunk","delta":"..."} (opcional; solo si streaming=true)
      // - {"t":"result", ...RunnerResponse...} (obligatorio; exactamente uno)
      let new_size = out_size + string.byte_size(line)
      case new_size > max_size {
        True -> {
          abort_interaction_with_error(
            port,
            agent,
            sink,
            stream_cfg,
            InteractionError(
              InfraError,
              "Runner output exceeded "
                <> int.to_string(max_size)
                <> " bytes limit",
              ctx.trace_id,
            ),
          )
        }
        False -> {
          // Nota: port_process solo entrega líneas completas. Si un evento excede el límite
          // de tamaño por línea (ver `protocolos_runner.md`) o llega fragmentado por el port,
          // se trata como error de contrato (InfraError) y se aborta la interacción.
          // El decoder distingue por `t`.
          case decode_runner_event(line) {
            Ok(RunnerEventLog(msg)) -> {
              let event =
                log_event(RunnerOut, msg, Some(ctx.trace_id), ctx.instance_id)
              agent.internal_ingest_log(agent, event)
              interaction_read_loop(
                port,
                agent,
                ctx,
                sink,
                stream_cfg,
                pending_events,
                pending_bytes,
                result,
                new_size,
                max_size,
                deadline_ms,
              )
            }
            Ok(RunnerEventChunk(delta)) -> {
              // En streaming, acumular en pending y flushear por tamaño/intervalo.
              let event = content_chunk(ctx.trace_id, delta)
              // `batch_byte_size` cuenta bytes del payload lógico (delta UTF-8), no el framing SSE completo.
              let delta_bytes = string.byte_size(delta)
              let pending_events = case sink {
                Some(_) -> [event, ..pending_events]
                None -> pending_events
              }
              let pending_bytes = case sink {
                Some(_) -> pending_bytes + delta_bytes
                None -> pending_bytes
              }

              // Flush por tamaño.
              let #(sink, pending_events, pending_bytes) = case sink {
                Some(_) if pending_bytes >= stream_cfg.batch_byte_size ->
                  flush_pending(sink, stream_cfg, pending_events, pending_bytes)
                _ -> #(sink, pending_events, pending_bytes)
              }

              interaction_read_loop(
                port,
                agent,
                ctx,
                sink,
                stream_cfg,
                pending_events,
                pending_bytes,
                result,
                new_size,
                max_size,
                deadline_ms,
              )
            }
            Ok(RunnerEventResult(response)) -> {
              // Guardar el resultado final. Si el runner emite más de un result, se trata como error.
              case result {
                Some(_) -> {
                  abort_interaction_with_error(
                    port,
                    agent,
                    sink,
                    stream_cfg,
                    InteractionError(
                      InfraError,
                      "Runner emitted multiple result events",
                      ctx.trace_id,
                    ),
                  )
                }
                None ->
                  interaction_read_loop(
                    port,
                    agent,
                    ctx,
                    sink,
                    stream_cfg,
                    pending_events,
                    pending_bytes,
                    Some(response),
                    new_size,
                    max_size,
                    deadline_ms,
                  )
              }
            }
            Error(_) -> {
              // Fail-fast: bytes fuera de contrato.
              abort_interaction_with_error(
                port,
                agent,
                sink,
                stream_cfg,
                InteractionError(
                  InfraError,
                  "Invalid runner event (non-JSONL)",
                  ctx.trace_id,
                ),
              )
            }
          }
        }
      }
    }

    FromPort(PortExit(0)) -> {
      // Flush best-effort antes del cierre.
      let #(sink, _pending_events, _pending_bytes) =
        flush_pending(sink, stream_cfg, pending_events, pending_bytes)

      // El resultado final llega como evento `t="result"`.
      let result = case result {
        Some(response) ->
          runner_response_to_interaction_result(
            response,
            artifact_registry,
            ctx.instance_id,
            ctx.trace_id,
          )
        None ->
          Error(InteractionError(
            InfraError,
            "Runner exited without result event",
            ctx.trace_id,
          ))
      }

      finalize_interaction(agent, sink, stream_cfg, result)
    }

    FromPort(PortExit(code)) -> {
      finalize_interaction(
        agent,
        sink,
        stream_cfg,
        Error(InteractionError(
          InfraError,
          "Exit code " <> int.to_string(code),
          ctx.trace_id,
        )),
      )
    }
  }
}

/// Parsea la respuesta del runner y la convierte a InteractionResult.
fn runner_response_to_interaction_result(
  response: RunnerResponse,
  artifact_registry: Subject(ArtifactRegistryMsg),
  instance_id: InstanceId,
  trace_id: TraceId,
) -> Result(InteractionResult, InteractionError) {
  case response.status {
    StatusError -> {
      let err =
        response.error
        |> option.unwrap(RunnerError(AgentError, "Unknown error"))
      Error(InteractionError(err.kind, err.message, trace_id))
    }
    StatusSuccess -> {
      let artifacts =
        register_artifacts(response.artifacts, artifact_registry, instance_id)
      Ok(InteractionResult(
        data: response_data_from_runner(response.data),
        artifacts: artifacts,
        trace_id: trace_id,
      ))
    }
  }
}

/// Registra artefactos en ArtifactRegistry y devuelve sus URLs públicas.
/// - `ArtifactRef.path` ya viene como `WorkspacePath` validado desde el decoder del RunnerResponse.
/// - El `ArtifactRegistry` asigna el `ArtifactId` (UUID) y mantiene el mapping en memoria.
fn register_artifacts(
  refs: List(ArtifactRef),
  registry: Subject(ArtifactRegistryMsg),
  instance_id: InstanceId,
) -> List(PublicArtifact) {
  refs
  |> list.map(fn(ref) {
    let artifact_id =
      artifact_registry_api.register_artifact(
        registry,
        ref.path,
        ref.mime,
        instance_id,
      )
    PublicArtifact(
      name: ref.name,
      url: "/artifacts/" <> artifact_id_to_string(artifact_id),
      mime: ref.mime,
    )
  })
}

/// Aborta una interacción en curso terminando el *worker BEAM*.
/// Esto NO envía señales al OS: al morir el owner del port, el wrapper recibe EOF y aplica SIGTERM→SIGKILL al runner.
/// El actor recibirá `WorkerDown` y limpiará el estado (no implica cancelación por desconexión de cliente SSE).
pub fn cancel_interaction(handle: InteractionHandle) -> Nil {
  let pid = interaction_handle_pid(handle)
  process.kill(pid)
}
