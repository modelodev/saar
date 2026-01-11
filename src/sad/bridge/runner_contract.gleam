//// Runner JSONL contract.
////
//// Mission: decode runner-emitted JSONL events into `types_runner.RunnerEvent`
//// values and validate basic stream invariants.
////
//// Responsibilities:
//// - Decode event lines (`t=log|chunk|result|provision_result`).
//// - Validate event sequence constraints (result presence, chunk vs streaming).
//// - Enforce stdout size limits to avoid unbounded output.
////
//// Non-responsibilities:
//// - Port I/O or JSONL framing (see `sad/bridge/port_process`).
//// - Higher-level interaction orchestration.
////
//// Relationships:
//// - Consumed by `sad/bridge/runner` when reading stdout.
//// - Uses `sad/types/runner` and `sad/types/enums`.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import sad/types/enums as types_enums
import sad/types/runner as types_runner

pub type ContractError {
  InvalidJson(String)
  UnknownEvent(String)
  UnknownStatus(String)
  UnknownErrorKind(String)
  MissingResult
  DuplicateResult
  ChunkWithoutStreaming
  StdoutBytesExceeded(max: Int, total: Int)
}

pub fn decode_event(
  line: String,
) -> Result(types_runner.RunnerEvent, ContractError) {
  case decode_tag(line, InvalidJson) {
    Ok("log") -> decode_log(line)
    Ok("chunk") -> decode_chunk(line)
    Ok("result") -> decode_result(line)
    Ok("provision_result") -> decode_provision_result(line)
    Ok(other) -> Error(UnknownEvent(other))
    Error(error) -> Error(error)
  }
}

pub fn validate_sequence(
  events: List(types_runner.RunnerEvent),
  streaming: Bool,
) -> Result(Nil, ContractError) {
  let #(result_count, has_chunk) =
    list.fold(events, #(0, False), fn(acc, event) {
      let #(count, chunk_seen) = acc
      case event {
        types_runner.RunnerEventResult(_) -> #(count + 1, chunk_seen)
        types_runner.RunnerEventChunk(_) -> #(count, True)
        _ -> acc
      }
    })

  case has_chunk && !streaming {
    True -> Error(ChunkWithoutStreaming)
    False ->
      case result_count {
        0 -> Error(MissingResult)
        1 -> Ok(Nil)
        _ -> Error(DuplicateResult)
      }
  }
}

pub fn enforce_max_stdout_bytes(
  total: Int,
  line: String,
  max_bytes: Int,
) -> Result(Int, ContractError) {
  case max_bytes <= 0 {
    True -> Ok(total + string.byte_size(line))
    False -> {
      let next = total + string.byte_size(line)
      case next > max_bytes {
        True -> Error(StdoutBytesExceeded(max: max_bytes, total: next))
        False -> Ok(next)
      }
    }
  }
}

type RawRunnerError {
  RawRunnerError(kind: String, message: String)
}

type RawResult {
  RawResult(
    status: String,
    data: option.Option(json.Json),
    artifacts: List(types_runner.ArtifactRef),
    error: option.Option(RawRunnerError),
  )
}

type RawProvisionResult {
  RawProvisionResult(status: String, log_files: List(String))
}

fn decode_log(line: String) -> Result(types_runner.RunnerEvent, ContractError) {
  let decoder = {
    use message <- decode.field("message", decode.string)
    use level <- decode.field("level", decode.string)
    decode.success(types_runner.RunnerEventLog(message: message, level: level))
  }

  parse_json(line, decoder, InvalidJson)
}

fn decode_chunk(line: String) -> Result(types_runner.RunnerEvent, ContractError) {
  let decoder = {
    use delta <- decode.field("delta", decode.string)
    decode.success(types_runner.RunnerEventChunk(delta: delta))
  }

  parse_json(line, decoder, InvalidJson)
}

fn decode_result(
  line: String,
) -> Result(types_runner.RunnerEvent, ContractError) {
  let decoder = {
    use status <- decode.field("status", decode.string)
    use data <- decode.optional_field(
      "data",
      option.None,
      json_option_decoder(),
    )
    use artifacts <- decode.optional_field(
      "artifacts",
      [],
      decode.list(of: artifact_decoder()),
    )
    use error <- decode.optional_field("error", option.None, error_decoder())
    decode.success(RawResult(
      status: status,
      data: data,
      artifacts: artifacts,
      error: error,
    ))
  }

  use raw <- result.try(parse_json(line, decoder, InvalidJson))
  use status <- result.try(parse_status(raw.status, UnknownStatus))
  use error <- result.try(parse_runner_error(raw.error))

  Ok(
    types_runner.RunnerEventResult(
      response: types_runner.runner_response_from_raw(
        status,
        raw.data,
        raw.artifacts,
        error,
      ),
    ),
  )
}

fn decode_provision_result(
  line: String,
) -> Result(types_runner.RunnerEvent, ContractError) {
  let decoder = {
    use status <- decode.field("status", decode.string)
    use log_files <- decode.optional_field(
      "log_files",
      [],
      decode.list(of: decode.string),
    )
    decode.success(RawProvisionResult(status: status, log_files: log_files))
  }

  use raw <- result.try(parse_json(line, decoder, InvalidJson))
  use status <- result.try(parse_status(raw.status, UnknownStatus))

  Ok(
    types_runner.RunnerEventProvisionResult(
      result: types_runner.RunnerProvisionResult(
        status: status,
        log_files: raw.log_files,
      ),
    ),
  )
}

fn artifact_decoder() -> decode.Decoder(types_runner.ArtifactRef) {
  let decoder = {
    use name <- decode.field("name", decode.string)
    use path <- decode.field("path", decode.string)
    use mime <- decode.field("mime", decode.string)
    decode.success(types_runner.ArtifactRef(name: name, path: path, mime: mime))
  }

  decoder
}

fn error_decoder() -> decode.Decoder(option.Option(RawRunnerError)) {
  decode.optional(raw_runner_error_decoder())
}

fn raw_runner_error_decoder() -> decode.Decoder(RawRunnerError) {
  let decoder = {
    use kind <- decode.field("kind", decode.string)
    use message <- decode.field("message", decode.string)
    decode.success(RawRunnerError(kind: kind, message: message))
  }

  decoder
}

fn json_option_decoder() -> decode.Decoder(option.Option(json.Json)) {
  decode.optional(decode.dynamic)
  |> decode.map(fn(value) { option.map(value, json_from_dynamic) })
}

fn parse_runner_error(
  raw: option.Option(RawRunnerError),
) -> Result(option.Option(types_runner.RunnerError), ContractError) {
  case raw {
    option.None -> Ok(option.None)
    option.Some(RawRunnerError(kind: kind, message: message)) -> {
      use parsed <- result.try(parse_error_kind(kind))
      Ok(option.Some(types_runner.RunnerError(kind: parsed, message: message)))
    }
  }
}

fn parse_error_kind(
  kind: String,
) -> Result(types_enums.ErrorKind, ContractError) {
  types_enums.error_kind_from_string(kind)
  |> result.map_error(fn(_) { UnknownErrorKind(kind) })
}

@external(erlang, "gleam_stdlib", "identity")
fn json_from_dynamic(data: Dynamic) -> json.Json

fn parse_json(
  line: String,
  decoder: decode.Decoder(a),
  on_invalid_json: fn(String) -> e,
) -> Result(a, e) {
  json.parse(line, decoder)
  |> result.map_error(fn(err) { on_invalid_json(string.inspect(err)) })
}

fn decode_tag(
  line: String,
  on_invalid_json: fn(String) -> e,
) -> Result(String, e) {
  let decoder = {
    use tag <- decode.field("t", decode.string)
    decode.success(tag)
  }

  parse_json(line, decoder, on_invalid_json)
}

fn parse_status(
  status: String,
  on_unknown: fn(String) -> e,
) -> Result(types_runner.RunnerStatus, e) {
  case status {
    "success" -> Ok(types_runner.StatusSuccess)
    "error" -> Ok(types_runner.StatusError)
    other -> Error(on_unknown(other))
  }
}
