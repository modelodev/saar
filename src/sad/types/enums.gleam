pub type LandlockMode {
  LandlockBestEffort
  LandlockEnforced
  LandlockOff
}

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

pub fn landlock_mode_to_string(mode: LandlockMode) -> String {
  case mode {
    LandlockBestEffort -> "best_effort"
    LandlockEnforced -> "enforced"
    LandlockOff -> "off"
  }
}

pub type Lifecycle {
  Transient
  Continuous
}

pub fn lifecycle_to_string(lc: Lifecycle) -> String {
  case lc {
    Transient -> "transient"
    Continuous -> "continuous"
  }
}

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

pub type ErrorKind {
  AgentError
  InfraError
  BadRequest
}

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

pub fn error_kind_to_string(kind: ErrorKind) -> String {
  case kind {
    AgentError -> "agent_error"
    InfraError -> "infra_error"
    BadRequest -> "bad_request"
  }
}
