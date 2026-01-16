import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/string
import gleeunit
import gleeunit/should
import saar/adapters/a2ui
import saar/types/core as types_core
import saar/types/stream

pub fn main() {
  gleeunit.main()
}

pub fn a2ui_shape_exact() {
  let trace_id = types_core.trace_id("trace-a2ui")

  let begin = a2ui.begin_rendering(trace_id)
  let begin_frame = stream.payload(begin)

  begin_frame
  |> should.equal(
    "data: {\"beginRendering\":{\"surfaceId\":\"trace-a2ui\"}}\n\n",
  )

  assert_one_top_level_key(begin_frame)

  let update = a2ui.data_model_update(trace_id, "delta")
  let update_frame = stream.payload(update)

  update_frame
  |> should.equal(
    "data: {\"dataModelUpdate\":{\"surfaceId\":\"trace-a2ui\",\"delta\":\"delta\"}}\n\n",
  )

  assert_one_top_level_key(update_frame)
}

fn assert_one_top_level_key(frame: String) -> Nil {
  let payload =
    frame
    |> string.replace("data: ", "")
    |> string.trim_end

  let decoder = decode.dict(decode.string, decode.dynamic)
  let assert Ok(obj) = json.parse(payload, decoder)

  dict.size(obj) |> should.equal(1)
  Nil
}
