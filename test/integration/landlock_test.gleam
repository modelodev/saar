import gleeunit
import gleeunit/should
import port_helpers
import sad/bridge/port_process
import sad/types/agent as types_agent

pub fn main() {
  gleeunit.main()
}

pub fn landlock_best_effort_does_not_break_without_support() {
  port_helpers.ensure_wrapper_path()

  // Even if landlock is unavailable, best-effort must keep the instance running.
  // We can't reliably force an unsupported kernel in CI, so this test asserts
  // that the wrapper starts and exits cleanly in best-effort mode.
  let env = port_helpers.base_env(200, [#("SAD_LANDLOCK_MODE", "best_effort")])

  port_process.start("/bin/sh", ["-c", "exit 0"], env, ".", 262_144)
  |> should.be_ok

  Nil
}

pub fn landlock_enforced_fails_instance_if_unavailable() {
  port_helpers.ensure_wrapper_path()

  // In enforced mode, missing prerequisites (e.g. SAD_WORKSPACE) must fail the
  // instance without crashing the SAD process.
  let env = port_helpers.base_env(200, [#("SAD_LANDLOCK_MODE", "enforced")])

  let result =
    port_process.start("/bin/sh", ["-c", "exit 0"], env, ".", 262_144)

  case result {
    Ok(_) -> panic as "Expected enforced landlock failure"
    Error(_) -> Nil
  }
}

pub fn failure_reason_string_is_stable_test() {
  // This is a characterization test: the client-facing string must remain stable.
  types_agent.failure_reason_to_string(types_agent.LandlockUnavailable)
  |> should.equal("landlock_unavailable")
}
