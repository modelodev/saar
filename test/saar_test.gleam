import envoy
import gleam/dynamic
import gleam/erlang/atom
import gleeunit

pub fn main() {
  case envoy.get("SAAR_TEST_VERBOSE_OTP") {
    Ok(_) -> Nil
    Error(_) -> silence_otp_supervisor_reports()
  }

  gleeunit.main()
}

fn silence_otp_supervisor_reports() -> Nil {
  // Hide warning-level noise during tests.
  let _ = logger_set_primary_config(atom.create("level"), atom.create("error"))

  // Supervisor reports are expected in crash-semantics tests.
  let _ =
    logger_set_module_level(atom.create("supervisor"), atom.create("critical"))

  // Mist uses a legacy logger and may emit `=ERROR REPORT=` noise
  // (e.g. `MalformedRequest`) when a client closes early.
  // Silence it for the test suite; failures still fail the tests.
  let _ = error_logger_tty(False)

  Nil
}

@external(erlang, "logger", "set_primary_config")
fn logger_set_primary_config(
  key: atom.Atom,
  value: atom.Atom,
) -> dynamic.Dynamic

@external(erlang, "logger", "set_module_level")
fn logger_set_module_level(
  module: atom.Atom,
  level: atom.Atom,
) -> dynamic.Dynamic

@external(erlang, "error_logger", "tty")
fn error_logger_tty(enabled: Bool) -> dynamic.Dynamic
