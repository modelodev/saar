import gleam/dynamic/decode
import gleam/json
import gleam/option.{None}
import gleam/result
import gleam/string
import sad/types

pub type JsonlError {
  InvalidJson(String)
  UnknownEvent(String)
  UnknownStatus(String)
}

pub fn decode_runner_event(
  line: String,
) -> Result(types.RunnerEvent, JsonlError) {
  case decode_tag(line) {
    Ok("log") -> decode_log(line)
    Ok("result") -> decode_result(line)
    Ok(other) -> Error(UnknownEvent(other))
    Error(error) -> Error(error)
  }
}

fn decode_log(line: String) -> Result(types.RunnerEvent, JsonlError) {
  let decoder = {
    use message <- decode.field("message", decode.string)
    use level <- decode.field("level", decode.string)
    decode.success(types.RunnerEventLog(message: message, level: level))
  }

  parse_json(line, decoder)
}

fn decode_result(line: String) -> Result(types.RunnerEvent, JsonlError) {
  let decoder = {
    use status <- decode.field("status", decode.string)
    decode.success(status)
  }

  use status <- result.try(parse_json(line, decoder))
  use status_value <- result.try(parse_status(status))

  Ok(
    types.RunnerEventResult(response: types.RunnerResponse(
      status: status_value,
      data: None,
      artifacts: [],
      error: None,
    )),
  )
}

fn parse_status(status: String) -> Result(types.RunnerStatus, JsonlError) {
  case status {
    "success" -> Ok(types.StatusSuccess)
    "error" -> Ok(types.StatusError)
    other -> Error(UnknownStatus(other))
  }
}

fn decode_tag(line: String) -> Result(String, JsonlError) {
  let decoder = {
    use tag <- decode.field("t", decode.string)
    decode.success(tag)
  }

  parse_json(line, decoder)
}

fn parse_json(line: String, decoder: decode.Decoder(a)) -> Result(a, JsonlError) {
  json.parse(line, decoder)
  |> result.map_error(fn(err) { InvalidJson(string.inspect(err)) })
}
