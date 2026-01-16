//// Resolved parameter values.
////
//// Mission: represent resolved runner/profile parameters, including secrets, in
//// a form that can be safely rendered for execution and diagnostics.
////
//// Responsibilities:
//// - Provide a single type for plain values and secrets.
//// - Provide rendering helpers for environment export and logging.
////
//// Non-responsibilities:
//// - Resolving parameter sources (see `saar/params`).
//// - Defining the secret redaction policy (delegated to `saar/types/core`).
////
//// Relationships:
//// - Produced by `saar/params`.
//// - Consumed by `saar/bridge/interpolator` and `saar/bridge/serialization`.

import gleam/dict.{type Dict}
import saar/types/core as types_core

/// A resolved parameter value.
///
/// Use `NormalValue` for ordinary values and `SecretVal` for secrets that may
/// need redaction in logs.
pub type ResolvedValue {
  NormalValue(types_core.Value)
  SecretVal(types_core.SecretValue)
}

/// A map of resolved parameter names to values.
///
/// Example:
/// ```gleam
/// import gleam/dict
/// import saar/types/core as types_core
/// import saar/types/resolved_params
///
/// let params =
///   dict.from_list([
///     #("model", resolved_params.NormalValue(types_core.StringVal("gpt-4"))),
///   ])
/// ```
pub type ResolvedParams =
  Dict(String, ResolvedValue)

/// Converts a resolved value to its environment-safe string form.
///
/// Secrets are unwrapped to their raw env value.
pub fn resolved_value_to_env(value: ResolvedValue) -> String {
  case value {
    NormalValue(v) -> types_core.value_to_string(v)
    SecretVal(secret) -> types_core.secret_to_env_value(secret)
  }
}

/// Converts a resolved value to a diagnostic string.
///
/// Secrets are rendered using the redaction policy defined by `saar/types/core`.
pub fn resolved_value_inspect(value: ResolvedValue) -> String {
  case value {
    NormalValue(v) -> types_core.value_to_string(v)
    SecretVal(secret) -> types_core.secret_inspect(secret)
  }
}
