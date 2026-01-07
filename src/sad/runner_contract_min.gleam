import gleam/option.{None}
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
  case extract_string_field(line, "t") {
    Ok(tag) ->
      case tag {
        "log" -> decode_log(line)
        "result" -> decode_result(line)
        other -> Error(UnknownEvent(other))
      }
    Error(error) -> Error(error)
  }
}

fn decode_log(line: String) -> Result(types.RunnerEvent, JsonlError) {
  case extract_string_field(line, "message") {
    Ok(message) ->
      case extract_string_field(line, "level") {
        Ok(level) -> Ok(types.RunnerEventLog(message: message, level: level))
        Error(error) -> Error(error)
      }
    Error(error) -> Error(error)
  }
}

fn decode_result(line: String) -> Result(types.RunnerEvent, JsonlError) {
  case extract_string_field(line, "status") {
    Ok(status) ->
      case parse_status(status) {
        Ok(status_value) ->
          Ok(
            types.RunnerEventResult(response: types.RunnerResponse(
              status: status_value,
              data: None,
              artifacts: [],
              error: None,
            )),
          )
        Error(error) -> Error(error)
      }
    Error(error) -> Error(error)
  }
}

fn parse_status(status: String) -> Result(types.RunnerStatus, JsonlError) {
  case status {
    "success" -> Ok(types.StatusSuccess)
    "error" -> Ok(types.StatusError)
    other -> Error(UnknownStatus(other))
  }
}

fn extract_string_field(
  line: String,
  key: String,
) -> Result(String, JsonlError) {
  let pattern = "\"" <> key <> "\":"

  case string.split_once(line, pattern) {
    Error(_) -> Error(InvalidJson("missing field: " <> key))
    Ok(#(_, rest)) -> {
      let rest = string.trim_start(rest)
      case string.starts_with(rest, "\"") {
        False -> Error(InvalidJson("expected string for: " <> key))
        True -> {
          let rest = string.drop_start(rest, 1)
          case string.split_once(rest, "\"") {
            Ok(#(value, _)) -> Ok(value)
            Error(_) -> Error(InvalidJson("unterminated string: " <> key))
          }
        }
      }
    }
  }
}
