import gleam/dynamic/decode
import gleam/option.{None}
import gleam/result
import sad/bridge/runner_contract_common as contract_common
import sad/types/runner as types_runner

pub type JsonlError {
  InvalidJson(String)
  UnknownEvent(String)
  UnknownStatus(String)
}

pub fn decode_runner_event(
  line: String,
) -> Result(types_runner.RunnerEvent, JsonlError) {
  case contract_common.decode_tag(line, InvalidJson) {
    Ok("log") -> decode_log(line)
    Ok("result") -> decode_result(line)
    Ok(other) -> Error(UnknownEvent(other))
    Error(error) -> Error(error)
  }
}

fn decode_log(line: String) -> Result(types_runner.RunnerEvent, JsonlError) {
  let decoder = {
    use message <- decode.field("message", decode.string)
    use level <- decode.field("level", decode.string)
    decode.success(types_runner.RunnerEventLog(message: message, level: level))
  }

  contract_common.parse_json(line, decoder, InvalidJson)
}

fn decode_result(line: String) -> Result(types_runner.RunnerEvent, JsonlError) {
  let decoder = {
    use status <- decode.field("status", decode.string)
    decode.success(status)
  }

  use status <- result.try(contract_common.parse_json(
    line,
    decoder,
    InvalidJson,
  ))
  use status_value <- result.try(contract_common.parse_status(
    status,
    UnknownStatus,
  ))

  Ok(
    types_runner.RunnerEventResult(response: types_runner.RunnerResponse(
      status: status_value,
      data: None,
      artifacts: [],
      error: None,
    )),
  )
}
