import gleam/json
import gleam/list
import gleeunit
import gleeunit/should
import sad/decoders
import simplifile

pub fn main() {
  gleeunit.main()
}

pub fn decode_profile_examples_ok_test() {
  let fixtures = [
    "test/fixtures/source_local/profiles/echo_cli.json",
    "test/fixtures/source_local/profiles/echo_server.json",
    "test/fixtures/source_local/profiles/greedy_logger.json",
    "test/fixtures/source_local/profiles/slow_poke.json",
    "test/fixtures/source_local/profiles/crasher.json",
    "test/fixtures/source_local/profiles/artifact_gen.json",
    "test/fixtures/source_local/profiles/streaming_echo.json",
  ]

  fixtures
  |> list.each(fn(path) {
    let assert Ok(contents) = simplifile.read(from: path)
    json.parse(contents, decoders.profile_decoder())
    |> should.be_ok
  })
}

pub fn decode_profile_examples_unknown_keys_ignored_test() {
  let payload =
    "{"
    <> "\"meta\":{\"id\":\"x\",\"lifecycle\":\"transient\",\"description\":\"d\",\"extra\":1},"
    <> "\"parameters\":{},"
    <> "\"runner\":{\"type\":\"echo\",\"tool_config\":{\"script\":\"echo.py\"},\"noise\":true},"
    <> "\"interface\":{\"protocol\":\"runner\",\"capabilities\":{\"echo\":{\"input_schema\":\"std:chat\",\"streaming\":false,\"noise\":1}},\"extra\":2},"
    <> "\"ignored\":\"ok\""
    <> "}"

  json.parse(payload, decoders.profile_decoder())
  |> should.be_ok

  let invalid_schema =
    "{"
    <> "\"meta\":{\"id\":\"x\",\"lifecycle\":\"transient\",\"description\":\"d\"},"
    <> "\"parameters\":{},"
    <> "\"runner\":{\"type\":\"echo\",\"tool_config\":{\"script\":\"echo.py\"}},"
    <> "\"interface\":{\"protocol\":\"runner\",\"capabilities\":{\"echo\":{\"input_schema\":{\"base\":\"std:files\",\"extra_fields\":{\"mode\":{\"type\":\"string\"}}}}}}"
    <> "}"

  json.parse(invalid_schema, decoders.profile_decoder())
  |> should.be_error
}
