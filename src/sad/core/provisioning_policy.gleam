//// Provisioning policy and failure classification.
////
//// Mission: keep managed-port provisioning behavior stable, explicit, and easy to test.
////
//// Responsibilities:
//// - Classify low-level errors (port pool / port owner) into `types_agent.FailureReason`.
//// - Decide retry behavior for managed-port provisioning.
////
//// Non-responsibilities:
//// - Performing IO (starting processes, HTTP health checks, filesystem changes).
//// - Updating core actors (registry/agent).
////
//// Relationships:
//// - Used by `sad/core/agent_manager` provisioning flow.
//// - Consumed by unit tests to cover edge cases.

import gleam/option
import gleam/string
import sad/port_pool
import sad/types/agent as types_agent

pub type RetryDecision(a) {
  Done(Result(a, types_agent.FailureReason))
  Retry(remaining: Int, last_failure: option.Option(types_agent.FailureReason))
}

/// Returns `True` when a provisioning failure should be retried.
pub fn should_retry(reason: types_agent.FailureReason) -> Bool {
  case reason {
    types_agent.PortInUse -> True
    types_agent.PortBindFailed -> True
    _ -> False
  }
}

/// Computes the next retry decision for a provisioning attempt.
///
/// The caller is responsible for performing the next attempt when `Retry`.
pub fn retry_step(
  a: Result(a, types_agent.FailureReason),
  remaining: Int,
) -> RetryDecision(a) {
  retry_step_with_last(a, remaining, option.None)
}

/// Like `retry_step/2`, but retains the last failure to report on exhaustion.
pub fn retry_step_with_last(
  attempt: Result(a, types_agent.FailureReason),
  remaining: Int,
  last_failure: option.Option(types_agent.FailureReason),
) -> RetryDecision(a) {
  case attempt {
    Ok(value) -> Done(Ok(value))

    Error(reason) ->
      case remaining <= 1 {
        True -> Done(Error(final_failure(reason, last_failure)))

        False ->
          case should_retry(reason) {
            True -> Retry(remaining - 1, option.Some(reason))
            False -> Done(Error(reason))
          }
      }
  }
}

fn final_failure(
  _current: types_agent.FailureReason,
  last: option.Option(types_agent.FailureReason),
) -> types_agent.FailureReason {
  case last {
    option.Some(reason) -> reason
    option.None -> types_agent.PortBindFailed
  }
}

/// Classifies port pool allocation errors.
pub fn from_port_pool_error(
  err: port_pool.PortPoolError,
) -> types_agent.FailureReason {
  case err {
    port_pool.PoolExhausted -> types_agent.PortPoolExhausted
    port_pool.PortInUse -> types_agent.PortInUse
    port_pool.BindCheckFailed(_) -> types_agent.PortBindFailed
    port_pool.NoAvailablePortAfterRetries(_) -> types_agent.PortPoolExhausted
    _ -> types_agent.PortBindFailed
  }
}

/// Classifies port owner init failure reasons.
///
/// This parses stable, wrapper-generated substrings.
pub fn from_port_owner_start_reason(reason: String) -> types_agent.FailureReason {
  case string.contains(reason, "LANDLOCK_UNAVAILABLE") {
    True -> types_agent.LandlockUnavailable

    False ->
      case string.contains(reason, "CheckPortInUse") {
        True -> types_agent.PortInUse

        False ->
          case string.contains(reason, "Managed port check failed") {
            True -> types_agent.PortBindFailed
            False -> types_agent.StartServerFailed
          }
      }
  }
}
