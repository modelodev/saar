import gleam/dict
import gleam/option
import gleeunit
import gleeunit/should
import sad/core/agent_lifecycle as lifecycle
import sad/types/agent as types_agent

pub fn main() {
  gleeunit.main()
}

pub fn start_instance_transitions() {
  let params = dict.new()

  let created = lifecycle.agent_created(params)
  let next_created = lifecycle.on_start_instance(created)
  lifecycle.is_provisioning(next_created) |> should.equal(True)

  let stopped = lifecycle.agent_stopped(params)
  let next_stopped = lifecycle.on_start_instance(stopped)
  lifecycle.is_provisioning(next_stopped) |> should.equal(True)

  let provisioning = lifecycle.agent_provisioning(params)
  let next_provisioning = lifecycle.on_start_instance(provisioning)
  lifecycle.is_provisioning(next_provisioning) |> should.equal(True)
}

pub fn provisioning_outcome_success() {
  let params = dict.new()
  let ready = lifecycle.agent_ready_transient(params)

  let #(next_state, assigned_port) =
    lifecycle.on_provisioning_done(Ok(#(ready, option.None)))

  lifecycle.is_ready_transient(next_state) |> should.equal(True)
  assigned_port |> should.equal(option.None)
}

pub fn provisioning_outcome_failure() {
  let #(next_state, assigned_port) =
    lifecycle.on_provisioning_done(Error(types_agent.NoNetwork))

  lifecycle.is_failed(next_state) |> should.equal(True)
  lifecycle.get_failure_reason(next_state)
  |> should.equal(option.Some(types_agent.NoNetwork))
  assigned_port |> should.equal(option.None)
}

pub fn can_interact_when_ready() {
  let params = dict.new()
  let ready = lifecycle.agent_ready_transient(params)

  case lifecycle.can_interact(ready) {
    lifecycle.Allow(returned) -> returned |> should.equal(params)
    _ -> panic as "expected Allow"
  }
}

pub fn can_interact_rejects_not_ready() {
  let params = dict.new()
  let created = lifecycle.agent_created(params)

  case lifecycle.can_interact(created) {
    lifecycle.RejectNotReady -> Nil
    _ -> panic as "expected RejectNotReady"
  }
}

pub fn stop_instance_non_continuous() {
  let params = dict.new()
  let ready = lifecycle.agent_ready_transient(params)

  let lifecycle.StopDecision(
    next_state: next_state,
    resource_to_stop: resource_to_stop,
  ) = lifecycle.on_stop_instance(ready)

  lifecycle.is_stopped(next_state) |> should.equal(True)
  resource_to_stop |> should.equal(option.None)
}

pub fn server_died_sets_failed() {
  let next_state = lifecycle.on_server_died()

  lifecycle.get_failure_reason(next_state)
  |> should.equal(option.Some(types_agent.ServerDied))
}
