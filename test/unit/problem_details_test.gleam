import gleam/bit_array
import gleam/bytes_tree
import gleam/http/response
import gleam/string
import gleeunit
import gleeunit/should
import mist
import sad/gateway/problem
import sad/otp/safe_call
import sad/types/core as types_core
import sad/types/enums as types_enums
import test_assertions

pub fn main() {
  gleeunit.main()
}

pub fn bad_request_maps_to_400_test() {
  let trace_id = types_core.trace_id("trace-400")
  let resp =
    problem.from_error_kind(types_enums.BadRequest, trace_id, "/x", "bad")
  response_status(resp) |> should.equal(400)
  assert_problem_kind(resp, "bad_request")
}

pub fn agent_error_maps_to_422_test() {
  let trace_id = types_core.trace_id("trace-422")
  let resp =
    problem.from_error_kind(types_enums.AgentError, trace_id, "/x", "agent")
  response_status(resp) |> should.equal(422)
  assert_problem_kind(resp, "agent_error")
}

pub fn infra_error_maps_to_500_test() {
  let trace_id = types_core.trace_id("trace-500")
  let resp =
    problem.from_error_kind(types_enums.InfraError, trace_id, "/x", "infra")
  response_status(resp) |> should.equal(500)
  assert_problem_kind(resp, "infra_error")
}

pub fn call_error_disconnected_maps_to_503_test() {
  let trace_id = types_core.trace_id("trace-503")
  let resp = problem.from_call_error(safe_call.Disconnected, trace_id, "/x")
  response_status(resp) |> should.equal(503)
  assert_problem_kind(resp, "infra_error")
}

pub fn call_error_timeout_maps_to_504_test() {
  let trace_id = types_core.trace_id("trace-504")
  let resp = problem.from_call_error(safe_call.TimedOut, trace_id, "/x")
  response_status(resp) |> should.equal(504)
  assert_problem_kind(resp, "infra_error")
}

fn response_status(resp: response.Response(mist.ResponseData)) -> Int {
  let response.Response(status: status, ..) = resp
  status
}

fn assert_problem_kind(
  resp: response.Response(mist.ResponseData),
  expected: String,
) -> Nil {
  let body = response_body_string(resp)

  string.contains(body, "\"kind\":\"" <> expected <> "\"")
  |> should.equal(True)

  Nil
}

fn response_body_string(resp: response.Response(mist.ResponseData)) -> String {
  let response.Response(body: body, ..) = resp

  case body {
    mist.Bytes(tree) ->
      tree
      |> bytes_tree.to_bit_array
      |> bit_array.to_string
      |> test_assertions.assert_ok

    _ -> panic as "Expected mist.Bytes body"
  }
}
