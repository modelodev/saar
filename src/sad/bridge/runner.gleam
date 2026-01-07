import gleam/dict
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option
import gleam/result
import sad/bridge/port_process
import sad/bridge/serialization
import sad/runner_contract
import sad/types

const read_timeout_ms = 200

const max_read_attempts = 200

pub fn execute_transient(
  runner_path: String,
  runner_args: List(String),
  env: List(#(String, String)),
  cwd: String,
  input: types.SadInput,
  max_runner_event_bytes: Int,
  max_stdout_bytes: Int,
) -> Result(types.InteractionResult, types.InteractionError) {
  use process <- result.try(start_process(
    runner_path,
    runner_args,
    env,
    cwd,
    max_runner_event_bytes,
    input.context.trace_id,
  ))

  let payload = serialization.sad_input_to_string(input)
  port_process.send(process, payload)

  use events <- result.try(read_events(
    process,
    max_stdout_bytes,
    input.context.trace_id,
    True,
  ))

  use _ <- result.try(
    runner_contract.validate_sequence(events, False)
    |> result.map_error(fn(error) {
      interaction_error(
        input.context.trace_id,
        "Invalid event sequence: " <> contract_error_to_string(error),
      )
    }),
  )

  case first_result(events, input.context.trace_id) {
    Ok(response) ->
      runner_response_to_interaction_result(response, input.context.trace_id)
    Error(error) -> Error(error)
  }
}

pub fn run_provision(
  runner_path: String,
  runner_args: List(String),
  env: List(#(String, String)),
  cwd: String,
  input: types.SadInput,
  max_runner_event_bytes: Int,
  max_stdout_bytes: Int,
) -> Result(types.RunnerProvisionResult, types.InteractionError) {
  let args = list.append(runner_args, ["--provision"])

  use process <- result.try(start_process(
    runner_path,
    args,
    env,
    cwd,
    max_runner_event_bytes,
    input.context.trace_id,
  ))

  let payload = serialization.sad_input_to_string(input)
  port_process.send(process, payload)

  use events <- result.try(read_events(
    process,
    max_stdout_bytes,
    input.context.trace_id,
    True,
  ))

  use provision <- result.try(provision_result_from_events(
    events,
    input.context.trace_id,
  ))

  case provision.status {
    types.StatusSuccess -> Ok(provision)
    types.StatusError ->
      Error(interaction_error(input.context.trace_id, "Provision failed"))
  }
}

fn start_process(
  runner_path: String,
  runner_args: List(String),
  env: List(#(String, String)),
  cwd: String,
  max_runner_event_bytes: Int,
  trace_id: types.TraceId,
) -> Result(port_process.PortProcess, types.InteractionError) {
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
      Error(types.InteractionError(
        kind: types.InfraError,
        message: "Wrapper not found: " <> name,
        trace_id: trace_id,
      ))
    Error(port_process.SpawnFailed(reason)) ->
      Error(types.InteractionError(
        kind: types.InfraError,
        message: "Failed to start runner: " <> reason,
        trace_id: trace_id,
      ))
  }
}

fn read_events(
  process: port_process.PortProcess,
  max_stdout_bytes: Int,
  trace_id: types.TraceId,
  close_on_timeout: Bool,
) -> Result(List(types.RunnerEvent), types.InteractionError) {
  read_events_loop(
    process,
    max_stdout_bytes,
    trace_id,
    0,
    [],
    max_read_attempts,
    close_on_timeout,
    False,
  )
}

fn read_events_loop(
  process: port_process.PortProcess,
  max_stdout_bytes: Int,
  trace_id: types.TraceId,
  total_bytes: Int,
  events: List(types.RunnerEvent),
  attempts: Int,
  close_on_timeout: Bool,
  stdin_closed: Bool,
) -> Result(List(types.RunnerEvent), types.InteractionError) {
  case attempts {
    0 -> Error(interaction_error(trace_id, "Runner read timeout"))
    _ ->
      case port_process.read_line(process, read_timeout_ms) {
        Ok(line) -> {
          use next_total <- result.try(
            runner_contract.enforce_max_stdout_bytes(
              total_bytes,
              line,
              max_stdout_bytes,
            )
            |> result.map_error(fn(error) {
              interaction_error(
                trace_id,
                "Runner output exceeded limit: "
                  <> contract_error_to_string(error),
              )
            }),
          )

          case runner_contract.decode_event(line) {
            Ok(event) ->
              read_events_loop(
                process,
                max_stdout_bytes,
                trace_id,
                next_total,
                [event, ..events],
                attempts,
                close_on_timeout,
                stdin_closed,
              )
            Error(error) ->
              Error(interaction_error(
                trace_id,
                "Invalid runner event: " <> contract_error_to_string(error),
              ))
          }
        }

        Error(port_process.Timeout) ->
          case close_on_timeout && !stdin_closed {
            True -> {
              port_process.send(process, "{\"t\":\"stop\"}")
              read_events_loop(
                process,
                max_stdout_bytes,
                trace_id,
                total_bytes,
                events,
                attempts,
                close_on_timeout,
                True,
              )
            }
            False ->
              read_events_loop(
                process,
                max_stdout_bytes,
                trace_id,
                total_bytes,
                events,
                attempts - 1,
                close_on_timeout,
                stdin_closed,
              )
          }
        Error(port_process.NoeolFragment(fragment)) ->
          Error(interaction_error(trace_id, "Fragmented output: " <> fragment))
        Error(port_process.PortExited(code)) ->
          case code {
            0 -> Ok(list.reverse(events))
            _ ->
              Error(types.InteractionError(
                kind: types.InfraError,
                message: "Runner exited with code " <> int.to_string(code),
                trace_id: trace_id,
              ))
          }
      }
  }
}

fn first_result(
  events: List(types.RunnerEvent),
  trace_id: types.TraceId,
) -> Result(types.RunnerResponse, types.InteractionError) {
  case
    list.find(events, fn(event) {
      case event {
        types.RunnerEventResult(_) -> True
        _ -> False
      }
    })
  {
    Ok(types.RunnerEventResult(response)) -> Ok(response)
    _ ->
      Error(types.InteractionError(
        kind: types.InfraError,
        message: "Runner exited without result event",
        trace_id: trace_id,
      ))
  }
}

fn provision_result_from_events(
  events: List(types.RunnerEvent),
  trace_id: types.TraceId,
) -> Result(types.RunnerProvisionResult, types.InteractionError) {
  let provision_events =
    events
    |> list.filter_map(fn(event) {
      case event {
        types.RunnerEventProvisionResult(result) -> Ok(result)
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
  response: types.RunnerResponse,
  trace_id: types.TraceId,
) -> Result(types.InteractionResult, types.InteractionError) {
  case response.status {
    types.StatusError -> {
      let message = case response.error {
        option.Some(err) -> err.message
        option.None -> "Runner returned error"
      }
      let kind = case response.error {
        option.Some(err) -> err.kind
        option.None -> types.InfraError
      }
      Error(types.InteractionError(
        kind: kind,
        message: message,
        trace_id: trace_id,
      ))
    }
    types.StatusSuccess -> {
      let data = response_data_from_runner(response.data)
      Ok(types.InteractionResult(data: data, artifacts: [], trace_id: trace_id))
    }
  }
}

fn response_data_from_runner(data: option.Option(Json)) -> types.ResponseData {
  case data {
    option.None ->
      types.ResponseData(content: option.None, metadata: dict.new())
    option.Some(payload) ->
      types.ResponseData(
        content: option.None,
        metadata: dict.from_list([#("raw", payload)]),
      )
  }
}

fn interaction_error(
  trace_id: types.TraceId,
  message: String,
) -> types.InteractionError {
  types.InteractionError(
    kind: types.InfraError,
    message: message,
    trace_id: trace_id,
  )
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
