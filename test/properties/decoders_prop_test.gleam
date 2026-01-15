import gleam/dynamic
import gleam/list
import gleeunit/should
import qcheck
import sad/decoders
import sad/types/core as types_core

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
