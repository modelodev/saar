import gleam/json
import gleam/string
import gleeunit/should
import qcheck
import sad/adapters/a2a
import sad/adapters/a2ui
import sad/adapters/agui
import sad/sse
import sad/types/core as types_core
import sad/types/stream

const test_count: Int = 200

pub fn prop_agui_sse_line_format_matches_sse_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  qcheck.run(config, qcheck.string(), fn(payload) {
    agui.to_sse_line_format(payload)
    |> should.equal(sse.line(payload))
  })
}

pub fn prop_a2a_sse_line_format_matches_sse_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  qcheck.run(config, qcheck.string(), fn(payload) {
    a2a.to_sse_line_format(payload)
    |> should.equal(sse.line(payload))
  })
}

pub fn prop_a2ui_begin_rendering_payload_matches_json_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  qcheck.run(config, qcheck.string(), fn(raw_trace_id) {
    let trace_id = types_core.trace_id(raw_trace_id)

    let expected =
      trace_id
      |> a2ui.begin_rendering_json
      |> json.to_string
      |> sse.line

    a2ui.begin_rendering(trace_id)
    |> stream.payload
    |> should.equal(expected)
  })
}

pub fn prop_a2ui_data_model_update_payload_matches_json_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let generator = qcheck.tuple2(qcheck.string(), qcheck.string())

  qcheck.run(config, generator, fn(pair) {
    let #(raw_trace_id, delta) = pair
    let trace_id = types_core.trace_id(raw_trace_id)

    let expected =
      a2ui.data_model_update_json(trace_id, delta)
      |> json.to_string
      |> sse.line

    a2ui.data_model_update(trace_id, delta)
    |> stream.payload
    |> should.equal(expected)
  })
}

pub fn prop_trace_id_preserved() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  qcheck.run(config, qcheck.string(), fn(raw_trace_id) {
    let trace_id = types_core.trace_id(raw_trace_id)

    agui.run_started(trace_id)
    |> stream.payload
    |> string.contains(raw_trace_id)
    |> should.equal(True)
  })
}
