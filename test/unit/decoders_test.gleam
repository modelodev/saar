import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import sad/decoders
import sad/types/core as types_core
import sad/types/input as types_input
import sad/types/profile as types_profile
import simplifile

pub fn main() {
  gleeunit.main()
}

pub fn describe_dynamic_type_shapes_test() {
  decoders.describe_dynamic_type(dynamic.string("x"))
  |> should.equal("string")

  decoders.describe_dynamic_type(dynamic.bool(True))
  |> should.equal("bool")

  decoders.describe_dynamic_type(dynamic.int(1))
  |> should.equal("number")

  decoders.describe_dynamic_type(dynamic.float(1.0))
  |> should.equal("number")

  decoders.describe_dynamic_type(dynamic.list([dynamic.int(1)]))
  |> should.equal("array")

  decoders.describe_dynamic_type(
    dynamic.properties([#(dynamic.string("k"), dynamic.int(1))]),
  )
  |> should.equal("object")
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

pub fn decode_instance_id_ok_test() {
  let assert Ok(instance_id) =
    decoders.decode_instance_id(dynamic.string("inst-1"))

  types_core.instance_id_to_string(instance_id)
  |> should.equal("inst-1")
}

pub fn decode_instance_id_invalid_test() {
  decoders.decode_instance_id(dynamic.string(""))
  |> should.be_error

  decoders.decode_instance_id(dynamic.string("bad/1"))
  |> should.be_error
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

pub fn decode_payload_chat_ok_test() {
  let assert Ok(contents) =
    simplifile.read(from: "test/fixtures/payloads/chat_simple.json")
  let assert Ok(inputs) = json.parse(contents, decode.dynamic)

  let assert Ok(types_input.PayloadChat(messages, extra)) =
    decoders.decode_payload_std_chat(inputs, dict.new())

  list.length(messages)
  |> should.equal(1)

  dict.size(extra)
  |> should.equal(0)
}

pub fn decode_payload_files_ok_test() {
  let assert Ok(contents) =
    simplifile.read(from: "test/fixtures/payloads/files_single.json")
  let assert Ok(inputs) = json.parse(contents, decode.dynamic)

  let assert Ok(types_input.PayloadFiles(files)) =
    decoders.decode_payload_std_files(inputs)

  list.length(files)
  |> should.equal(1)
}

pub fn decode_payload_mixed_ok_test() {
  let mixed_json =
    "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"files\":[{\"name\":\"doc.txt\",\"url\":\"https://example.com/doc.txt\",\"mime\":\"text/plain\"}]}"

  let assert Ok(inputs) = json.parse(mixed_json, decode.dynamic)

  let assert Ok(types_input.PayloadMixed(messages, files, extra)) =
    decoders.decode_payload_mixed(inputs, dict.new())

  list.length(messages)
  |> should.equal(1)

  list.length(files)
  |> should.equal(1)

  dict.size(extra)
  |> should.equal(0)
}

pub fn decode_extra_field_default_applied_test() {
  let extra_fields =
    dict.from_list([
      #(
        "tone",
        types_profile.ExtraFieldDef(
          type_: types_profile.FieldString,
          enum_values: None,
          default: Some(types_core.StringVal("formal")),
        ),
      ),
    ])

  let inputs_json = "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
  let assert Ok(inputs) = json.parse(inputs_json, decode.dynamic)

  let assert Ok(types_input.PayloadChat(_, extra)) =
    decoders.decode_payload_std_chat(inputs, extra_fields)

  dict.get(extra, "tone")
  |> should.equal(Ok(types_core.StringVal("formal")))
}

pub fn decode_extra_field_required_missing_test() {
  let extra_fields =
    dict.from_list([
      #(
        "tone",
        types_profile.ExtraFieldDef(
          type_: types_profile.FieldString,
          enum_values: None,
          default: None,
        ),
      ),
    ])

  let inputs_json = "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
  let assert Ok(inputs) = json.parse(inputs_json, decode.dynamic)

  decoders.decode_payload_std_chat(inputs, extra_fields)
  |> should.be_error
}

pub fn decode_extra_field_enum_valid_test() {
  let extra_fields =
    dict.from_list([
      #(
        "tone",
        types_profile.ExtraFieldDef(
          type_: types_profile.FieldString,
          enum_values: Some(["formal", "casual"]),
          default: None,
        ),
      ),
    ])

  let inputs_json =
    "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"tone\":\"formal\"}"
  let assert Ok(inputs) = json.parse(inputs_json, decode.dynamic)

  let assert Ok(types_input.PayloadChat(_, extra)) =
    decoders.decode_payload_std_chat(inputs, extra_fields)

  dict.get(extra, "tone")
  |> should.equal(Ok(types_core.StringVal("formal")))
}

pub fn decode_extra_fields_unknown_ignored_test() {
  let extra_fields =
    dict.from_list([
      #(
        "tone",
        types_profile.ExtraFieldDef(
          type_: types_profile.FieldString,
          enum_values: None,
          default: Some(types_core.StringVal("formal")),
        ),
      ),
    ])

  let inputs_json =
    "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"unknown\":\"x\"}"
  let assert Ok(inputs) = json.parse(inputs_json, decode.dynamic)

  let assert Ok(types_input.PayloadChat(_, extra)) =
    decoders.decode_payload_std_chat(inputs, extra_fields)

  dict.has_key(extra, "unknown")
  |> should.equal(False)
}
