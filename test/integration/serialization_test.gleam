import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option
import gleeunit
import gleeunit/should
import runner_fixtures
import sad/bridge/serialization
import sad/types/input as types_input
import sad/types/runner as types_runner
import simplifile

pub fn main() {
  gleeunit.main()
}

pub fn sad_input_contains_required_blocks_test() {
  let input =
    runner_fixtures.base_input(
      load_chat_payload(),
      types_runner.ArtifactConfig(include: [], exclude: []),
    )
  let body = serialization.sad_input_to_string(input)

  let decoder = {
    use _ <- decode.field("meta", decode.dynamic)
    use _ <- decode.field("params", decode.dynamic)
    use _ <- decode.field("input", decode.dynamic)
    use _ <- decode.field("context", decode.dynamic)
    use _ <- decode.field("helpers", decode.dynamic)
    use _ <- decode.field("runner_def", decode.dynamic)
    decode.success(Nil)
  }

  json.parse(body, decoder)
  |> should.equal(Ok(Nil))
}

pub fn runner_def_always_present_test() {
  let input =
    runner_fixtures.base_input(
      load_chat_payload(),
      types_runner.ArtifactConfig(include: [], exclude: []),
    )
  let body = serialization.sad_input_to_string(input)

  let decoder = decode.dict(decode.string, decode.dynamic)
  let assert Ok(values) = json.parse(body, decoder)

  dict.has_key(values, "runner_def")
  |> should.equal(True)

  dict.has_key(values, "runner")
  |> should.equal(False)
}

pub fn helpers_is_null_in_s04_test() {
  let input =
    runner_fixtures.base_input(
      load_chat_payload(),
      types_runner.ArtifactConfig(include: [], exclude: []),
    )
  let body = serialization.sad_input_to_string(input)

  let decoder = {
    use helpers <- decode.field("helpers", decode.optional(decode.dynamic))
    decode.success(helpers)
  }

  json.parse(body, decoder)
  |> should.equal(Ok(option.None))
}

fn load_chat_payload() -> types_input.InputPayload {
  let assert Ok(contents) =
    simplifile.read(from: "test/fixtures/payloads/chat_simple.json")

  let decoder = {
    use messages <- decode.field(
      "messages",
      decode.list(of: chat_message_decoder()),
    )
    decode.success(messages)
  }

  let assert Ok(messages) = json.parse(contents, decoder)
  types_input.PayloadChat(messages, dict.new())
}

fn chat_message_decoder() -> decode.Decoder(types_input.ChatMessage) {
  let decoder = {
    use role <- decode.field("role", decode.string)
    use content <- decode.field("content", decode.string)
    decode.success(types_input.ChatMessage(role: role, content: content))
  }

  decoder
}
