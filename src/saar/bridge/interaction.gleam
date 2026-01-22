////
//// Mission: execute a single interaction using a profile snapshot.
////
//// Responsibilities:
//// - Execute a capability defined in a profile interface snapshot.
//// - When streaming, push SSE payloads via a request-scoped `StreamSink`.
//// - Return a final `InteractionResult` or `InteractionError`.
////
//// Non-responsibilities:
//// - Spawning/monitoring interaction workers (AgentActor responsibility).
//// - Enforcing hard timeouts (AgentActor responsibility).
//// - HTTP gateway routing/authentication.
////
//// Relationships:
//// - Called by `saar/core/agent` from a worker process.
//// - Uses `saar/streams/stream_pump` + `saar/streams/sink` for SSE delivery.

import envoy
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import saar/adapters/a2a
import saar/adapters/a2ui
import saar/adapters/agui
import saar/artifacts
import saar/bridge/artifact_registration
import saar/bridge/http_client
import saar/bridge/interpolator
import saar/bridge/port_process
import saar/bridge/runner
import saar/bridge/runner_contract
import saar/bridge/serialization
import saar/bridge/wrapper_env
import saar/core/artifact_registry_protocol
import saar/ffi
import saar/ingest_metadata
import saar/json_pointer
import saar/response_mapping
import saar/streams/sink
import saar/streams/stream_pump
import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/enums as types_enums
import saar/types/input as types_input
import saar/types/output as types_output
import saar/types/profile as types_profile
import saar/types/resolved_params
import saar/types/runner as types_runner
import saar/types/stream as types_stream

/// Executes a single interaction.
///
/// This function is pure with respect to agent state: concurrency guards and
/// hard timeouts are enforced by the caller (AgentActor).
///
/// `stream_mode` selects whether the bridge pushes SSE chunks or returns a
/// single response.
pub fn run(
  profile: types_profile.Profile,
  profile_id: types_core.ProfileId,
  instance_id: types_core.InstanceId,
  capability_name: String,
  inputs: types_input.InputPayload,
  context: types_input.RequestContext,
  params: resolved_params.ResolvedParams,
  workspace: String,
  config: types_config.SaarConfig,
  artifact_registry: process.Subject(
    artifact_registry_protocol.ArtifactRegistryMsg,
  ),
  assigned_port: Option(Int),
  stream_mode: sink.StreamMode,
) -> Result(types_output.InteractionResult, types_output.InteractionError) {
  let meta = case profile.meta.lifecycle {
    types_enums.Transient ->
      types_input.TransientMeta("v0", profile_id, instance_id)

    types_enums.Continuous ->
      types_input.ContinuousMeta("v0", profile_id, instance_id)
  }

  let input =
    types_input.SaarInput(
      meta: meta,
      params: params,
      input: inputs,
      context: context,
      helpers: None,
      runner_def: profile.runner,
    )

  case profile.interface {
    types_profile.RunnerInterface(caps) ->
      case dict.get(caps, capability_name) {
        Error(_) ->
          Error(types_output.saar_error(
            context.trace_id,
            types_enums.BadRequest,
            "Unknown capability",
          ))

        Ok(cap) ->
          case stream_mode, cap.streaming {
            sink.Streaming(stream_sink), True ->
              execute_runner_streaming(
                input,
                instance_id,
                workspace,
                config,
                artifact_registry,
                stream_sink,
              )
            _, _ ->
              execute_runner_sync(input, workspace, config, artifact_registry)
          }
      }

    types_profile.HttpInterface(base_url, headers, _health, caps) ->
      case dict.get(caps, capability_name) {
        Error(_) ->
          Error(types_output.saar_error(
            context.trace_id,
            types_enums.BadRequest,
            "Unknown capability",
          ))

        Ok(cap) ->
          case stream_mode, cap.streaming {
            sink.Streaming(_), True ->
              Error(types_output.saar_error(
                context.trace_id,
                types_enums.InfraError,
                "http_streaming_not_supported",
              ))

            _, _ ->
              execute_http_sync(
                base_url,
                headers,
                cap,
                input,
                config,
                assigned_port,
              )
          }
      }
  }
}

fn execute_runner_sync(
  input: types_input.SaarInput,
  workspace: String,
  config: types_config.SaarConfig,
  artifact_registry: process.Subject(
    artifact_registry_protocol.ArtifactRegistryMsg,
  ),
) -> Result(types_output.InteractionResult, types_output.InteractionError) {
  let #(runner_path, runner_args) = runner_command(input.runner_def, config)

  let ctx =
    interpolator.build_context(
      input.params,
      input.input,
      input.context,
      None,
      None,
    )

  use env_map <- result.try(interpolator.interpolate_dict(
    input.runner_def.env_map,
    ctx,
  ))
  use args <- result.try(interpolator.interpolate_list(
    input.runner_def.args,
    ctx,
  ))

  let env = list.append(runner_env(), dict.to_list(env_map))
  let env = list.append(env, [#("SAAR_WORKSPACE", workspace)])

  runner.execute_transient(
    runner_path,
    list.append(runner_args, args),
    env,
    workspace,
    input,
    config,
    artifact_registry,
    False,
    0,
  )
}

type StreamFlags {
  AguiFlags(agui.AgUiState)
  A2uiFlags(started: Bool)
  A2aFlags(a2a.A2aStreamState)
}

fn init_a2a_flags(
  pump: stream_pump.StreamPump,
  input: types_input.SaarInput,
  extensions: a2a.Extensions,
) -> StreamFlags {
  let context_id = case dict.get(input.context.extra, "context_id") {
    Ok(value) -> value
    Error(_) -> types_core.trace_id_to_string(input.context.trace_id)
  }

  let state0 = a2a.new_stream(input.context.trace_id, context_id, extensions)

  let #(state, events) =
    a2a.convert_stream(
      state0,
      a2a.StreamStarted(task_id: input.context.trace_id, context_id: context_id),
    )

  let events = case ingest_event_from_context(input.context.extra) {
    Some(event) -> list.append(events, [event])
    None -> events
  }

  events |> list.each(fn(ev) { stream_pump.push(pump, ev) })

  A2aFlags(state)
}

fn ingest_event_from_context(
  extra: dict.Dict(String, String),
) -> Option(types_stream.StreamEvent) {
  case ingest_metadata.ingest_payload_from_context(extra) {
    Some(payload) -> Some(a2a.ingest_data_event(payload))
    None -> None
  }
}

fn execute_runner_streaming(
  input: types_input.SaarInput,
  instance_id: types_core.InstanceId,
  workspace: String,
  config: types_config.SaarConfig,
  artifact_registry: process.Subject(
    artifact_registry_protocol.ArtifactRegistryMsg,
  ),
  stream_sink: sink.StreamSink,
) -> Result(types_output.InteractionResult, types_output.InteractionError) {
  let types_config.SaarConfig(stream: stream_cfg, ..) = config
  let types_config.StreamConfig(
    interaction_stream: pump_cfg,
    sse_keep_alive_interval_ms: _keep_alive_ms,
    ..,
  ) = stream_cfg

  let done = process.new_subject()
  let pump = stream_pump.start(done, Some(stream_sink), pump_cfg)

  // Emit protocol start eagerly and initialize protocol state.
  let flags = case sink.protocol(stream_sink) {
    sink.AgUi -> {
      let #(agui_state, events) =
        agui.convert(agui.new(), agui.StreamStarted(input.context.trace_id))

      events |> list.each(fn(ev) { stream_pump.push(pump, ev) })

      AguiFlags(agui_state)
    }

    sink.A2uiV08 -> A2uiFlags(started: False)

    sink.A2a -> init_a2a_flags(pump, input, a2a.NoExtensions)

    sink.A2aA2uiV08 -> init_a2a_flags(pump, input, a2a.A2uiV08)
  }

  let #(runner_path, runner_args) = runner_command(input.runner_def, config)

  let ctx =
    interpolator.build_context(
      input.params,
      input.input,
      input.context,
      None,
      None,
    )

  use env_map <- result.try(interpolator.interpolate_dict(
    input.runner_def.env_map,
    ctx,
  ))
  use args <- result.try(interpolator.interpolate_list(
    input.runner_def.args,
    ctx,
  ))

  let env = list.append(runner_env(), dict.to_list(env_map))
  let env = list.append(env, [#("SAAR_WORKSPACE", workspace)])

  let types_config.RunnerExecSettings(
    shutdown_timeout_ms: shutdown_timeout_ms,
    wrapper: wrapper,
    ..,
  ) = types_config.runner_exec_settings(config)

  let env =
    wrapper_env.append(
      env,
      wrapper,
      shutdown_timeout_ms,
      config.landlock_mode,
      config.landlock_policy,
      workspace,
    )

  let types_config.RunnerExecSettings(
    max_runner_event_bytes: max_event_bytes,
    read_timeout_ms: read_timeout_ms,
    ..,
  ) = types_config.runner_exec_settings(config)

  use proc <- result.try(
    port_process.start(
      runner_path,
      list.append(runner_args, args),
      env,
      workspace,
      max_event_bytes,
    )
    |> result.map_error(fn(err) {
      types_output.saar_error(
        input.context.trace_id,
        types_enums.InfraError,
        port_error_to_string(err),
      )
    }),
  )

  let control_line =
    json.object([
      #("t", json.string("input")),
      #("payload", serialization.saar_input_to_json(input)),
    ])
    |> json.to_string

  port_process.send(proc, control_line <> "\n")

  read_runner_stream(
    proc,
    read_timeout_ms,
    input,
    pump,
    flags,
    config,
    artifact_registry,
    instance_id,
  )
}

fn read_runner_stream(
  proc: port_process.PortProcess,
  read_timeout_ms: Int,
  input: types_input.SaarInput,
  pump: stream_pump.StreamPump,
  flags: StreamFlags,
  config: types_config.SaarConfig,
  artifact_registry: process.Subject(
    artifact_registry_protocol.ArtifactRegistryMsg,
  ),
  instance_id: types_core.InstanceId,
) -> Result(types_output.InteractionResult, types_output.InteractionError) {
  let #(proc, out) = port_process.read_line(proc, read_timeout_ms)

  case out {
    Error(port_process.Timeout) ->
      read_runner_stream(
        proc,
        read_timeout_ms,
        input,
        pump,
        flags,
        config,
        artifact_registry,
        instance_id,
      )

    Error(port_process.NoeolFragment(fragment)) ->
      Error(types_output.saar_error(
        input.context.trace_id,
        types_enums.InfraError,
        "Fragmented output: " <> fragment,
      ))

    Error(port_process.OversizedEvent(_size, _max)) ->
      Error(types_output.saar_error(
        input.context.trace_id,
        types_enums.InfraError,
        "Runner event too large",
      ))

    Error(port_process.PortExited(code)) ->
      case code == port_process.landlock_unavailable_exit_code {
        True ->
          Error(types_output.saar_error(
            input.context.trace_id,
            types_enums.InfraError,
            "LANDLOCK_UNAVAILABLE",
          ))

        False ->
          Error(types_output.saar_error(
            input.context.trace_id,
            types_enums.InfraError,
            "Runner exited with code " <> int.to_string(code),
          ))
      }

    Ok(line) ->
      runner_contract.decode_event(line)
      |> result.map_error(fn(err) {
        types_output.saar_error(
          input.context.trace_id,
          types_enums.InfraError,
          "Invalid runner event: " <> string.inspect(err),
        )
      })
      |> result.try(fn(event) {
        case event {
          types_runner.RunnerEventLog(_, _) ->
            read_runner_stream(
              proc,
              read_timeout_ms,
              input,
              pump,
              flags,
              config,
              artifact_registry,
              instance_id,
            )

          types_runner.RunnerEventChunk(delta) -> {
            let flags = emit_chunk(pump, input.context.trace_id, delta, flags)
            read_runner_stream(
              proc,
              read_timeout_ms,
              input,
              pump,
              flags,
              config,
              artifact_registry,
              instance_id,
            )
          }

          types_runner.RunnerEventResult(response) -> {
            let final =
              runner_response_to_result(
                response,
                input.runner_def.artifact_config,
                input.context.trace_id,
                config,
                artifact_registry,
                instance_id,
              )

            emit_terminal(pump, input.context.trace_id, final, flags)
            stream_pump.finish(pump, final)
            final
          }

          _ ->
            Error(types_output.saar_error(
              input.context.trace_id,
              types_enums.InfraError,
              "Unexpected runner event",
            ))
        }
      })
  }
}

fn emit_chunk(
  pump: stream_pump.StreamPump,
  trace_id: types_core.TraceId,
  delta: String,
  flags: StreamFlags,
) -> StreamFlags {
  case flags {
    AguiFlags(agui_state) -> {
      let #(agui_state, events) =
        agui.convert(agui_state, agui.ContentChunk(delta))
      events |> list.each(fn(ev) { stream_pump.push(pump, ev) })
      AguiFlags(agui_state)
    }

    A2uiFlags(started) -> {
      case started {
        False -> stream_pump.push(pump, a2ui.begin_rendering(trace_id))
        True -> Nil
      }

      stream_pump.push(pump, a2ui.data_model_update(trace_id, delta))
      A2uiFlags(started: True)
    }

    A2aFlags(state) -> {
      let #(next, events) = a2a.convert_stream(state, a2a.ContentChunk(delta))
      events |> list.each(fn(ev) { stream_pump.push(pump, ev) })
      A2aFlags(next)
    }
  }
}

fn emit_terminal(
  pump: stream_pump.StreamPump,
  trace_id: types_core.TraceId,
  result: Result(types_output.InteractionResult, types_output.InteractionError),
  flags: StreamFlags,
) -> Nil {
  case flags {
    A2uiFlags(_) -> Nil

    AguiFlags(agui_state) ->
      case result {
        Ok(ok) -> {
          let #(_next_state, events) =
            agui.convert(
              agui_state,
              agui.StreamFinished(trace_id, ok.artifacts),
            )
          events |> list.each(fn(ev) { stream_pump.push(pump, ev) })
          Nil
        }

        Error(err) -> {
          let #(_next_state, events) =
            agui.convert(agui_state, agui.StreamError(err))
          events |> list.each(fn(ev) { stream_pump.push(pump, ev) })
          Nil
        }
      }

    A2aFlags(state) ->
      case result {
        Ok(ok) -> {
          let #(_next, events) =
            a2a.convert_stream(state, a2a.StreamFinished(ok.artifacts))
          events |> list.each(fn(ev) { stream_pump.push(pump, ev) })
          Nil
        }

        Error(err) -> {
          let #(_next, events) = a2a.convert_stream(state, a2a.StreamError(err))
          events |> list.each(fn(ev) { stream_pump.push(pump, ev) })
          Nil
        }
      }
  }
}

fn runner_response_to_result(
  response: types_runner.RunnerResponse,
  artifact_cfg: types_runner.ArtifactConfig,
  trace_id: types_core.TraceId,
  config: types_config.SaarConfig,
  artifact_registry: process.Subject(
    artifact_registry_protocol.ArtifactRegistryMsg,
  ),
  instance_id: types_core.InstanceId,
) -> Result(types_output.InteractionResult, types_output.InteractionError) {
  case response {
    types_runner.RunnerFailure(error: err, ..) ->
      Error(types_output.saar_error(trace_id, err.kind, err.message))

    types_runner.RunnerSuccess(data: data, artifacts: runner_artifacts) -> {
      let response_data = case data {
        None -> types_output.ResponseData(content: None, metadata: dict.new())
        Some(payload) ->
          types_output.ResponseData(
            content: None,
            metadata: dict.from_list([#("raw", payload)]),
          )
      }

      let collected =
        artifacts.collect(runner_artifacts, artifact_cfg)
        |> result.map_error(fn(err) {
          types_output.saar_error(
            trace_id,
            types_enums.InfraError,
            "Invalid artifact path: " <> string.inspect(err),
          )
        })

      use collected_artifacts <- result.try(collected)

      use public_artifacts <- result.try(
        artifact_registration.register_collected_artifacts(
          config,
          artifact_registry,
          instance_id,
          collected_artifacts,
          trace_id,
        ),
      )

      Ok(types_output.InteractionResult(
        data: response_data,
        artifacts: public_artifacts,
        trace_id: trace_id,
      ))
    }
  }
}

fn execute_http_sync(
  base_url: String,
  headers: dict.Dict(String, String),
  capability: types_profile.HttpCapability,
  input: types_input.SaarInput,
  config: types_config.SaarConfig,
  assigned_port: Option(Int),
) -> Result(types_output.InteractionResult, types_output.InteractionError) {
  let ctx =
    interpolator.build_context(
      input.params,
      input.input,
      input.context,
      Some(managed_port_host(config)),
      assigned_port,
    )

  use base <- result.try(interpolator.interpolate_string(base_url, ctx))
  use hdrs <- result.try(interpolator.interpolate_dict(headers, ctx))

  let url = base <> capability.path

  let method = http_method(capability.method)

  let types_config.SaarConfig(limits: limits, timeouts: timeouts, ..) = config
  let types_config.SaarLimits(max_http_response_bytes: max_resp, ..) = limits
  let types_config.SaarTimeouts(call_timeout_ms: timeout_ms, ..) = timeouts

  let response = case capability.body {
    None -> {
      let body = json.to_string(input_payload_to_json(input.input))
      http_client.request_sync_string(
        method,
        url,
        hdrs,
        Some(body),
        timeout_ms,
        max_resp,
      )
      |> result.map_error(fn(err) {
        types_output.saar_error(
          input.context.trace_id,
          types_enums.InfraError,
          http_client.http_error_to_string(err),
        )
      })
    }

    Some(types_profile.JsonBody(template)) -> {
      use rendered <- result.try(interpolator.interpolate_json(template, ctx))
      let body = json.to_string(rendered)
      http_client.request_sync_string(
        method,
        url,
        hdrs,
        Some(body),
        timeout_ms,
        max_resp,
      )
      |> result.map_error(fn(err) {
        types_output.saar_error(
          input.context.trace_id,
          types_enums.InfraError,
          http_client.http_error_to_string(err),
        )
      })
    }

    Some(types_profile.MultipartBody(fields, files)) -> {
      use interpolated_fields <- result.try(interpolator.interpolate_dict(
        fields,
        ctx,
      ))
      use file_parts <- result.try(resolve_multipart_files(
        files,
        input.input,
        input.context.trace_id,
      ))
      case file_parts {
        [] ->
          Error(types_output.saar_error(
            input.context.trace_id,
            types_enums.BadRequest,
            "Multipart body requires files",
          ))

        [#(field, file)] ->
          http_client.request_multipart_file(
            input.context.trace_id,
            method,
            url,
            hdrs,
            interpolated_fields,
            field,
            file,
            capability.streaming,
            config,
            timeout_ms,
          )

        _ -> {
          use responses <- result.try(
            file_parts
            |> list.try_map(fn(pair) {
              let #(field, file) = pair
              http_client.request_multipart_file(
                input.context.trace_id,
                method,
                url,
                hdrs,
                interpolated_fields,
                field,
                file,
                capability.streaming,
                config,
                timeout_ms,
              )
            }),
          )
          first_response(responses, input.context.trace_id)
        }
      }
    }
  }

  response
  |> result.try(fn(resp) {
    use response_data <- result.try(build_http_response_data(
      capability.response,
      resp,
      input.context.trace_id,
    ))
    Ok(types_output.InteractionResult(
      data: response_data,
      artifacts: [],
      trace_id: input.context.trace_id,
    ))
  })
}

fn resolve_multipart_files(
  files: List(types_profile.MultipartFilePart),
  payload: types_input.InputPayload,
  trace_id: types_core.TraceId,
) -> Result(List(#(String, types_input.FileRef)), types_output.InteractionError) {
  files
  |> list.try_map(fn(part) {
    let types_profile.MultipartFilePart(
      field: field,
      source_pointer: source_pointer,
    ) = part
    resolve_file_pointer(source_pointer, payload, trace_id)
    |> result.map(fn(file) { #(field, file) })
  })
}

fn resolve_file_pointer(
  pointer: String,
  payload: types_input.InputPayload,
  trace_id: types_core.TraceId,
) -> Result(types_input.FileRef, types_output.InteractionError) {
  use parsed <- result.try(
    json_pointer.parse(pointer)
    |> result.map_error(fn(_) {
      types_output.saar_error(
        trace_id,
        types_enums.BadRequest,
        "Invalid file pointer '" <> pointer <> "'",
      )
    }),
  )

  case json_pointer.segments(parsed) {
    ["input", "files", index_str] ->
      case int.parse(index_str) {
        Ok(index) if index >= 0 ->
          file_at(payload_files(payload), index, trace_id, pointer)
        _ ->
          Error(types_output.saar_error(
            trace_id,
            types_enums.BadRequest,
            "Invalid file pointer '" <> pointer <> "'",
          ))
      }

    _ ->
      Error(types_output.saar_error(
        trace_id,
        types_enums.BadRequest,
        "Invalid file pointer '" <> pointer <> "'",
      ))
  }
}

fn payload_files(payload: types_input.InputPayload) -> List(types_input.FileRef) {
  case payload {
    types_input.PayloadChat(_, _) -> []
    types_input.PayloadFiles(files) -> files
    types_input.PayloadMixed(_, files, _) -> files
  }
}

fn file_at(
  files: List(types_input.FileRef),
  index: Int,
  trace_id: types_core.TraceId,
  pointer: String,
) -> Result(types_input.FileRef, types_output.InteractionError) {
  files
  |> list.drop(index)
  |> list.first
  |> result.map_error(fn(_) {
    types_output.saar_error(
      trace_id,
      types_enums.BadRequest,
      "Missing file for pointer '" <> pointer <> "'",
    )
  })
}

fn first_response(
  responses: List(http_client.HttpResponse),
  trace_id: types_core.TraceId,
) -> Result(http_client.HttpResponse, types_output.InteractionError) {
  responses
  |> list.first
  |> result.map_error(fn(_) {
    types_output.saar_error(
      trace_id,
      types_enums.InfraError,
      "Missing multipart response",
    )
  })
}

fn build_http_response_data(
  response: Option(types_profile.ResponseConfig),
  resp: http_client.HttpResponse,
  trace_id: types_core.TraceId,
) -> Result(types_output.ResponseData, types_output.InteractionError) {
  case response {
    None ->
      Ok(types_output.ResponseData(
        content: Some(resp.body),
        metadata: dict.new(),
      ))

    Some(response_config) -> {
      use body <- result.try(
        json.parse(resp.body, decode.dynamic)
        |> result.map_error(fn(_) {
          types_output.saar_error(
            trace_id,
            types_enums.AgentError,
            "Invalid HTTP response JSON",
          )
        }),
      )
      use mapped <- result.try(response_mapping.apply_response_mapping(
        trace_id,
        Some(response_config),
        body,
      ))
      Ok(types_output.ResponseData(
        content: mapped.text,
        metadata: mapped.metadata,
      ))
    }
  }
}

fn http_method(method: types_profile.HttpMethod) -> http.Method {
  case method {
    types_profile.HttpGet -> http.Get
    types_profile.HttpPost -> http.Post
    types_profile.HttpPut -> http.Put
    types_profile.HttpDelete -> http.Delete
  }
}

fn runner_env() -> List(#(String, String)) {
  let path_env = case envoy.get("PATH") {
    Ok(path) -> [#("PATH", path)]
    Error(_) -> []
  }

  let force_fallback = case envoy.get("SAAR_WRAPPER_FORCE_FALLBACK") {
    Ok(value) -> value
    Error(_) -> "1"
  }

  list.append(path_env, [#("SAAR_WRAPPER_FORCE_FALLBACK", force_fallback)])
}

fn runner_command(
  runner_def: types_runner.Runner,
  config: types_config.SaarConfig,
) -> #(String, List(String)) {
  let types_config.SaarConfig(runner: runner_cfg, ..) = config
  let types_config.RunnerSystemConfig(python_bin: python_bin, ..) = runner_cfg

  types_runner.runner_exec_command(runner_def, python_bin)
}

fn managed_port_host(config: types_config.SaarConfig) -> String {
  let types_config.SaarConfig(runner: runner_cfg, ..) = config
  let types_config.RunnerSystemConfig(managed_port_host: host, ..) = runner_cfg
  host
}

fn port_error_to_string(err: port_process.PortError) -> String {
  case err {
    port_process.WrapperNotFound(name) -> "Wrapper not found: " <> name
    port_process.SpawnFailed(reason) ->
      "Failed to start runner: " <> ffi.ffi_error_to_string(reason)
  }
}

fn input_payload_to_json(payload: types_input.InputPayload) -> json.Json {
  case payload {
    types_input.PayloadChat(messages, extra) -> {
      let base = [#("messages", json.array(messages, chat_message_to_json))]
      let extra_fields =
        extra
        |> dict.to_list
        |> list.map(fn(pair) { #(pair.0, input_value_to_json(pair.1)) })
      json.object(list.append(base, extra_fields))
    }

    types_input.PayloadFiles(files) ->
      json.object([#("files", json.array(files, file_ref_to_json))])

    types_input.PayloadMixed(messages, files, extra) -> {
      let base = [
        #("messages", json.array(messages, chat_message_to_json)),
        #("files", json.array(files, file_ref_to_json)),
      ]
      let extra_fields =
        extra
        |> dict.to_list
        |> list.map(fn(pair) { #(pair.0, input_value_to_json(pair.1)) })
      json.object(list.append(base, extra_fields))
    }
  }
}

fn chat_message_to_json(message: types_input.ChatMessage) -> json.Json {
  json.object([
    #("role", json.string(message.role)),
    #("content", json.string(message.content)),
  ])
}

fn file_ref_to_json(file: types_input.FileRef) -> json.Json {
  json.object([
    #("url", json.string(file.url)),
    #("mime", json.string(file.mime)),
    #("name", json.string(file.name)),
    #("context", case file.context {
      Some(ctx) -> json.string(ctx)
      None -> json.null()
    }),
  ])
}

fn input_value_to_json(value: types_input.InputValue) -> json.Json {
  case value {
    types_core.StringVal(s) -> json.string(s)
    types_core.IntVal(i) -> json.int(i)
    types_core.FloatVal(f) -> json.float(f)
    types_core.BoolVal(b) -> json.bool(b)
    types_core.ListVal(items) -> json.array(items, json.string)
  }
}
