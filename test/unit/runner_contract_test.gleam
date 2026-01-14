import gleam/json
import gleam/option
import gleeunit
import gleeunit/should
import sad/bridge/runner_contract
import sad/types/runner as types_runner

pub fn main() {
  gleeunit.main()
}

pub fn rejects_double_result_test() {
  let events = [success_result(), success_result()]

  runner_contract.validate_sequence(events, True)
  |> should.equal(Error(runner_contract.DuplicateResult))
}

pub fn rejects_chunk_when_streaming_false_test() {
  let events = [
    types_runner.RunnerEventChunk(delta: "hi"),
    success_result(),
  ]

  runner_contract.validate_sequence(events, False)
  |> should.equal(Error(runner_contract.ChunkWithoutStreaming))
}

pub fn rejects_unknown_t_test() {
  runner_contract.decode_event("{\"t\":\"nope\"}")
  |> should.equal(Error(runner_contract.UnknownEvent("nope")))
}

pub fn allows_log_after_result_test() {
  let events = [
    success_result(),
    types_runner.RunnerEventLog(message: "late", level: "info"),
  ]

  runner_contract.validate_sequence(events, True)
  |> should.equal(Ok(Nil))
}

pub fn allows_result_first_test() {
  let events = [
    success_result(),
    types_runner.RunnerEventLog(message: "later", level: "info"),
  ]

  runner_contract.validate_sequence(events, True)
  |> should.equal(Ok(Nil))
}

pub fn decodes_object_data_test() {
  runner_contract.decode_event(
    "{\"t\":\"result\",\"status\":\"success\",\"data\":{},\"artifacts\":[]}",
  )
  |> should.equal(
    Ok(
      types_runner.RunnerEventResult(
        response: types_runner.RunnerSuccess(
          data: option.Some(json.object([])),
          artifacts: [],
        ),
      ),
    ),
  )
}

fn success_result() -> types_runner.RunnerEvent {
  types_runner.RunnerEventResult(
    response: types_runner.RunnerSuccess(data: option.None, artifacts: []),
  )
}
