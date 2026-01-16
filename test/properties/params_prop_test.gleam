import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import qcheck
import saar/params
import saar/types/core as types_core
import saar/types/profile as types_profile
import saar/types/resolved_params
import saar/validation/params as param_validation

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

pub fn prop_fixed_always_same() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let generator = qcheck.tuple2(qcheck.string(), qcheck.uniform_int())

  qcheck.run(config, generator, fn(pair) {
    let #(name, value) = pair

    let parameters = dict.from_list([#(name, fixed_int_param(value))])

    let resolved = resolve_params(parameters)
    let assert Ok(resolved) = resolved

    let assert Ok(resolved_params.NormalValue(types_core.IntVal(got))) =
      dict.get(resolved, name)

    got |> should.equal(value)
  })
}

pub fn prop_missing_sources_produce_error() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let generator = qcheck.tuple2(qcheck.string(), qcheck.string())

  qcheck.run(config, generator, fn(pair) {
    let #(name, key) = pair

    let parameters =
      dict.from_list([
        #(name, types_profile.ConfigParam(key, None, types_profile.ParamString)),
      ])

    resolve_params(parameters)
    |> should.equal(Error([params.MissingConfig(name, key)]))
  })
}

pub fn prop_resolved_keys_match_input() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let generator =
    qcheck.generic_dict(
      keys_from: qcheck.string(),
      values_from: qcheck.uniform_int(),
      size_from: qcheck.bounded_int(0, 5),
    )

  qcheck.run(config, generator, fn(values) {
    let parameters = fixed_int_parameters(values)

    let assert Ok(resolved) = resolve_params(parameters)

    let expected_keys = dict.keys(parameters) |> list.sort(string.compare)
    let got_keys = dict.keys(resolved) |> list.sort(string.compare)

    got_keys |> should.equal(expected_keys)
  })
}

fn resolve_params(
  parameters: dict.Dict(String, types_profile.Parameter),
) -> Result(
  dict.Dict(String, resolved_params.ResolvedValue),
  List(params.ParamResolutionError),
) {
  params.resolve_params(parameters, dict.new(), env_lookup_none, dict.new())
}

fn env_lookup_none(_key: String) -> Result(String, Nil) {
  Error(Nil)
}

fn fixed_int_param(value: Int) -> types_profile.Parameter {
  types_profile.FixedParam(types_core.IntVal(value))
}

fn fixed_int_parameters(
  values: dict.Dict(String, Int),
) -> dict.Dict(String, types_profile.Parameter) {
  values
  |> dict.to_list
  |> list.fold(dict.new(), fn(acc, entry) {
    let #(key, value) = entry
    dict.insert(acc, key, fixed_int_param(value))
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
