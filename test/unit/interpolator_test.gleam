import gleam/dict
import gleam/dynamic as dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None}
import gleeunit
import gleeunit/should
import sad/bridge/interpolator
import sad/types
import sad/types/core as types_core
import sad/types/input as types_input

pub fn main() {
  gleeunit.main()
}

fn base_context(params: types.ResolvedParams) -> interpolator.InterpContext {
  context_with_input(params, types_input.PayloadChat([], dict.new()))
}

fn context_with_input(
  params: types.ResolvedParams,
  input: types_input.InputPayload,
) -> interpolator.InterpContext {
  interpolator.InterpContext(
    params: params,
    input: input,
    context: types_input.RequestContext(
      trace_id: types_core.trace_id("trace-1"),
      extra: dict.new(),
    ),
    helpers: None,
    runner_host: None,
    runner_port: None,
  )
}

fn json_to_dynamic(value: json.Json) -> dynamic.Dynamic {
  let assert Ok(dynamic_value) =
    json.to_string(value)
    |> json.parse(using: decode.dynamic)
  dynamic_value
}

fn decode_object(value: dynamic.Dynamic) -> dict.Dict(String, dynamic.Dynamic) {
  let assert Ok(object) =
    decode.run(value, decode.dict(decode.string, decode.dynamic))
  object
}

pub fn interpolate_params_test() {
  let params =
    dict.from_list([
      #("name", types.NormalValue(types_core.StringVal("Ada"))),
    ])

  let ctx = base_context(params)

  interpolator.interpolate_string_strict("hi {{params.name}}", ctx)
  |> should.equal(Ok("hi Ada"))
}

pub fn interpolate_hyphenated_key_test() {
  let params =
    dict.from_list([
      #("api-key", types.NormalValue(types_core.StringVal("token"))),
    ])

  let ctx = base_context(params)

  interpolator.interpolate_string_strict("key={{params.api-key}}", ctx)
  |> should.equal(Ok("key=token"))
}

pub fn interpolate_missing_test() {
  let ctx = base_context(dict.new())

  interpolator.interpolate_string_strict("{{params.missing}}", ctx)
  |> should.equal(Error(interpolator.UnknownKey("params", "missing")))
}

pub fn interpolate_invalid_placeholder_literal_test() {
  let ctx = base_context(dict.new())

  interpolator.interpolate_string_strict("keep {{bad..key}}", ctx)
  |> should.equal(Ok("keep {{bad..key}}"))
}

pub fn interpolate_json_nested_objects_test() {
  let params =
    dict.from_list([
      #("x", types.NormalValue(types_core.StringVal("value"))),
    ])

  let ctx = base_context(params)

  let template =
    json.object([
      #("a", json.object([#("b", json.string("{{params.x}}"))])),
    ])

  let assert Ok(result) = interpolator.interpolate_json(template, ctx)

  result
  |> json.to_string
  |> should.equal("{\"a\":{\"b\":\"value\"}}")
}

pub fn interpolate_json_arrays_test() {
  let params =
    dict.from_list([
      #("a", types.NormalValue(types_core.StringVal("one"))),
      #("b", types.NormalValue(types_core.StringVal("two"))),
    ])

  let ctx = base_context(params)

  let template =
    json.object([
      #(
        "items",
        json.array(["{{params.a}}", "{{params.b}}"], json.string),
      ),
    ])

  let assert Ok(result) = interpolator.interpolate_json(template, ctx)

  result
  |> json.to_string
  |> should.equal("{\"items\":[\"one\",\"two\"]}")
}

pub fn interpolate_json_mixed_types_test() {
  let params =
    dict.from_list([
      #("x", types.NormalValue(types_core.StringVal("ok"))),
    ])

  let ctx = base_context(params)

  let template =
    json.object([
      #("s", json.string("{{params.x}}")),
      #("n", json.int(1)),
      #("b", json.bool(True)),
    ])

  let assert Ok(result) = interpolator.interpolate_json(template, ctx)

  let object = result |> json_to_dynamic |> decode_object

  let assert Ok(value_s) = dict.get(object, "s")
  let assert Ok(value_n) = dict.get(object, "n")
  let assert Ok(value_b) = dict.get(object, "b")

  let assert Ok(text) = decode.run(value_s, decode.string)
  let assert Ok(number) = decode.run(value_n, decode.int)
  let assert Ok(flag) = decode.run(value_b, decode.bool)

  text |> should.equal("ok")
  number |> should.equal(1)
  flag |> should.equal(True)
}

pub fn interpolate_json_preserves_null_test() {
  let ctx = base_context(dict.new())

  let template = json.object([#("value", json.null())])

  let assert Ok(result) = interpolator.interpolate_json(template, ctx)

  result
  |> json.to_string
  |> should.equal("{\"value\":null}")
}

pub fn interpolate_json_preserves_numbers_test() {
  let ctx = base_context(dict.new())

  let template = json.object([#("value", json.int(42))])

  let assert Ok(result) = interpolator.interpolate_json(template, ctx)

  result
  |> json.to_string
  |> should.equal("{\"value\":42}")
}

pub fn interpolate_json_deep_nesting_test() {
  let params =
    dict.from_list([
      #("deep", types.NormalValue(types_core.StringVal("ok"))),
    ])

  let ctx = base_context(params)

  let template =
    json.object([
      #(
        "a",
        json.object([
          #(
            "b",
            json.object([
              #(
                "c",
                json.object([
                  #(
                    "d",
                    json.object([#("e", json.string("{{params.deep}}"))]),
                  ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    ])

  let assert Ok(result) = interpolator.interpolate_json(template, ctx)

  result
  |> json.to_string
  |> should.equal("{\"a\":{\"b\":{\"c\":{\"d\":{\"e\":\"ok\"}}}}}")
}

pub fn interpolate_json_from_pointer_test() {
  let params =
    dict.from_list([
      #("x", types.NormalValue(types_core.StringVal("value"))),
    ])

  let input =
    types_input.PayloadChat(
      [types_input.ChatMessage(role: "user", content: "{{params.x}}")],
      dict.new(),
    )

  let ctx = context_with_input(params, input)

  let template =
    json.object([
      #(
        "messages",
        json.object([#("$from", json.string("/input/messages"))]),
      ),
    ])

  let assert Ok(result) = interpolator.interpolate_json(template, ctx)

  let object = result |> json_to_dynamic |> decode_object
  let assert Ok(messages_value) = dict.get(object, "messages")
  let assert Ok(messages) = decode.run(messages_value, decode.list(of: decode.dynamic))

  case messages {
    [first, .._] -> {
      let message_object = decode_object(first)
      let assert Ok(role_value) = dict.get(message_object, "role")
      let assert Ok(content_value) = dict.get(message_object, "content")
      let assert Ok(role) = decode.run(role_value, decode.string)
      let assert Ok(content) = decode.run(content_value, decode.string)

      role |> should.equal("user")
      content |> should.equal("{{params.x}}")
    }
    _ -> should.fail()
  }
}

pub fn interpolate_json_from_pointer_invalid_test() {
  let ctx = base_context(dict.new())

  let template =
    json.object([
      #(
        "messages",
        json.object([#("$from", json.string("/input/missing"))]),
      ),
    ])

  interpolator.interpolate_json(template, ctx)
  |> should.equal(Error(interpolator.InvalidPointer("/input/missing")))
}
