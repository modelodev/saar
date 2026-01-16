import gleam/dict
import gleam/option.{None}
import gleeunit/should
import qcheck
import sad/bridge/interpolator
import sad/types/core as types_core
import sad/types/input as types_input

const test_count: Int = 200

pub fn prop_interpolate_string_without_placeholders_is_identity_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)
  let generator = safe_template_generator()

  qcheck.run(config, generator, fn(template) {
    interpolator.interpolate_string(template, empty_context())
    |> should.equal(Ok(template))
  })
}

pub fn prop_interpolate_dict_without_placeholders_is_identity_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let generator =
    qcheck.generic_dict(
      keys_from: safe_template_generator(),
      values_from: safe_template_generator(),
      size_from: qcheck.bounded_int(0, 5),
    )

  qcheck.run(config, generator, fn(templates) {
    interpolator.interpolate_dict(templates, empty_context())
    |> should.equal(Ok(templates))
  })
}

fn safe_template_generator() -> qcheck.Generator(String) {
  let allowed_chars =
    qcheck.from_weighted_generators(
      #(90, qcheck.alphanumeric_ascii_codepoint()),
      [#(10, qcheck.ascii_whitespace_codepoint())],
    )

  qcheck.generic_string(
    codepoints_from: allowed_chars,
    length_from: qcheck.bounded_int(0, 60),
  )
}

fn empty_context() -> interpolator.InterpContext {
  interpolator.build_context(
    dict.new(),
    types_input.PayloadChat([], dict.new()),
    types_input.RequestContext(
      trace_id: types_core.trace_id("trace-1"),
      extra: dict.new(),
    ),
    None,
    None,
  )
}
