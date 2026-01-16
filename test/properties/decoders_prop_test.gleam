import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import qcheck
import sad/decoders
import sad/types/core as types_core
import sad/types/profile as types_profile

const test_count: Int = 200

pub fn prop_describe_dynamic_type_string_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  qcheck.run(config, qcheck.string(), fn(text) {
    decoders.describe_dynamic_type(dynamic.string(text))
    |> should.equal("string")
  })
}

pub fn prop_describe_dynamic_type_int_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  qcheck.run(config, qcheck.uniform_int(), fn(value) {
    decoders.describe_dynamic_type(dynamic.int(value))
    |> should.equal("number")
  })
}

pub fn prop_decode_scalar_value_int_roundtrip_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  qcheck.run(config, qcheck.uniform_int(), fn(value) {
    decoders.decode_scalar_value(dynamic.int(value))
    |> should.equal(Ok(types_core.IntVal(value)))
  })
}

pub fn prop_decode_scalar_value_rejects_arrays_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let generator =
    qcheck.generic_list(qcheck.uniform_int(), qcheck.bounded_int(0, 5))

  qcheck.run(config, generator, fn(values) {
    let items = values |> list.map(dynamic.int)

    decoders.decode_scalar_value(dynamic.list(items))
    |> should.equal(Error(Nil))
  })
}

pub fn prop_extra_fields_ignored() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  qcheck.run(config, qcheck.uniform_int(), fn(extra_value) {
    let payload = profile_payload_with_unknown(extra_value) |> json.to_string
    let assert Ok(value) = json.parse(payload, decode.dynamic)

    decoders.decode_profile(value) |> should.be_ok
    Nil
  })
}

pub fn prop_parameter_keys_preserved() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let generator =
    qcheck.generic_dict(
      keys_from: qcheck.string(),
      values_from: qcheck.uniform_int(),
      size_from: qcheck.bounded_int(0, 5),
    )

  qcheck.run(config, generator, fn(params_values) {
    let params_entries =
      params_values
      |> dict.to_list
      |> list.map(fn(entry) {
        let #(key, value) = entry
        #(key, fixed_int_param_json(value))
      })

    let payload =
      profile_payload_with_parameters(params_entries) |> json.to_string
    let assert Ok(value) = json.parse(payload, decode.dynamic)

    let profile = decoders.decode_profile(value) |> should.be_ok
    let types_profile.Profile(parameters: decoded, ..) = profile

    let expected = dict.keys(params_values) |> list.sort(string.compare)
    let got = dict.keys(decoded) |> list.sort(string.compare)

    got |> should.equal(expected)
  })
}

pub fn prop_http_method_roundtrip() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let method_generator =
    qcheck.from_generators(qcheck.return(types_profile.HttpGet), [
      qcheck.return(types_profile.HttpPost),
      qcheck.return(types_profile.HttpPut),
      qcheck.return(types_profile.HttpDelete),
    ])

  let generator = qcheck.tuple2(method_generator, qcheck.bool())

  qcheck.run(config, generator, fn(pair) {
    let #(method, uppercase) = pair

    let raw = case method {
      types_profile.HttpGet -> "get"
      types_profile.HttpPost -> "post"
      types_profile.HttpPut -> "put"
      types_profile.HttpDelete -> "delete"
    }

    let raw = case uppercase {
      True -> string.uppercase(raw)
      False -> raw
    }

    let payload = http_interface_payload(raw)
    let assert Ok(value) = json.parse(payload, decode.dynamic)

    let interface = decoders.decode_interface(value) |> should.be_ok

    case interface {
      types_profile.HttpInterface(capabilities: caps, ..) -> {
        let assert Ok(types_profile.HttpCapability(method: decoded, ..)) =
          dict.get(caps, "c")

        decoded |> should.equal(method)
      }

      _ -> should.fail()
    }
  })
}

fn profile_payload_with_unknown(extra_value: Int) -> json.Json {
  json.object([
    #(
      "meta",
      json.object([
        #("id", json.string("x")),
        #("lifecycle", json.string("transient")),
        #("description", json.string("d")),
        #("unknown", json.int(extra_value)),
      ]),
    ),
    #("parameters", json.object([])),
    #(
      "runner",
      json.object([
        #("type", json.string("echo")),
        #("tool_config", json.object([#("script", json.string("echo.py"))])),
        #("extra", json.bool(True)),
      ]),
    ),
    #(
      "interface",
      json.object([
        #("protocol", json.string("runner")),
        #("capabilities", json.object([])),
        #("other", json.int(extra_value)),
      ]),
    ),
    #("ignored", json.string("ok")),
  ])
}

fn profile_payload_with_parameters(
  parameter_entries: List(#(String, json.Json)),
) -> json.Json {
  json.object([
    #(
      "meta",
      json.object([
        #("id", json.string("x")),
        #("lifecycle", json.string("transient")),
        #("description", json.string("d")),
      ]),
    ),
    #("parameters", json.object(parameter_entries)),
    #(
      "runner",
      json.object([
        #("type", json.string("echo_cli")),
        #("tool_config", json.object([#("script", json.string("echo_cli.py"))])),
      ]),
    ),
    #(
      "interface",
      json.object([
        #("protocol", json.string("runner")),
        #(
          "capabilities",
          json.object([
            #(
              "echo",
              json.object([
                #("input_schema", json.string("std:chat")),
                #("streaming", json.bool(False)),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  ])
}

fn fixed_int_param_json(value: Int) -> json.Json {
  json.object([
    #("source", json.string("fixed")),
    #("value", json.int(value)),
    #("type", json.string("int")),
  ])
}

fn http_interface_payload(method: String) -> String {
  json.object([
    #("protocol", json.string("http")),
    #("base_url", json.string("http://example")),
    #(
      "capabilities",
      json.object([
        #(
          "c",
          json.object([
            #("path", json.string("/p")),
            #("method", json.string(method)),
          ]),
        ),
      ]),
    ),
  ])
  |> json.to_string
}
