import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import sad/core/provisioning_policy
import sad/port_pool
import sad/types/agent as types_agent

pub fn main() {
  gleeunit.main()
}

pub fn failure_reason_to_string_is_stable_test() {
  types_agent.failure_reason_to_string(types_agent.PortInUse)
  |> should.equal("port_in_use")

  types_agent.failure_reason_to_string(types_agent.PortBindFailed)
  |> should.equal("port_bind_failed")

  types_agent.failure_reason_to_string(types_agent.PortPoolExhausted)
  |> should.equal("port_pool_exhausted")

  types_agent.failure_reason_to_string(types_agent.StartServerFailed)
  |> should.equal("start_server_failed")

  types_agent.failure_reason_to_string(types_agent.StartSnapshotFailed)
  |> should.equal("start_snapshot_failed")

  types_agent.failure_reason_to_string(types_agent.ServerDied)
  |> should.equal("server_died")

  types_agent.failure_reason_to_string(types_agent.AgentDown)
  |> should.equal("agent_down")

  types_agent.failure_reason_to_string(types_agent.NoNetwork)
  |> should.equal("no_network")

  types_agent.failure_reason_to_string(types_agent.LandlockUnavailable)
  |> should.equal("landlock_unavailable")

  types_agent.failure_reason_to_string(types_agent.Unknown)
  |> should.equal("unknown")
}

pub fn classifies_port_pool_errors_test() {
  provisioning_policy.from_port_pool_error(port_pool.PoolExhausted)
  |> should.equal(types_agent.PortPoolExhausted)

  provisioning_policy.from_port_pool_error(port_pool.PortInUse)
  |> should.equal(types_agent.PortInUse)

  provisioning_policy.from_port_pool_error(port_pool.BindCheckFailed("x"))
  |> should.equal(types_agent.PortBindFailed)

  provisioning_policy.from_port_pool_error(port_pool.BindCheckInvalidHost(
    host: "x",
  ))
  |> should.equal(types_agent.PortBindFailed)

  provisioning_policy.from_port_pool_error(port_pool.BindCheckPermissionDenied)
  |> should.equal(types_agent.PortBindFailed)

  provisioning_policy.from_port_pool_error(port_pool.InvalidRange)
  |> should.equal(types_agent.PortBindFailed)

  provisioning_policy.from_port_pool_error(
    port_pool.NoAvailablePortAfterRetries(3),
  )
  |> should.equal(types_agent.PortPoolExhausted)
}

pub fn classifies_port_owner_start_reason_test() {
  provisioning_policy.from_port_owner_start_reason("LANDLOCK_UNAVAILABLE")
  |> should.equal(types_agent.LandlockUnavailable)

  provisioning_policy.from_port_owner_start_reason("CheckPortInUse")
  |> should.equal(types_agent.PortInUse)

  provisioning_policy.from_port_owner_start_reason("Managed port check failed")
  |> should.equal(types_agent.PortBindFailed)

  // Prefer "landlock" when multiple signals exist.
  provisioning_policy.from_port_owner_start_reason(
    "LANDLOCK_UNAVAILABLE; CheckPortInUse; Managed port check failed",
  )
  |> should.equal(types_agent.LandlockUnavailable)

  // Otherwise keep previous precedence.
  provisioning_policy.from_port_owner_start_reason(
    "CheckPortInUse; Managed port check failed",
  )
  |> should.equal(types_agent.PortInUse)

  provisioning_policy.from_port_owner_start_reason("something else")
  |> should.equal(types_agent.StartServerFailed)
}

pub fn retry_step_retries_only_expected_failures_test() {
  // Retry for PortInUse
  provisioning_policy.retry_step(Error(types_agent.PortInUse), 3)
  |> should.equal(provisioning_policy.Retry(
    remaining: 2,
    last_failure: Some(types_agent.PortInUse),
  ))

  // Retry for PortBindFailed
  provisioning_policy.retry_step(Error(types_agent.PortBindFailed), 2)
  |> should.equal(provisioning_policy.Retry(
    remaining: 1,
    last_failure: Some(types_agent.PortBindFailed),
  ))

  // Do not retry for PoolExhausted
  provisioning_policy.retry_step(Error(types_agent.PortPoolExhausted), 3)
  |> should.equal(
    provisioning_policy.Done(Error(types_agent.PortPoolExhausted)),
  )

  // Do not retry for StartServerFailed
  provisioning_policy.retry_step(Error(types_agent.StartServerFailed), 3)
  |> should.equal(
    provisioning_policy.Done(Error(types_agent.StartServerFailed)),
  )
}

pub fn retry_step_reports_last_failure_on_exhaustion_test() {
  // If we tracked a last failure, report it when attempts are exhausted.
  provisioning_policy.retry_step_with_last(
    Error(types_agent.PortBindFailed),
    1,
    Some(types_agent.PortInUse),
  )
  |> should.equal(provisioning_policy.Done(Error(types_agent.PortInUse)))

  // Otherwise report a stable default on exhaustion.
  provisioning_policy.retry_step_with_last(
    Error(types_agent.PortInUse),
    1,
    None,
  )
  |> should.equal(provisioning_policy.Done(Error(types_agent.PortBindFailed)))
}
