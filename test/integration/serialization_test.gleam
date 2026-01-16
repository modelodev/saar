import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option
import gleeunit
import gleeunit/should
import runner_fixtures
import saar/bridge/serialization
import saar/types/input as types_input
import saar/types/runner as types_runner
import simplifile

pub fn main() {
  gleeunit.main()
}

pub fn saar_input_contains_required_blocks_test() {
  let input =
    runner_fixtures.base_input(
      load_chat_payload(),
      types_runner.ArtifactConfig(include: [], exclude: []),
    )
  let body = serialization.saar_input_to_string(input)

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
  let body = serialization.saar_input_to_string(input)

  let decoder = decode.dict(decode.string, decode.dynamic)
  let assert Ok(values) = json.parse(body, decoder)

  dict.has_key(values, "runner_def")
  |> should.equal(True)

  dict.has_key(values, "runner")
  |> should.equal(False)
}

pub fn helpers_include_last_user_content_test() {
  let input =
    runner_fixtures.base_input(
      load_chat_payload(),
      types_runner.ArtifactConfig(include: [], exclude: []),
    )
  let body = serialization.saar_input_to_string(input)

  let decoder = {
    use helpers <- decode.field("helpers", helpers_decoder())
    decode.success(helpers)
  }

  json.parse(body, decoder)
  |> should.equal(Ok(#(option.Some("Hello"), [])))
}

pub fn helpers_include_last_user_files_test() {
  let input =
    runner_fixtures.base_input(
      load_files_payload(),
      types_runner.ArtifactConfig(include: [], exclude: []),
    )
  let body = serialization.saar_input_to_string(input)

  let decoder = {
    use helpers <- decode.field("helpers", helpers_decoder())
    decode.success(helpers)
  }

  let assert Ok(#(last_user_content, files)) = json.parse(body, decoder)
  last_user_content |> should.equal(option.None)
  files
  |> should.equal([
    types_input.FileRef(
      url: "https://example.com/doc.pdf",
      mime: "application/pdf",
      name: "doc.pdf",
      context: option.None,
    ),
  ])
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

fn helpers_decoder() -> decode.Decoder(
  #(option.Option(String), List(types_input.FileRef)),
) {
  let decoder = {
    use last_user_content <- decode.field(
      "last_user_content",
      decode.optional(decode.string),
    )
    use last_user_files <- decode.field(
      "last_user_files",
      decode.list(of: file_ref_decoder()),
    )
    decode.success(#(last_user_content, last_user_files))
  }

  decoder
}

fn file_ref_decoder() -> decode.Decoder(types_input.FileRef) {
  let decoder = {
    use url <- decode.field("url", decode.string)
    use mime <- decode.field("mime", decode.string)
    use name <- decode.field("name", decode.string)
    use context <- decode.optional_field(
      "context",
      option.None,
      decode.optional(decode.string),
    )
    decode.success(types_input.FileRef(
      url: url,
      mime: mime,
      name: name,
      context: context,
    ))
  }

  decoder
}

fn load_files_payload() -> types_input.InputPayload {
  let assert Ok(contents) =
    simplifile.read(from: "test/fixtures/payloads/files_single.json")

  let decoder = {
    use files <- decode.field("files", decode.list(of: file_ref_decoder()))
    decode.success(files)
  }

  let assert Ok(files) = json.parse(contents, decoder)
  types_input.PayloadFiles(files)
}
