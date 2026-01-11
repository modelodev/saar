import gleam/dict
import gleam/dynamic/decode
import gleam/http
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import port_helpers
import runner_fixtures
import sad/bridge/client
import sad/bridge/runner
import sad/net/tcp_listener
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/input as types_input
import sad/types/output as types_output
import sad/types/runner as types_runner
import test_assertions

const host = "127.0.0.1"

pub fn main() {
  gleeunit.main()
}

pub fn port_injected_into_env_test() {
  port_helpers.ensure_wrapper_path()

  let #(server, port, _trace_id) =
    start_echo_server_with_runtime(types_runner.RuntimeConfig(
      mode: types_runner.ManagedPort,
      port_env_var: Some("TEST_PORT"),
      host_env_var: Some("TEST_HOST"),
    ))

  let url = "http://" <> host <> ":" <> int.to_string(port) <> "/env"

  let resp =
    client.request_sync(http.Get, url, dict.new(), None, 1000, 4096)
    |> test_assertions.assert_ok

  runner.stop_server(server)

  let assert Ok(dynamic_env) = json.parse(resp.body, decode.dynamic)

  let decoder = {
    use sad_host <- decode.field("SAD_HOST", decode.optional(decode.string))
    use sad_port <- decode.field("SAD_PORT", decode.optional(decode.string))
    use test_host <- decode.field("TEST_HOST", decode.optional(decode.string))
    use test_port <- decode.field("TEST_PORT", decode.optional(decode.string))
    decode.success(#(sad_host, sad_port, test_host, test_port))
  }

  let assert Ok(#(
    Some(sad_host),
    Some(sad_port),
    Some(test_host),
    Some(test_port),
  )) = decode.run(dynamic_env, decoder)

  sad_host |> should.equal(host)
  test_host |> should.equal(host)
  sad_port |> should.equal(int.to_string(port))
  test_port |> should.equal(int.to_string(port))
}

pub fn managed_port_in_use_fails_fast_test() {
  port_helpers.ensure_wrapper_path()

  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)

  let config = types_config.default_sad_config()

  let runtime =
    types_runner.RuntimeConfig(
      mode: types_runner.ManagedPort,
      port_env_var: None,
      host_env_var: None,
    )

  let input = base_input_with_runtime(runtime)
  let env = port_helpers.base_env(500, [])

  let result =
    runner.start_server(
      "python3",
      ["./test/fixtures/source_local/runners/echo_server.py"],
      env,
      ".",
      input,
      config,
      Some(port),
    )

  tcp_listener.close(listener)

  let err = test_assertions.assert_error(result)
  let types_output.InteractionError(kind: kind, ..) = err
  kind |> should.equal(types_enums.InfraError)
}

fn start_echo_server_with_runtime(
  runtime: types_runner.RuntimeConfig,
) -> #(runner.ServerHandle, Int, types_core.TraceId) {
  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)
  tcp_listener.close(listener)

  let config = types_config.default_sad_config()
  let input = base_input_with_runtime(runtime)

  let env = port_helpers.base_env(500, [])

  let server =
    runner.start_server(
      "python3",
      ["./test/fixtures/source_local/runners/echo_server.py"],
      env,
      ".",
      input,
      config,
      Some(port),
    )
    |> test_assertions.assert_ok

  port_helpers.wait_for_http_200(
    "http://" <> host <> ":" <> int.to_string(port) <> "/health",
    40,
    25,
  )

  #(server, port, input.context.trace_id)
}

fn base_input_with_runtime(
  runtime: types_runner.RuntimeConfig,
) -> types_input.SadInput {
  let base_input =
    runner_fixtures.base_input(
      runner_fixtures.default_chat_payload(),
      types_runner.ArtifactConfig(include: [], exclude: []),
    )

  types_input.SadInput(
    ..base_input,
    runner_def: types_runner.Runner(..base_input.runner_def, runtime: runtime),
  )
}
