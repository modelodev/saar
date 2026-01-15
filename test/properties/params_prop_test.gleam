import gleam/int
import gleeunit/should
import qcheck
import sad/types/core as types_core
import sad/types/profile as types_profile
import sad/validation/params as param_validation

const test_count: Int = 200

pub fn prop_parse_literal_int_roundtrip_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  qcheck.run(config, qcheck.uniform_int(), fn(value) {
    let raw = int.to_string(value)

    param_validation.parse_literal(types_profile.ParamInt, raw)
    |> should.equal(Ok(types_core.IntVal(value)))
  })
}

pub fn prop_parse_literal_bool_is_case_insensitive_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let generator = qcheck.tuple2(qcheck.bool(), qcheck.bool())

  qcheck.run(config, generator, fn(pair) {
    let #(value, upper) = pair

    let raw = case value, upper {
      True, True -> "TRUE"
      True, False -> "true"
      False, True -> "FALSE"
      False, False -> "false"
    }

    param_validation.parse_literal(types_profile.ParamBool, raw)
    |> should.equal(Ok(types_core.BoolVal(value)))
  })
}

pub fn prop_ensure_value_type_accepts_matching_values_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let type_generator =
    qcheck.from_generators(qcheck.return(types_profile.ParamString), [
      qcheck.return(types_profile.ParamInt),
      qcheck.return(types_profile.ParamFloat),
      qcheck.return(types_profile.ParamBool),
    ])

  let generator =
    qcheck.bind(type_generator, fn(expected) {
      qcheck.map(value_generator_for(expected), fn(value) { #(expected, value) })
    })

  qcheck.run(config, generator, fn(pair) {
    let #(expected, value) = pair

    param_validation.ensure_value_type(expected, value)
    |> should.equal(Ok(value))
  })
}

fn value_generator_for(
  expected: types_profile.ParamType,
) -> qcheck.Generator(types_core.Value) {
  case expected {
    types_profile.ParamString ->
      qcheck.string() |> qcheck.map(types_core.StringVal)
    types_profile.ParamInt ->
      qcheck.uniform_int() |> qcheck.map(types_core.IntVal)
    types_profile.ParamFloat ->
      qcheck.bounded_float(from: -1000.0, to: 1000.0)
      |> qcheck.map(types_core.FloatVal)
    types_profile.ParamBool -> qcheck.bool() |> qcheck.map(types_core.BoolVal)
  }
}
