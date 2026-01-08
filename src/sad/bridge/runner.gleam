import gleam/dict
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option
import gleam/result
import sad/artifacts
import sad/bridge/port_process
import sad/bridge/serialization
import sad/runner_contract
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/input as types_input
import sad/types/output as types_output
import sad/types/runner as types_runner

const read_timeout_ms = 200

const max_read_attempts = 200

type ReadState {
  ReadState(
    total_bytes: Int,
    events: List(types_runner.RunnerEvent),
    attempts: Int,
    stdin_closed: Bool,
  )
}

pub fn execute_transient(
  runner_path: String,
  runner_args: List(String),
  env: List(#(String, String)),
  cwd: String,
  input: types_input.SadInput,
  max_runner_event_bytes: Int,
  max_stdout_bytes: Int,
  streaming: Bool,
) -> Result(types_output.InteractionResult, types_output.InteractionError) {
  use events <- result.try(run_and_collect_events(
    runner_path,
    runner_args,
    env,
    cwd,
    input,
    max_runner_event_bytes,
    max_stdout_bytes,
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
  max_runner_event_bytes: Int,
  max_stdout_bytes: Int,
) -> Result(types_runner.RunnerProvisionResult, types_output.InteractionError) {
  let args = list.append(runner_args, ["--provision"])

  use events <- result.try(run_and_collect_events(
    runner_path,
    args,
    env,
    cwd,
    input,
    max_runner_event_bytes,
    max_stdout_bytes,
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
  close_on_timeout: Bool,
) -> Result(List(types_runner.RunnerEvent), types_output.InteractionError) {
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

  read_events(
    process,
    max_stdout_bytes,
    input.context.trace_id,
    close_on_timeout,
  )
}

fn read_events(
  process: port_process.PortProcess,
  max_stdout_bytes: Int,
  trace_id: types_core.TraceId,
  close_on_timeout: Bool,
) -> Result(List(types_runner.RunnerEvent), types_output.InteractionError) {
  read_events_loop(
    process,
    max_stdout_bytes,
    trace_id,
    close_on_timeout,
    ReadState(
      total_bytes: 0,
      events: [],
      attempts: max_read_attempts,
      stdin_closed: False,
    ),
  )
}

fn read_events_loop(
  process: port_process.PortProcess,
  max_stdout_bytes: Int,
  trace_id: types_core.TraceId,
  close_on_timeout: Bool,
  state: ReadState,
) -> Result(List(types_runner.RunnerEvent), types_output.InteractionError) {
  let ReadState(
    total_bytes: total_bytes,
    events: events,
    attempts: attempts,
    stdin_closed: stdin_closed,
  ) = state

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
                close_on_timeout,
                ReadState(
                  total_bytes: next_total,
                  events: [event, ..events],
                  attempts: attempts,
                  stdin_closed: stdin_closed,
                ),
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
                close_on_timeout,
                ReadState(
                  total_bytes: total_bytes,
                  events: events,
                  attempts: attempts,
                  stdin_closed: True,
                ),
              )
            }
            False ->
              read_events_loop(
                process,
                max_stdout_bytes,
                trace_id,
                close_on_timeout,
                ReadState(
                  total_bytes: total_bytes,
                  events: events,
                  attempts: attempts - 1,
                  stdin_closed: stdin_closed,
                ),
              )
          }
        Error(port_process.NoeolFragment(fragment)) ->
          Error(interaction_error(trace_id, "Fragmented output: " <> fragment))
        Error(port_process.PortExited(code)) ->
          case code {
            0 -> Ok(list.reverse(events))
            _ ->
              Error(interaction_error(
                trace_id,
                "Runner exited with code " <> int.to_string(code),
              ))
          }
      }
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
        artifacts.collect(response.artifacts, artifact_config)
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
