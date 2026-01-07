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
  use tag <- result.try(
    json.parse(line, decode.field("t", decode.string))
    |> result.map_error(fn(err) { InvalidJson(string.inspect(err)) }),
  )

  case tag {
    "log" -> decode_log(line)
    "result" -> decode_result(line)
    other -> Error(UnknownEvent(other))
  }
}

fn decode_log(line: String) -> Result(types.RunnerEvent, JsonlError) {
  let decoder = {
    use message <- decode.field("message", decode.string)
    use level <- decode.field("level", decode.string)
    decode.success(types.RunnerEventLog(message: message, level: level))
  }

  json.parse(line, decoder)
  |> result.map_error(fn(err) { InvalidJson(string.inspect(err)) })
}

fn decode_result(line: String) -> Result(types.RunnerEvent, JsonlError) {
  let decoder = {
    use status <- decode.field("status", decode.string)
    decode.success(status)
  }

  let parse_result =
    json.parse(line, decoder)
    |> result.map_error(fn(err) { InvalidJson(string.inspect(err)) })

  use status <- result.try(parse_result)

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
