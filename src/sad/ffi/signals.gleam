//// OS signal integration.
////
//// Mission: install a SIGTERM handler that triggers SAD's graceful shutdown.
////
//// Responsibilities:
//// - Replace the default `erl_signal_handler` SIGTERM behavior.
//// - Forward SIGTERM events into the provided BEAM process.
////
//// Non-responsibilities:
//// - Implementing the shutdown flow (owned by `sad/gateway/shutdown`).
////
//// Relationships:
//// - Used by `sad.gleam` when running `sad serve`.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process

/// Installs the SAD SIGTERM handler.
///
/// `target` receives the Erlang record `{sad_sigterm}`.
pub fn install_sigterm_handler(target: process.Pid) -> Nil {
  let _ = install_sigterm_handler_ffi(target)
  Nil
}

@external(erlang, "sad_signal_handler", "install")
fn install_sigterm_handler_ffi(target: process.Pid) -> Dynamic
