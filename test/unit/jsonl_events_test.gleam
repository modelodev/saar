import gleam/json
import gleam/list
import gleam/option.{None}
import gleeunit
import gleeunit/should
import sad/bridge/runner_contract
import sad/types/runner as types_runner

pub fn main() {
  gleeunit.main()
}

pub fn jsonl_sequence_logs_chunks_result_ok() {
  let lines = [
    json.object([
      #("t", json.string("log")),
      #("level", json.string("info")),
      #("message", json.string("hello")),
    ])
      |> json.to_string,
    json.object([
      #("t", json.string("chunk")),
      #("delta", json.string("hi")),
    ])
      |> json.to_string,
    json.object([
      #("t", json.string("result")),
      #("status", json.string("success")),
      #("data", json.object([])),
    ])
      |> json.to_string,
  ]

  let events =
    lines
    |> list.map(fn(line) {
      let assert Ok(event) = runner_contract.decode_event(line)
      event
    })

  runner_contract.validate_sequence(events, True)
  |> should.equal(Ok(Nil))
}

pub fn jsonl_invalid_json_line() {
  runner_contract.decode_event("{bad json")
  |> should.be_error
  Nil
}

pub fn jsonl_two_results_rejected() {
  let result_event =
    types_runner.RunnerEventResult(
      response: types_runner.RunnerSuccess(data: None, artifacts: []),
    )

  runner_contract.validate_sequence([result_event, result_event], True)
  |> should.equal(Error(runner_contract.DuplicateResult))
}

pub fn jsonl_chunk_without_streaming_rejected() {
  let chunk_event = types_runner.RunnerEventChunk(delta: "x")

  let result_event =
    types_runner.RunnerEventResult(
      response: types_runner.RunnerSuccess(data: None, artifacts: []),
    )

  runner_contract.validate_sequence([chunk_event, result_event], False)
  |> should.equal(Error(runner_contract.ChunkWithoutStreaming))
}
