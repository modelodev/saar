import envoy
import gleam/dynamic
import gleam/erlang/atom
import gleeunit

pub fn main() {
  case envoy.get("SAD_TEST_VERBOSE_OTP") {
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
