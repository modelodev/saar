//// OS signal integration.
////
//// Mission: install a SIGTERM handler that triggers SAAR's graceful shutdown.
////
//// Responsibilities:
//// - Replace the default `erl_signal_handler` SIGTERM behavior.
//// - Forward SIGTERM events into the provided BEAM process.
////
//// Non-responsibilities:
//// - Implementing the shutdown flow (owned by `saar/gateway/shutdown`).
////
//// Relationships:
//// - Used by `saar.gleam` when running `saar serve`.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process

/// Installs the SAAR SIGTERM handler.
///
/// `target` receives the Erlang record `{saar_sigterm}`.
pub fn install_sigterm_handler(target: process.Pid) -> Nil {
  let _ = install_sigterm_handler_ffi(target)
  Nil
}

@external(erlang, "saar_signal_handler", "install")
fn install_sigterm_handler_ffi(target: process.Pid) -> Dynamic
