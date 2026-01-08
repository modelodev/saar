import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleeunit
import gleeunit/should
import sad/decoders
import sad/types/core as types_core
import sad/types/profile as types_profile
import simplifile

pub fn main() {
  gleeunit.main()
}

pub fn decode_profile_ok_test() {
  let assert Ok(contents) =
    simplifile.read(from: "test/fixtures/source_local/profiles/echo_cli.json")

  let assert Ok(profile) = json.parse(contents, decoders.profile_decoder())

  let types_profile.Profile(meta: meta, ..) = profile
  meta.id
  |> types_core.profile_id_to_string
  |> should.equal("echo_cli")
}

pub fn decode_profile_unknown_fields_ignored_test() {
  let payload =
    "{"
    <> "\"meta\":{\"id\":\"x\",\"lifecycle\":\"transient\",\"description\":\"d\",\"unknown\":1},"
    <> "\"parameters\":{},"
    <> "\"runner\":{\"type\":\"echo\",\"tool_config\":{\"script\":\"echo.py\"},\"extra\":true},"
    <> "\"interface\":{\"protocol\":\"runner\",\"capabilities\":{\"echo\":{\"input_schema\":\"std:chat\",\"streaming\":false,\"extra\":1}},\"other\":2},"
    <> "\"ignored\":\"ok\""
    <> "}"

  json.parse(payload, decoders.profile_decoder())
  |> should.be_ok
}

pub fn decode_network_mode_strict_test() {
  decoders.decode_network_mode(dynamic.string("managed_port"))
  |> should.be_ok

  decoders.decode_network_mode(dynamic.string("no_network"))
  |> should.be_ok

  decoders.decode_network_mode(dynamic.string("host"))
  |> should.be_error

  decoders.decode_network_mode(dynamic.string("MANAGED_PORT"))
  |> should.be_error
}

pub fn decode_input_schema_forms_test() {
  let assert Ok(chat) = json.parse("\"std:chat\"", decode.dynamic)
  let assert Ok(types_profile.SchemaChat) = decoders.decode_input_schema(chat)

  let assert Ok(ref_chat) =
    json.parse("{\"$ref\":\"std:chat\"}", decode.dynamic)
  let assert Ok(types_profile.SchemaChat) =
    decoders.decode_input_schema(ref_chat)

  let assert Ok(extended) =
    json.parse(
      "{\"base\":\"std:chat\",\"extra_fields\":{\"mode\":{\"type\":\"string\"}}}",
      decode.dynamic,
    )

  let assert Ok(types_profile.SchemaChatExtended(extra_fields)) =
    decoders.decode_input_schema(extended)

  dict.has_key(extra_fields, "mode")
  |> should.equal(True)
}

pub fn decode_extra_fields_only_for_std_chat_test() {
  let assert Ok(invalid) =
    json.parse(
      "{\"base\":\"std:files\",\"extra_fields\":{\"mode\":{\"type\":\"string\"}}}",
      decode.dynamic,
    )

  decoders.decode_input_schema(invalid)
  |> should.be_error
}
