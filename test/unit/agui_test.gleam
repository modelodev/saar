import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should
import saar/adapters/agui
import saar/types/core as types_core
import saar/types/enums as types_enums
import saar/types/output as types_output
import saar/types/stream

pub fn main() {
  gleeunit.main()
}

pub fn convert_stream_started() {
  let trace_id = types_core.trace_id("trace-1")
  let state0 = agui.new()

  let #(state1, events) = agui.convert(state0, agui.StreamStarted(trace_id))

  state1 |> should.equal(state0)
  list.length(events) |> should.equal(1)

  let assert Ok(first) = list.first(events)
  stream.payload(first)
  |> should.equal(
    "data: {\"type\":\"RUN_STARTED\",\"threadId\":\"trace-1\",\"runId\":\"trace-1\"}\n\n",
  )
}

pub fn convert_first_content_chunk() {
  let state0 = agui.new()
  let #(state1, events) = agui.convert(state0, agui.ContentChunk("hi"))

  case state1 {
    agui.AgUiState(phase: agui.InMessage("msg-1"), ..) ->
      should.equal(True, True)
    _ -> should.equal(True, False)
  }

  list.length(events) |> should.equal(2)

  let assert [start, content] = events

  stream.payload(start)
  |> should.equal(
    "data: {\"type\":\"TEXT_MESSAGE_START\",\"messageId\":\"msg-1\",\"role\":\"assistant\"}\n\n",
  )

  stream.payload(content)
  |> should.equal(
    "data: {\"type\":\"TEXT_MESSAGE_CONTENT\",\"messageId\":\"msg-1\",\"delta\":\"hi\"}\n\n",
  )
}

pub fn convert_subsequent_chunk() {
  let state0 = agui.new()
  let #(state1, _events1) = agui.convert(state0, agui.ContentChunk("a"))

  let #(_state2, events2) = agui.convert(state1, agui.ContentChunk("b"))

  list.length(events2) |> should.equal(1)

  let assert Ok(content) = list.first(events2)
  stream.payload(content)
  |> should.equal(
    "data: {\"type\":\"TEXT_MESSAGE_CONTENT\",\"messageId\":\"msg-1\",\"delta\":\"b\"}\n\n",
  )
}

pub fn convert_stream_finished() {
  let trace_id = types_core.trace_id("trace-abc")

  let state0 = agui.new()
  let #(state1, _events1) = agui.convert(state0, agui.ContentChunk("hello"))

  let #(state2, events2) =
    agui.convert(state1, agui.StreamFinished(trace_id, []))

  case state2 {
    agui.AgUiState(phase: agui.BeforeFirstChunk, ..) -> should.equal(True, True)
    _ -> should.equal(True, False)
  }

  list.length(events2) |> should.equal(2)

  let assert [end_, finished] = events2

  stream.payload(end_)
  |> should.equal(
    "data: {\"type\":\"TEXT_MESSAGE_END\",\"messageId\":\"msg-1\"}\n\n",
  )

  stream.payload(finished)
  |> should.equal(
    "data: {\"type\":\"RUN_FINISHED\",\"threadId\":\"trace-abc\",\"runId\":\"trace-abc\",\"artifacts\":[]}\n\n",
  )
}

pub fn convert_stream_error() {
  let trace_id = types_core.trace_id("trace-err")
  let err =
    types_output.InteractionError(
      kind: types_enums.InfraError,
      message: "Runner exited with code 1",
      trace_id: trace_id,
    )

  let state0 = agui.new()
  let #(_state1, events) = agui.convert(state0, agui.StreamError(err))

  list.length(events) |> should.equal(1)

  let assert Ok(first) = list.first(events)
  stream.payload(first)
  |> should.equal(
    "data: {\"type\":\"RUN_ERROR\",\"threadId\":\"trace-err\",\"runId\":\"trace-err\",\"error\":{\"kind\":\"infra_error\",\"message\":\"Runner exited with code 1\",\"trace_id\":\"trace-err\"}}\n\n",
  )
}

pub fn to_sse_line_format() {
  agui.to_sse_line_format("{\"x\":1}")
  |> should.equal("data: {\"x\":1}\n\n")
}

pub fn agui_sse_success_payload_exact() {
  let trace_id = types_core.trace_id("trace-abc")

  let artifact =
    types_output.PublicArtifact(
      id: types_core.artifact_id("01J..."),
      name: "report.pdf",
      url: None,
      mime: "application/pdf",
    )

  let state0 = agui.new()
  let #(_state1, started) = agui.convert(state0, agui.StreamStarted(trace_id))
  let #(state2, chunked) =
    agui.convert(state0, agui.ContentChunk("partial chunk"))
  let #(_state3, finished) =
    agui.convert(state2, agui.StreamFinished(trace_id, [artifact]))

  let actual =
    started
    |> list.append(chunked)
    |> list.append(finished)
    |> list.map(stream.payload)
    |> string.join("")

  let expected =
    "data: {\"type\":\"RUN_STARTED\",\"threadId\":\"trace-abc\",\"runId\":\"trace-abc\"}\n\n"
    <> "data: {\"type\":\"TEXT_MESSAGE_START\",\"messageId\":\"msg-1\",\"role\":\"assistant\"}\n\n"
    <> "data: {\"type\":\"TEXT_MESSAGE_CONTENT\",\"messageId\":\"msg-1\",\"delta\":\"partial chunk\"}\n\n"
    <> "data: {\"type\":\"TEXT_MESSAGE_END\",\"messageId\":\"msg-1\"}\n\n"
    <> "data: {\"type\":\"RUN_FINISHED\",\"threadId\":\"trace-abc\",\"runId\":\"trace-abc\",\"artifacts\":[{\"id\":\"01J...\",\"name\":\"report.pdf\",\"url\":null,\"mime\":\"application/pdf\"}]}\n\n"

  actual |> should.equal(expected)
}

pub fn agui_sse_error_payload_exact() {
  let trace_id = types_core.trace_id("trace-abc")
  let err =
    types_output.InteractionError(
      kind: types_enums.InfraError,
      message: "Runner exited with code 1",
      trace_id: trace_id,
    )

  let state0 = agui.new()
  let #(_state1, events) = agui.convert(state0, agui.StreamError(err))

  let actual = events |> list.map(stream.payload) |> string.join("")

  let expected =
    "data: {\"type\":\"RUN_ERROR\",\"threadId\":\"trace-abc\",\"runId\":\"trace-abc\",\"error\":{\"kind\":\"infra_error\",\"message\":\"Runner exited with code 1\",\"trace_id\":\"trace-abc\"}}\n\n"

  actual |> should.equal(expected)
}
