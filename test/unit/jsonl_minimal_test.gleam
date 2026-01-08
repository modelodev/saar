import gleeunit
import gleeunit/should
import sad/runner_contract_min
import sad/types/runner as types_runner

pub fn main() {
  gleeunit.main()
}

pub fn jsonl_result_ok_test() {
  let line =
    "{\"t\":\"result\",\"status\":\"success\",\"data\":{},\"artifacts\":[],\"error\":null}"

  case runner_contract_min.decode_runner_event(line) {
    Ok(types_runner.RunnerEventResult(response: response)) -> {
      let types_runner.RunnerResponse(status: status, ..) = response
      status |> should.equal(types_runner.StatusSuccess)
    }
    Ok(_) -> panic as "Expected result event"
    Error(_) -> panic as "Expected Ok result"
  }
}

pub fn jsonl_log_allowed_test() {
  let line = "{\"t\":\"log\",\"message\":\"hello\",\"level\":\"info\"}"

  case runner_contract_min.decode_runner_event(line) {
    Ok(types_runner.RunnerEventLog(message: message, level: level)) -> {
      message |> should.equal("hello")
      level |> should.equal("info")
    }
    Ok(_) -> panic as "Expected log event"
    Error(_) -> panic as "Expected Ok log"
  }
}

pub fn jsonl_unknown_t_rejected_test() {
  let line = "{\"t\":\"chunk\",\"delta\":\"x\"}"

  case runner_contract_min.decode_runner_event(line) {
    Ok(_) -> panic as "Expected error for chunk"
    Error(_) -> Nil
  }
}

pub fn jsonl_invalid_json_rejected_test() {
  let line = "{\"t\":\"result\","

  case runner_contract_min.decode_runner_event(line) {
    Ok(_) -> panic as "Expected error for invalid json"
    Error(_) -> Nil
  }
}
