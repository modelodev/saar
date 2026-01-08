import gleam/dict
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option
import gleam/result
import sad/artifacts
import sad/bridge/port_process
import sad/bridge/serialization
import sad/ffi
import sad/runner_contract
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/input as types_input
import sad/types/output as types_output
import sad/types/runner as types_runner

type Deadline {
  Infinite
  At(Int)
}

type ReadState {
  ReadState(
    total_bytes: Int,
    events: List(types_runner.RunnerEvent),
    attempts: Int,
    stdin_closed: Bool,
    stop_deadline: Deadline,
  )
}

pub fn execute_transient(
  runner_path: String,
  runner_args: List(String),
  env: List(#(String, String)),
  cwd: String,
  input: types_input.SadInput,
  config: types_config.SadConfig,
  streaming: Bool,
  timeout_ms: Int,
) -> Result(types_output.InteractionResult, types_output.InteractionError) {
  let #(
    max_runner_event_bytes,
    max_stdout_bytes,
    read_timeout_ms,
    max_read_attempts,
    shutdown_timeout_ms,
    wrapper,
    artifact_base_path,
  ) = runner_settings(config)

  use events <- result.try(run_and_collect_events(
    runner_path,
    runner_args,
    env,
    cwd,
    input,
    max_runner_event_bytes,
    max_stdout_bytes,
    read_timeout_ms,
    max_read_attempts,
    timeout_ms,
    shutdown_timeout_ms,
    wrapper,
    True,
  ))

  use _ <- result.try(
    runner_contract.validate_sequence(events, streaming)
    |> result.map_error(fn(error) {
      interaction_error(
        input.context.trace_id,
        "Invalid event sequence: " <> contract_error_to_string(error),
      )
    }),
  )

  case first_result(events, input.context.trace_id) {
    Ok(response) ->
      runner_response_to_interaction_result(
        response,
        input.runner_def.artifact_config,
        artifact_base_path,
        input.context.trace_id,
      )
    Error(error) -> Error(error)
  }
}

pub fn run_provision(
  runner_path: String,
  runner_args: List(String),
  env: List(#(String, String)),
  cwd: String,
  input: types_input.SadInput,
  config: types_config.SadConfig,
  timeout_ms: Int,
) -> Result(types_runner.RunnerProvisionResult, types_output.InteractionError) {
  let #(
    max_runner_event_bytes,
    max_stdout_bytes,
    read_timeout_ms,
    max_read_attempts,
    shutdown_timeout_ms,
    wrapper,
    _,
  ) = runner_settings(config)
  let args = list.append(runner_args, ["--provision"])

  use events <- result.try(run_and_collect_events(
    runner_path,
    args,
    env,
    cwd,
    input,
    max_runner_event_bytes,
    max_stdout_bytes,
    read_timeout_ms,
    max_read_attempts,
    timeout_ms,
    shutdown_timeout_ms,
    wrapper,
    True,
  ))

  use provision <- result.try(provision_result_from_events(
    events,
    input.context.trace_id,
  ))

  case provision.status {
    types_runner.StatusSuccess -> Ok(provision)
    types_runner.StatusError ->
      Error(interaction_error(input.context.trace_id, "Provision failed"))
  }
}

fn start_process(
  runner_path: String,
  runner_args: List(String),
  env: List(#(String, String)),
  cwd: String,
  max_runner_event_bytes: Int,
  trace_id: types_core.TraceId,
) -> Result(port_process.PortProcess, types_output.InteractionError) {
  case
    port_process.start(
      runner_path,
      runner_args,
      env,
      cwd,
      max_runner_event_bytes,
    )
  {
    Ok(process) -> Ok(process)
    Error(port_process.WrapperNotFound(name)) ->
      Error(interaction_error(trace_id, "Wrapper not found: " <> name))
    Error(port_process.SpawnFailed(reason)) ->
      Error(interaction_error(trace_id, "Failed to start runner: " <> reason))
  }
}

fn run_and_collect_events(
  runner_path: String,
  runner_args: List(String),
  env: List(#(String, String)),
  cwd: String,
  input: types_input.SadInput,
  max_runner_event_bytes: Int,
  max_stdout_bytes: Int,
  read_timeout_ms: Int,
  max_read_attempts: Int,
  timeout_ms: Int,
  shutdown_timeout_ms: Int,
  wrapper: types_config.WrapperConfig,
  stop_on_timeout: Bool,
) -> Result(List(types_runner.RunnerEvent), types_output.InteractionError) {
  let env = append_wrapper_env(env, wrapper, shutdown_timeout_ms)
  use process <- result.try(start_process(
    runner_path,
    runner_args,
    env,
    cwd,
    max_runner_event_bytes,
    input.context.trace_id,
  ))

  let control_line =
    json.object([
      #("t", json.string("input")),
      #("payload", serialization.sad_input_to_json(input)),
    ])
    |> json.to_string
  port_process.send(process, control_line <> "\n")

  read_events(
    process,
    max_stdout_bytes,
    input.context.trace_id,
    read_timeout_ms,
    max_read_attempts,
    timeout_ms,
    shutdown_timeout_ms,
    wrapper,
    stop_on_timeout,
  )
}

fn read_events(
  process: port_process.PortProcess,
  max_stdout_bytes: Int,
  trace_id: types_core.TraceId,
  read_timeout_ms: Int,
  max_read_attempts: Int,
  timeout_ms: Int,
  shutdown_timeout_ms: Int,
  wrapper: types_config.WrapperConfig,
  stop_on_timeout: Bool,
) -> Result(List(types_runner.RunnerEvent), types_output.InteractionError) {
  let call_deadline = deadline_from_timeout(timeout_ms)
  read_events_loop(
    process,
    max_stdout_bytes,
    trace_id,
    ReadState(
      total_bytes: 0,
      events: [],
      attempts: max_read_attempts,
      stdin_closed: False,
      stop_deadline: Infinite,
    ),
    read_timeout_ms,
    call_deadline,
    shutdown_timeout_ms,
    wrapper,
    stop_on_timeout,
  )
}

fn read_events_loop(
  process: port_process.PortProcess,
  max_stdout_bytes: Int,
  trace_id: types_core.TraceId,
  state: ReadState,
  read_timeout_ms: Int,
  call_deadline: Deadline,
  shutdown_timeout_ms: Int,
  wrapper: types_config.WrapperConfig,
  stop_on_timeout: Bool,
) -> Result(List(types_runner.RunnerEvent), types_output.InteractionError) {
  let now_ms = ffi.now_ms()

  use state <- result.try(ensure_stop_deadline(state, now_ms, trace_id))
  use state <- result.try(update_state_for_timeout(
    process,
    state,
    now_ms,
    call_deadline,
    stop_on_timeout,
    shutdown_timeout_ms,
    wrapper,
    trace_id,
  ))

  case attempts_expired(state, call_deadline) {
    True -> Error(interaction_error(trace_id, "Runner read timeout"))
    False ->
      read_event(
        process,
        max_stdout_bytes,
        trace_id,
        read_timeout_ms,
        call_deadline,
        shutdown_timeout_ms,
        wrapper,
        stop_on_timeout,
        state,
      )
  }
}

fn read_event(
  process: port_process.PortProcess,
  max_stdout_bytes: Int,
  trace_id: types_core.TraceId,
  read_timeout_ms: Int,
  call_deadline: Deadline,
  shutdown_timeout_ms: Int,
  wrapper: types_config.WrapperConfig,
  stop_on_timeout: Bool,
  state: ReadState,
) -> Result(List(types_runner.RunnerEvent), types_output.InteractionError) {
  let ReadState(events: events, ..) = state

  case port_process.read_line(process, read_timeout_ms) {
    Ok(line) ->
      handle_read_line(
        process,
        max_stdout_bytes,
        trace_id,
        read_timeout_ms,
        call_deadline,
        shutdown_timeout_ms,
        wrapper,
        stop_on_timeout,
        state,
        line,
      )

    Error(port_process.Timeout) ->
      read_events_loop(
        process,
        max_stdout_bytes,
        trace_id,
        decrement_attempts_if_needed(state, call_deadline),
        read_timeout_ms,
        call_deadline,
        shutdown_timeout_ms,
        wrapper,
        stop_on_timeout,
      )
    Error(port_process.NoeolFragment(fragment)) ->
      Error(interaction_error(trace_id, "Fragmented output: " <> fragment))
    Error(port_process.PortExited(code)) ->
      handle_port_exit(code, events, trace_id, call_deadline)
  }
}

fn handle_read_line(
  process: port_process.PortProcess,
  max_stdout_bytes: Int,
  trace_id: types_core.TraceId,
  read_timeout_ms: Int,
  call_deadline: Deadline,
  shutdown_timeout_ms: Int,
  wrapper: types_config.WrapperConfig,
  stop_on_timeout: Bool,
  state: ReadState,
  line: String,
) -> Result(List(types_runner.RunnerEvent), types_output.InteractionError) {
  let now_ms = ffi.now_ms()
  use state <- result.try(update_state_for_timeout(
    process,
    state,
    now_ms,
    call_deadline,
    stop_on_timeout,
    shutdown_timeout_ms,
    wrapper,
    trace_id,
  ))

  case deadline_reached(call_deadline, now_ms) {
    True ->
      read_events_loop(
        process,
        max_stdout_bytes,
        trace_id,
        state,
        read_timeout_ms,
        call_deadline,
        shutdown_timeout_ms,
        wrapper,
        stop_on_timeout,
      )
    False ->
      handle_event_line(
        process,
        max_stdout_bytes,
        trace_id,
        read_timeout_ms,
        call_deadline,
        shutdown_timeout_ms,
        wrapper,
        stop_on_timeout,
        state,
        line,
      )
  }
}

fn handle_event_line(
  process: port_process.PortProcess,
  max_stdout_bytes: Int,
  trace_id: types_core.TraceId,
  read_timeout_ms: Int,
  call_deadline: Deadline,
  shutdown_timeout_ms: Int,
  wrapper: types_config.WrapperConfig,
  stop_on_timeout: Bool,
  state: ReadState,
  line: String,
) -> Result(List(types_runner.RunnerEvent), types_output.InteractionError) {
  let ReadState(total_bytes: total_bytes, events: events, ..) = state
  use next_total <- result.try(
    enforce_stdout_limit(total_bytes, line, max_stdout_bytes, trace_id),
  )
  use event <- result.try(decode_runner_event(line, trace_id))

  read_events_loop(
    process,
    max_stdout_bytes,
    trace_id,
    ReadState(..state, total_bytes: next_total, events: [event, ..events]),
    read_timeout_ms,
    call_deadline,
    shutdown_timeout_ms,
    wrapper,
    stop_on_timeout,
  )
}

fn enforce_stdout_limit(
  total_bytes: Int,
  line: String,
  max_stdout_bytes: Int,
  trace_id: types_core.TraceId,
) -> Result(Int, types_output.InteractionError) {
  runner_contract.enforce_max_stdout_bytes(total_bytes, line, max_stdout_bytes)
  |> result.map_error(fn(error) {
    interaction_error(
      trace_id,
      "Runner output exceeded limit: " <> contract_error_to_string(error),
    )
  })
}

fn decode_runner_event(
  line: String,
  trace_id: types_core.TraceId,
) -> Result(types_runner.RunnerEvent, types_output.InteractionError) {
  runner_contract.decode_event(line)
  |> result.map_error(fn(error) {
    interaction_error(
      trace_id,
      "Invalid runner event: " <> contract_error_to_string(error),
    )
  })
}

fn handle_port_exit(
  code: Int,
  events: List(types_runner.RunnerEvent),
  trace_id: types_core.TraceId,
  call_deadline: Deadline,
) -> Result(List(types_runner.RunnerEvent), types_output.InteractionError) {
  case code {
    0 ->
      case deadline_reached(call_deadline, ffi.now_ms()) {
        True -> Error(interaction_error(trace_id, "Runner call timeout"))
        False -> Ok(list.reverse(events))
      }
    _ ->
      Error(interaction_error(
        trace_id,
        "Runner exited with code " <> int.to_string(code),
      ))
  }
}

fn first_result(
  events: List(types_runner.RunnerEvent),
  trace_id: types_core.TraceId,
) -> Result(types_runner.RunnerResponse, types_output.InteractionError) {
  case
    list.find(events, fn(event) {
      case event {
        types_runner.RunnerEventResult(_) -> True
        _ -> False
      }
    })
  {
    Ok(types_runner.RunnerEventResult(response)) -> Ok(response)
    _ ->
      Error(interaction_error(trace_id, "Runner exited without result event"))
  }
}

fn provision_result_from_events(
  events: List(types_runner.RunnerEvent),
  trace_id: types_core.TraceId,
) -> Result(types_runner.RunnerProvisionResult, types_output.InteractionError) {
  let provision_events =
    events
    |> list.filter_map(fn(event) {
      case event {
        types_runner.RunnerEventProvisionResult(result) -> Ok(result)
        _ -> Error(Nil)
      }
    })

  case provision_events {
    [only] -> Ok(only)
    [] -> Error(interaction_error(trace_id, "Missing provision_result"))
    _ -> Error(interaction_error(trace_id, "Multiple provision_result events"))
  }
}

fn runner_response_to_interaction_result(
  response: types_runner.RunnerResponse,
  artifact_config: types_runner.ArtifactConfig,
  artifact_base_path: String,
  trace_id: types_core.TraceId,
) -> Result(types_output.InteractionResult, types_output.InteractionError) {
  case response.status {
    types_runner.StatusError -> {
      let message = case response.error {
        option.Some(err) -> err.message
        option.None -> "Runner returned error"
      }
      let kind = case response.error {
        option.Some(err) -> err.kind
        option.None -> types_enums.InfraError
      }
      Error(types_output.InteractionError(
        kind: kind,
        message: message,
        trace_id: trace_id,
      ))
    }
    types_runner.StatusSuccess -> {
      let data = response_data_from_runner(response.data)
      let artifacts =
        artifacts.collect(
          response.artifacts,
          artifact_config,
          artifact_base_path,
        )
        |> result.map_error(fn(err) {
          interaction_error(
            trace_id,
            "Invalid artifact path: " <> artifact_error_to_string(err),
          )
        })

      use public_artifacts <- result.try(artifacts)

      Ok(types_output.InteractionResult(
        data: data,
        artifacts: public_artifacts,
        trace_id: trace_id,
      ))
    }
  }
}

fn response_data_from_runner(
  data: option.Option(Json),
) -> types_output.ResponseData {
  case data {
    option.None ->
      types_output.ResponseData(content: option.None, metadata: dict.new())
    option.Some(payload) ->
      types_output.ResponseData(
        content: option.None,
        metadata: dict.from_list([#("raw", payload)]),
      )
  }
}

fn interaction_error(
  trace_id: types_core.TraceId,
  message: String,
) -> types_output.InteractionError {
  types_output.InteractionError(
    kind: types_enums.InfraError,
    message: message,
    trace_id: trace_id,
  )
}

fn runner_settings(
  config: types_config.SadConfig,
) -> #(Int, Int, Int, Int, Int, types_config.WrapperConfig, String) {
  let types_config.SadConfig(
    max_runner_event_bytes: max_runner_event_bytes,
    max_stdout_bytes: max_stdout_bytes,
    runner_io: runner_io,
    shutdown_timeout_ms: shutdown_timeout_ms,
    wrapper: wrapper,
    artifacts: artifacts,
    ..,
  ) = config

  let types_config.RunnerIoConfig(
    read_timeout_ms: read_timeout_ms,
    max_read_attempts: max_read_attempts,
  ) = runner_io

  let types_config.ArtifactStoreConfig(base_path: base_path) = artifacts

  #(
    max_runner_event_bytes,
    max_stdout_bytes,
    read_timeout_ms,
    max_read_attempts,
    shutdown_timeout_ms,
    wrapper,
    base_path,
  )
}

fn append_wrapper_env(
  env: List(#(String, String)),
  wrapper: types_config.WrapperConfig,
  shutdown_timeout_ms: Int,
) -> List(#(String, String)) {
  let types_config.WrapperConfig(
    read_buffer_bytes: read_buffer_bytes,
    control_line_bytes: control_line_bytes,
    poll_interval_ms: poll_interval_ms,
    post_kill_wait_ms: post_kill_wait_ms,
  ) = wrapper

  list.append(env, [
    #("SAD_SHUTDOWN_MS", int.to_string(shutdown_timeout_ms)),
    #("SAD_WRAPPER_READ_BUFFER_BYTES", int.to_string(read_buffer_bytes)),
    #("SAD_WRAPPER_CONTROL_LINE_BYTES", int.to_string(control_line_bytes)),
    #("SAD_WRAPPER_POLL_MS", int.to_string(poll_interval_ms)),
    #("SAD_WRAPPER_POST_KILL_WAIT_MS", int.to_string(post_kill_wait_ms)),
  ])
}

fn deadline_from_timeout(timeout_ms: Int) -> Deadline {
  case timeout_ms <= 0 {
    True -> Infinite
    False -> At(ffi.now_ms() + timeout_ms)
  }
}

fn deadline_reached(deadline: Deadline, now_ms: Int) -> Bool {
  case deadline {
    Infinite -> False
    At(deadline_ms) -> now_ms >= deadline_ms
  }
}

fn stop_deadline_from(
  now_ms: Int,
  shutdown_timeout_ms: Int,
  wrapper: types_config.WrapperConfig,
) -> Deadline {
  let types_config.WrapperConfig(post_kill_wait_ms: post_kill_wait_ms, ..) =
    wrapper
  At(now_ms + {shutdown_timeout_ms * 2} + post_kill_wait_ms)
}

fn ensure_stop_deadline(
  state: ReadState,
  now_ms: Int,
  trace_id: types_core.TraceId,
) -> Result(ReadState, types_output.InteractionError) {
  case deadline_reached(state.stop_deadline, now_ms) {
    True -> Error(interaction_error(trace_id, "Runner stop timeout"))
    False -> Ok(state)
  }
}

fn update_state_for_timeout(
  process: port_process.PortProcess,
  state: ReadState,
  now_ms: Int,
  call_deadline: Deadline,
  stop_on_timeout: Bool,
  shutdown_timeout_ms: Int,
  wrapper: types_config.WrapperConfig,
  trace_id: types_core.TraceId,
) -> Result(ReadState, types_output.InteractionError) {
  case deadline_reached(call_deadline, now_ms) {
    False -> Ok(state)
    True ->
      case stop_on_timeout {
        False -> Error(interaction_error(trace_id, "Runner call timeout"))
        True -> Ok(apply_timeout_stop(
          process,
          state,
          now_ms,
          shutdown_timeout_ms,
          wrapper,
        ))
      }
  }
}

fn apply_timeout_stop(
  process: port_process.PortProcess,
  state: ReadState,
  now_ms: Int,
  shutdown_timeout_ms: Int,
  wrapper: types_config.WrapperConfig,
) -> ReadState {
  let stop_deadline = case state.stop_deadline {
    Infinite -> stop_deadline_from(now_ms, shutdown_timeout_ms, wrapper)
    At(_) -> state.stop_deadline
  }

  case state.stdin_closed {
    True -> ReadState(..state, stop_deadline: stop_deadline)
    False -> {
      port_process.send(process, "{\"t\":\"stop\"}\n")
      ReadState(..state, stdin_closed: True, stop_deadline: stop_deadline)
    }
  }
}

fn attempts_expired(state: ReadState, call_deadline: Deadline) -> Bool {
  case call_deadline {
    Infinite -> state.attempts <= 0
    At(_) -> False
  }
}

fn decrement_attempts_if_needed(
  state: ReadState,
  call_deadline: Deadline,
) -> ReadState {
  case call_deadline {
    Infinite ->
      ReadState(..state, attempts: int.max(state.attempts - 1, 0))
    At(_) -> state
  }
}

fn contract_error_to_string(error: runner_contract.ContractError) -> String {
  case error {
    runner_contract.InvalidJson(reason) -> reason
    runner_contract.UnknownEvent(tag) -> "unknown event: " <> tag
    runner_contract.UnknownStatus(status) -> "unknown status: " <> status
    runner_contract.UnknownErrorKind(kind) -> "unknown error kind: " <> kind
    runner_contract.MissingResult -> "missing result"
    runner_contract.DuplicateResult -> "duplicate result"
    runner_contract.ChunkWithoutStreaming -> "chunk without streaming"
    runner_contract.StdoutBytesExceeded(max, total) ->
      "stdout exceeded " <> int.to_string(total) <> " > " <> int.to_string(max)
  }
}

fn artifact_error_to_string(error: artifacts.ArtifactError) -> String {
  case error {
    artifacts.InvalidPath(message) -> message
  }
}
