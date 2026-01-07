// Extracted reference snippet (v0)
// Source: arquitectura/bridge.md:1697
// Purpose: documentation-only; may not compile as-is.

/// Lanza worker HTTP que envía eventos al actor.
/// Retorna el PID del worker para que el actor lo monitoree.
/// Si streaming=true, usa SSE para recibir eventos incrementales.
pub fn start_interaction(
  ctx: BridgeCtx,
  req: AgentRequest,
  agent: AgentRef,
  /// Timeout efectivo resuelto por el actor (config + capability limits).
  timeout_ms: Int,
  streaming: Bool,
  stream_sink_option: Option(StreamSink),
) -> Pid {
  // Worker BEAM de IO: usar unlinked para que fallos externos no tumben al actor.
  process.spawn_unlinked(fn() {
    if streaming {
      execute_http_streaming(ctx, req, agent, timeout_ms, stream_sink_option)
    } else {
      agent_internal.interaction_done(agent, execute_http_capability(ctx, req, timeout_ms))
    }
  })
}

fn stream_sink_after_started_event(
  stream_sink_option: Option(StreamSink),
  trace_id: TraceId,
  stream_cfg: InteractionStreamConfig,
) -> Option(StreamSink) {
  case stream_sink_option {
    None -> None
    Some(sink) -> {
      case stream_sink.push_batch(sink, [stream_started(trace_id)], stream_cfg.push_timeout_ms) {
        Ok(_) -> Some(sink)
        Error(_) -> None
      }
    }
  }
}

fn push_stream_event(
  stream_sink_option: Option(StreamSink),
  stream_cfg: InteractionStreamConfig,
  event: StreamEvent,
) -> Option(StreamSink) {
  case stream_sink_option {
    None -> None
    Some(sink) -> {
      case stream_sink.push_batch(sink, [event], stream_cfg.push_timeout_ms) {
        Ok(_) -> Some(sink)
        Error(_) -> None
      }
    }
  }
}

fn finish_streaming_without_connection(
  agent: AgentRef,
  stream_sink_option: Option(StreamSink),
  stream_cfg: InteractionStreamConfig,
  err: InteractionError,
) -> Nil {
  case stream_sink_option {
    Some(sink) -> stream_sink.finish(sink, Error(err), stream_cfg.push_timeout_ms) |> ignore
    None -> Nil
  }
  agent_internal.interaction_done(agent, Error(err))
}

fn finalize_streaming_interaction(
  conn: SseConnection,
  agent: AgentRef,
  stream_sink_option: Option(StreamSink),
  stream_cfg: InteractionStreamConfig,
  result: Result(InteractionResult, InteractionError),
) -> Nil {
  http.close_sse(conn)
  case stream_sink_option {
    Some(sink) -> stream_sink.finish(sink, result, stream_cfg.push_timeout_ms) |> ignore
    None -> Nil
  }
  agent_internal.interaction_done(agent, result)
}

/// Ejecuta request HTTP con SSE para streaming.
fn execute_http_streaming(
  ctx: BridgeCtx,
  req: AgentRequest,
  agent: AgentRef,
  timeout_ms: Int,
  stream_sink_option: Option(StreamSink),
) -> Nil {
  let stream_cfg = ctx.config.interaction_stream
  let stream_sink_option = stream_sink_after_started_event(stream_sink_option, req.trace_id, stream_cfg)
  let deadline_ms = now_ms() + timeout_ms

  case setup_sse_connection(ctx, req) {
    Error(err) -> finish_streaming_without_connection(agent, stream_sink_option, stream_cfg, err)
    Ok(conn) -> {
      let stream_ctx = new_stream_context(req.trace_id, ctx.instance_id)
      sse_read_loop(
        conn,
        agent,
        stream_ctx,
        stream_sink_option,
        stream_cfg,
        ctx.artifact_registry,
        deadline_ms,
      )
    }
  }
}

fn setup_sse_connection(ctx: BridgeCtx, req: AgentRequest) -> Result(SseConnection, InteractionError) {
  case ctx.profile.interface {
    RunnerInterface(_) ->
      Error(InteractionError(InfraError, "HTTP streaming on runner interface", req.trace_id))

    HttpInterface(base_url, headers, _, capabilities) -> {
      use capability <- result.try(
        dict.get(capabilities, req.capability)
        |> result.map_error(fn(_) {
          InteractionError(BadRequest, "Unknown capability: " <> req.capability, req.trace_id)
        })
      )

      // v0: streaming HTTP usa SSE en la respuesta, pero el request usa el método/body
      // configurado en la capability (típico: POST JSON → text/event-stream).
      //
      // Mantener reglas simples:
      // - GET no puede llevar body (usar POST si necesitas payload).
      // - Multipart streaming se descarta en v0 (demasiadas piezas: fetch+multipart+SSE).
      case #(capability.method, capability.body) {
        #(Get, Some(_)) ->
          Error(InteractionError(
            BadRequest,
            "Invalid streaming HTTP capability: GET cannot have a body (use POST)",
            req.trace_id,
          ))
        #(_, Some(MultipartBody(_))) ->
          Error(InteractionError(
            BadRequest,
            "Invalid streaming HTTP capability: multipart body not supported for streaming in v0",
            req.trace_id,
          ))
        _ -> {
          let interp_ctx = build_interp_context(ctx, req.inputs, req.context)

          use url <- result.try(
            interpolate_string_strict(base_url <> capability.path, interp_ctx)
            |> result.map_error(fn(e) { InteractionError(InfraError, e, req.trace_id) })
          )

          use resolved_headers <- result.try(
            interpolate_env_map(headers, interp_ctx)
            |> result.map_error(fn(e) { InteractionError(InfraError, e, req.trace_id) })
          )

          // Body JSON opcional
          use body <- result.try(
            case capability.body {
              None -> Ok(None)
              Some(JsonBody(template)) ->
                interpolate_json(template, interp_ctx)
                |> result.map(Some)
              Some(MultipartBody(_)) -> Ok(None)
            }
            |> result.map_error(fn(e) { InteractionError(InfraError, e, req.trace_id) })
          )

          http.open_sse(capability.method, url, resolved_headers, body)
          |> result.map_error(fn(e) { InteractionError(InfraError, e, req.trace_id) })
        }
      }
    }
  }
}

/// Loop de lectura de eventos SSE.
/// Contrato v0 (ver `protocolos.md` §1.8): `data: <json>` donde `<json>` usa `t="log"|"chunk"|"result"`.
fn sse_read_loop(
  conn: SseConnection,
  agent: AgentRef,
  ctx: StreamContext,
  stream_sink_option: Option(StreamSink),
  stream_cfg: InteractionStreamConfig,
  artifact_registry: Subject(ArtifactRegistryMsg),
  deadline_ms: Int,
) -> Nil {
  if now_ms() >= deadline_ms {
    finalize_streaming_interaction(
      conn,
      agent,
      stream_sink_option,
      stream_cfg,
      Error(InteractionError(InfraError, "Interaction timed out", ctx.trace_id)),
    )
  } else {
    case http.sse_receive(conn, 500) {
      SseData(data) -> {
        case decode_runner_event(data) {
          Ok(RunnerEventLog(msg)) -> {
            agent_internal.ingest_log(
              agent,
              log_event(RunnerOut, msg, Some(ctx.trace_id), ctx.instance_id),
            )
            sse_read_loop(conn, agent, ctx, stream_sink_option, stream_cfg, artifact_registry, deadline_ms)
          }

          Ok(RunnerEventChunk(delta)) -> {
            let stream_sink_option =
              push_stream_event(stream_sink_option, stream_cfg, content_chunk(ctx.trace_id, delta))
            sse_read_loop(conn, agent, ctx, stream_sink_option, stream_cfg, artifact_registry, deadline_ms)
          }

          Ok(RunnerEventResult(response)) -> {
            let result = runner_response_to_interaction_result(
              response,
              artifact_registry,
              ctx.instance_id,
              ctx.trace_id,
            )
            finalize_streaming_interaction(conn, agent, stream_sink_option, stream_cfg, result)
          }

          Error(reason) ->
            finalize_streaming_interaction(
              conn,
              agent,
              stream_sink_option,
              stream_cfg,
              Error(InteractionError(InfraError, reason, ctx.trace_id)),
            )
        }
      }

      SseTimeout ->
        sse_read_loop(conn, agent, ctx, stream_sink_option, stream_cfg, artifact_registry, deadline_ms)

      SseClosed ->
        finalize_streaming_interaction(
          conn,
          agent,
          stream_sink_option,
          stream_cfg,
          Error(InteractionError(InfraError, "SSE closed without result", ctx.trace_id)),
        )

      SseError(reason) ->
        finalize_streaming_interaction(
          conn,
          agent,
          stream_sink_option,
          stream_cfg,
          Error(InteractionError(InfraError, reason, ctx.trace_id)),
        )
    }
  }
}

fn execute_http_capability(
  ctx: BridgeCtx,
  req: AgentRequest,
  timeout_ms: Int,
) -> Result(InteractionResult, InteractionError) {
  case ctx.profile.interface {
    RunnerInterface(_) -> Error(InteractionError(
      InfraError,
      "HTTP interaction on runner interface",
      req.trace_id,
    ))
    HttpInterface(base_url, headers, _, capabilities) -> {
      // Buscar capability
      case dict.get(capabilities, req.capability) {
        Error(_) -> Error(InteractionError(
          BadRequest,
          "Unknown capability: " <> req.capability,
          req.trace_id,
        ))
        Ok(cap) -> execute_capability(base_url, headers, cap, req, ctx, timeout_ms)
      }
    }
  }
}

fn execute_capability(
  base_url: String,
  headers: Dict(String, String),
  cap: HttpCapability,
  req: AgentRequest,
  ctx: BridgeCtx,
  timeout_ms: Int,
) -> Result(InteractionResult, InteractionError) {
  // Construir contexto de interpolación con host/port derivados
  // Los params ya vienen resueltos en ctx.params
  let interp_ctx = build_interp_context(ctx, req.inputs, req.context)
  
  // Interpolar URL
  use url <- result.try(
    interpolate_string_strict(base_url <> cap.path, interp_ctx)
    |> result.map_error(fn(e) { InteractionError(InfraError, e, req.trace_id) })
  )
  
  // Interpolar headers
  use resolved_headers <- result.try(
    interpolate_env_map(headers, interp_ctx)
    |> result.map_error(fn(e) { InteractionError(InfraError, e, req.trace_id) })
  )
  
  // Construir body (JSON o multipart) si existe
  let http_result =
    case cap.body {
      None -> request(cap.method, url, resolved_headers, None, timeout_ms)

      Some(JsonBody(template)) -> {
        use body_json <- result.try(
          interpolate_json(template, interp_ctx)
          |> result.map_error(fn(e) { InteractionError(InfraError, e, req.trace_id) })
        )
        request(cap.method, url, resolved_headers, Some(body_json), timeout_ms)
      }

      Some(MultipartBody(spec)) -> {
        // 1) Interpolar fields (strings)
        // 2) Resolver `source_pointer` contra `SAD_INPUT_JSON` para obtener FileRef
        // 3) Descargar el contenido (desde FileRef.url) y enviar multipart/form-data
        request_multipart(cap.method, url, resolved_headers, spec, interp_ctx, timeout_ms)
      }
    }
  
  case http_result {
    Error(err) -> Error(InteractionError(InfraError, http_error_to_string(err), req.trace_id))
    Ok(response) -> parse_http_response(response, cap.response, req.trace_id)
  }
}

fn parse_http_response(
  response: HttpResponse,
  mapping: Option(ResponseMapping),
  trace_id: TraceId,
) -> Result(InteractionResult, InteractionError) {
  case response.status >= 200 && response.status < 300 {
    False -> Error(InteractionError(
      AgentError,
      "HTTP " <> int.to_string(response.status),
      trace_id,
    ))
    True -> {
      let data = case mapping {
        None -> ResponseData(content: Some(response.body), metadata: dict.new())
        Some(m) -> extract_with_mapping(response.body, m)
      }
      Ok(InteractionResult(
        data: data,
        artifacts: [],
        trace_id: trace_id,
      ))
    }
  }
}

/// Aborta interacción HTTP terminando el *worker BEAM*.
pub fn cancel_interaction(handle: InteractionHandle) -> Nil {
  let pid = interaction_handle_pid(handle)
  process.kill(pid)
}
