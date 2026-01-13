import agent_helpers
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import sad/bridge/managed_port_env
import sad/net/tcp_listener
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/output as types_output
import sad/types/runner as types_runner

pub fn main() {
  gleeunit.main()
}

pub fn inject_managed_port_env_fails_when_port_in_use_test() {
  let config = agent_helpers.default_config()

  let assert Ok(#(listener, port)) = tcp_listener.listen("127.0.0.1", 0)

  let runtime =
    types_runner.RuntimeConfig(
      mode: types_runner.ManagedPort,
      host_env_var: None,
      port_env_var: None,
    )

  let result =
    managed_port_env.inject_managed_port_env(
      [],
      types_core.trace_id("test"),
      config,
      runtime,
      Some(port),
    )

  tcp_listener.close(listener)

  let err = result |> should.be_error
  let types_output.InteractionError(kind: kind, ..) = err
  kind |> should.equal(types_enums.InfraError)
}
