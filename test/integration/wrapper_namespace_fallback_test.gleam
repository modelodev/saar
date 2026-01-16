import gleeunit
import gleeunit/should
import port_helpers
import sad/bridge/port_process

pub fn main() {
  gleeunit.main()
}

pub fn wrapper_force_fallback_works() {
  port_helpers.ensure_wrapper_path()

  let env = port_helpers.base_env(200, [#("SAD_WRAPPER_FORCE_FALLBACK", "1")])

  let proc =
    port_process.start("/bin/sh", ["-c", "exit 0"], env, ".", 262_144)
    |> should.be_ok

  let _ = proc
  Nil
}

pub fn wrapper_namespace_optional() {
  port_helpers.ensure_wrapper_path()

  // Ensure the wrapper does not hang when namespaces are enabled and the child
  // exits immediately.
  let env = port_helpers.base_env(200, [#("SAD_WRAPPER_FORCE_FALLBACK", "0")])

  let proc =
    port_process.start("/bin/sh", ["-c", "exit 0"], env, ".", 262_144)
    |> should.be_ok

  let _ = proc
  Nil
}
