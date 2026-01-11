import gleeunit
import gleeunit/should
import sad/bridge/runner_contract
import sad/types/runner as types_runner

pub fn main() {
  gleeunit.main()
}

pub fn jsonl_result_ok_test() {
  let line =
    "{\"t\":\"result\",\"status\":\"success\",\"data\":{},\"artifacts\":[],\"error\":null}"

  case runner_contract.decode_event(line) {
    Ok(types_runner.RunnerEventResult(response: response)) -> {
      case response {
        types_runner.RunnerSuccess(..) -> Nil
        types_runner.RunnerFailure(..) -> panic as "Expected success result"
      }
    }
    Ok(_) -> panic as "Expected result event"
    Error(_) -> panic as "Expected Ok result"
  }
}

pub fn jsonl_log_allowed_test() {
  let line = "{\"t\":\"log\",\"message\":\"hello\",\"level\":\"info\"}"

  case runner_contract.decode_event(line) {
    Ok(types_runner.RunnerEventLog(message: message, level: level)) -> {
      message |> should.equal("hello")
      level |> should.equal("info")
    }
    Ok(_) -> panic as "Expected log event"
    Error(_) -> panic as "Expected Ok log"
  }
}

pub fn jsonl_unknown_t_rejected_test() {
  let line = "{\"t\":\"nope\"}"

  case runner_contract.decode_event(line) {
    Ok(_) -> panic as "Expected error for unknown event"
    Error(_) -> Nil
  }
}

pub fn jsonl_invalid_json_rejected_test() {
  let line = "{\"t\":\"result\","

  case runner_contract.decode_event(line) {
    Ok(_) -> panic as "Expected error for invalid json"
    Error(_) -> Nil
  }
}
