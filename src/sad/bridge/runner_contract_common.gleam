import gleam/dynamic/decode
import gleam/json
import gleam/result
import gleam/string
import sad/types/runner as types_runner

pub fn parse_json(
  line: String,
  decoder: decode.Decoder(a),
  on_invalid_json: fn(String) -> e,
) -> Result(a, e) {
  json.parse(line, decoder)
  |> result.map_error(fn(err) { on_invalid_json(string.inspect(err)) })
}

pub fn decode_tag(
  line: String,
  on_invalid_json: fn(String) -> e,
) -> Result(String, e) {
  let decoder = {
    use tag <- decode.field("t", decode.string)
    decode.success(tag)
  }

  parse_json(line, decoder, on_invalid_json)
}

pub fn parse_status(
  status: String,
  on_unknown: fn(String) -> e,
) -> Result(types_runner.RunnerStatus, e) {
  case status {
    "success" -> Ok(types_runner.StatusSuccess)
    "error" -> Ok(types_runner.StatusError)
    other -> Error(on_unknown(other))
  }
}
