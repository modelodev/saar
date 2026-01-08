import gleam/dict
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
  interpolator.InterpContext(
    params: params,
    input: types_input.PayloadChat([], dict.new()),
    context: types_input.RequestContext(
      trace_id: types_core.trace_id("trace-1"),
      extra: dict.new(),
    ),
    helpers: None,
    runner_host: None,
    runner_port: None,
  )
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
