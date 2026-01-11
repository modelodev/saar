//// Small enums used for configuration and (de)serialization.
////
//// Mission: define stable enumerations that are exchanged via config/env and
//// wire formats.
////
//// Responsibilities:
//// - Keep string representations stable.
//// - Provide explicit conversions to/from strings.
////
//// Non-responsibilities:
//// - Validation outside of the enum domain.
//// - Parsing complex configuration structures.
////
//// Relationships:
//// - Used by `sad/types/config`, `sad/types/profile`, and runner types.

/// How strictly filesystem isolation should be enforced.
///
/// This is typically configured via environment/config and interpreted by the
/// sandboxing layer.
pub type LandlockMode {
  LandlockBestEffort
  LandlockEnforced
  LandlockOff
}

/// Parses a `LandlockMode` from its string representation.
///
/// Valid values: `best_effort`, `enforced`, `off`.
pub fn landlock_mode_from_string(s: String) -> Result(LandlockMode, String) {
  case s {
    "best_effort" -> Ok(LandlockBestEffort)
    "enforced" -> Ok(LandlockEnforced)
    "off" -> Ok(LandlockOff)
    other ->
      Error(
        "Unknown landlock mode: '"
        <> other
        <> "'. Valid: best_effort, enforced, off",
      )
  }
}

/// Converts a `LandlockMode` to its stable string representation.
pub fn landlock_mode_to_string(mode: LandlockMode) -> String {
  case mode {
    LandlockBestEffort -> "best_effort"
    LandlockEnforced -> "enforced"
    LandlockOff -> "off"
  }
}

/// How a profile/runner is expected to behave over time.
///
/// - `Transient`: one-shot execution.
/// - `Continuous`: long-running service.
pub type Lifecycle {
  Transient
  Continuous
}

/// Converts a `Lifecycle` to its stable string representation.
pub fn lifecycle_to_string(lc: Lifecycle) -> String {
  case lc {
    Transient -> "transient"
    Continuous -> "continuous"
  }
}

/// Parses a `Lifecycle` from its string representation.
///
/// Valid values: `transient`, `continuous`.
pub fn lifecycle_from_string(s: String) -> Result(Lifecycle, String) {
  case s {
    "transient" -> Ok(Transient)
    "continuous" -> Ok(Continuous)
    other ->
      Error(
        "Unknown lifecycle: '" <> other <> "'. Valid: transient, continuous",
      )
  }
}

/// High-level error classification for client responses.
///
/// This is intentionally small and stable.
pub type ErrorKind {
  AgentError
  InfraError
  BadRequest
}

/// Parses an `ErrorKind` from its string representation.
///
/// Valid values: `agent_error`, `infra_error`, `bad_request`.
pub fn error_kind_from_string(s: String) -> Result(ErrorKind, String) {
  case s {
    "agent_error" -> Ok(AgentError)
    "infra_error" -> Ok(InfraError)
    "bad_request" -> Ok(BadRequest)
    other ->
      Error(
        "Unknown error kind: '"
        <> other
        <> "'. Valid: agent_error, infra_error, bad_request",
      )
  }
}

/// Converts an `ErrorKind` to its stable string representation.
pub fn error_kind_to_string(kind: ErrorKind) -> String {
  case kind {
    AgentError -> "agent_error"
    InfraError -> "infra_error"
    BadRequest -> "bad_request"
  }
}
