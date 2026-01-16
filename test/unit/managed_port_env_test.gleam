import agent_helpers
import gleam/int
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import saar/bridge/managed_port_env
import saar/net/tcp_listener
import saar/types/core as types_core
import saar/types/runner as types_runner

pub fn main() {
  gleeunit.main()
}

pub fn inject_managed_port_env_does_not_validate_availability_test() {
  let config = agent_helpers.default_config()

  let assert Ok(#(listener, port)) = tcp_listener.listen("127.0.0.1", 0)

  let runtime = types_runner.ManagedPort(host_env_var: None, port_env_var: None)

  let result =
    managed_port_env.inject_managed_port_env(
      [],
      types_core.trace_id("test"),
      config,
      runtime,
      Some(port),
    )

  tcp_listener.close(listener)

  result
  |> should.equal(
    Ok([#("SAAR_HOST", "127.0.0.1"), #("SAAR_PORT", int.to_string(port))]),
  )
}
