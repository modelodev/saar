import gleam/dict
import gleam/http
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import port_helpers
import runner_fixtures
import sad/bridge/client
import sad/bridge/runner
import sad/decoders
import sad/net/tcp_listener
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/input as types_input
import sad/types/output as types_output
import sad/types/profile as types_profile
import sad/types/runner as types_runner
import simplifile
import test_assertions

const host = "127.0.0.1"

pub fn main() {
  gleeunit.main()
}

pub fn execute_sync_ok_test() {
  port_helpers.ensure_wrapper_path()
  let #(server, port, _trace_id) = start_echo_server()

  let url = "http://" <> host <> ":" <> int.to_string(port) <> "/echo"

  let result =
    client.request_sync(http.Post, url, dict.new(), Some("hello"), 1000, 1024)

  runner.stop_server(server)

  let resp = test_assertions.assert_ok(result)
  resp.status |> should.equal(200)
  resp.body |> should.equal("hello")
}

pub fn execute_sync_respects_max_body_test() {
  port_helpers.ensure_wrapper_path()
  let #(server, port, _trace_id) = start_echo_server()

  let url = "http://" <> host <> ":" <> int.to_string(port) <> "/big?size=100"

  let result = client.request_sync(http.Get, url, dict.new(), None, 1000, 10)

  runner.stop_server(server)

  case result {
    Error(client.BodyTooLarge(..)) -> Nil
    other -> panic as { "Expected BodyTooLarge, got " <> string.inspect(other) }
  }
}

pub fn upstream_sse_requires_result_test() {
  port_helpers.ensure_wrapper_path()
  let #(server, port, trace_id) = start_echo_server()

  let url =
    "http://" <> host <> ":" <> int.to_string(port) <> "/sse?mode=no_result"

  let conn =
    client.open_sse(http.Get, url, dict.new(), None, 1000)
    |> test_assertions.assert_ok

  let result = client.read_sse_until_result(conn, trace_id, 262_144, 200)

  client.close_sse(conn)
  runner.stop_server(server)

  let err = test_assertions.assert_error(result)
  let types_output.InteractionError(kind: kind, ..) = err
  kind |> should.equal(types_enums.InfraError)
}

pub fn upstream_sse_invalid_json_fails_test() {
  port_helpers.ensure_wrapper_path()
  let #(server, port, trace_id) = start_echo_server()

  let url =
    "http://" <> host <> ":" <> int.to_string(port) <> "/sse?mode=invalid_json"

  let conn =
    client.open_sse(http.Get, url, dict.new(), None, 1000)
    |> test_assertions.assert_ok

  let result = client.read_sse_until_result(conn, trace_id, 262_144, 200)

  client.close_sse(conn)
  runner.stop_server(server)

  let err = test_assertions.assert_error(result)
  let types_output.InteractionError(kind: kind, ..) = err
  kind |> should.equal(types_enums.InfraError)
}

pub fn continuous_timeout_does_not_kill_server_test() {
  port_helpers.ensure_wrapper_path()
  let #(server, port, _trace_id) = start_echo_server()

  let slow = "http://" <> host <> ":" <> int.to_string(port) <> "/sleep?ms=200"

  let timed_out =
    client.request_sync(http.Get, slow, dict.new(), None, 50, 1024)

  case timed_out {
    Error(client.Timeout) -> Nil
    other -> panic as { "Expected Timeout, got " <> string.inspect(other) }
  }

  let health = "http://" <> host <> ":" <> int.to_string(port) <> "/health"

  client.request_sync(http.Get, health, dict.new(), None, 1000, 1024)
  |> should.be_ok

  runner.stop_server(server)
}

pub fn multipart_non_stream_ok_test() {
  port_helpers.ensure_wrapper_path()
  let #(server, port, trace_id) = start_echo_server()

  let file_url =
    "http://" <> host <> ":" <> int.to_string(port) <> "/file?size=4"
  let echo_url = "http://" <> host <> ":" <> int.to_string(port) <> "/echo"

  let file =
    types_input.FileRef(
      url: file_url,
      mime: "text/plain",
      name: "doc.txt",
      context: None,
    )

  let result =
    client.request_multipart(
      trace_id,
      http.Post,
      echo_url,
      dict.new(),
      dict.from_list([#("field", "value")]),
      "file",
      file,
      False,
      types_config.default_sad_config(),
      1000,
    )

  runner.stop_server(server)

  let resp = test_assertions.assert_ok(result)
  resp.status |> should.equal(200)
  string.contains(resp.body, "doc.txt") |> should.equal(True)
  string.contains(resp.body, "bbbb") |> should.equal(True)
}

pub fn multipart_streaming_rejected_test() {
  port_helpers.ensure_wrapper_path()
  let #(server, port, trace_id) = start_echo_server()

  let file_url =
    "http://" <> host <> ":" <> int.to_string(port) <> "/file?size=1"
  let echo_url = "http://" <> host <> ":" <> int.to_string(port) <> "/echo"

  let file =
    types_input.FileRef(
      url: file_url,
      mime: "text/plain",
      name: "doc.txt",
      context: None,
    )

  let result =
    client.request_multipart(
      trace_id,
      http.Post,
      echo_url,
      dict.new(),
      dict.new(),
      "file",
      file,
      True,
      types_config.default_sad_config(),
      1000,
    )

  runner.stop_server(server)

  let err = test_assertions.assert_error(result)
  let types_output.InteractionError(kind: kind, ..) = err
  kind |> should.equal(types_enums.BadRequest)
}

pub fn multipart_respects_max_file_fetch_bytes_test() {
  port_helpers.ensure_wrapper_path()
  let #(server, port, trace_id) = start_echo_server()

  let file_url =
    "http://" <> host <> ":" <> int.to_string(port) <> "/file?size=20"
  let echo_url = "http://" <> host <> ":" <> int.to_string(port) <> "/echo"

  let file =
    types_input.FileRef(
      url: file_url,
      mime: "text/plain",
      name: "doc.txt",
      context: None,
    )

  let base = types_config.default_sad_config()
  let config =
    types_config.SadConfig(
      ..base,
      limits: types_config.SadLimits(..base.limits, max_file_fetch_bytes: 5),
    )

  let result =
    client.request_multipart(
      trace_id,
      http.Post,
      echo_url,
      dict.new(),
      dict.new(),
      "file",
      file,
      False,
      config,
      1000,
    )

  runner.stop_server(server)

  let err = test_assertions.assert_error(result)
  let types_output.InteractionError(kind: kind, ..) = err
  kind |> should.equal(types_enums.InfraError)
}

fn start_echo_server() -> #(runner.ServerHandle, Int, types_core.TraceId) {
  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)
  tcp_listener.close(listener)

  let interface = echo_server_interface()
  let config = types_config.default_sad_config()

  let runtime =
    types_runner.RuntimeConfig(
      mode: types_runner.ManagedPort,
      port_env_var: Some("TEST_PORT"),
      host_env_var: Some("TEST_HOST"),
    )

  let base_input =
    runner_fixtures.base_input(
      runner_fixtures.default_chat_payload(),
      types_runner.ArtifactConfig(include: [], exclude: []),
    )

  let input =
    types_input.SadInput(
      ..base_input,
      runner_def: types_runner.Runner(..base_input.runner_def, runtime: runtime),
    )

  let env = port_helpers.base_env(500, [])

  let server =
    runner.start_server(
      "python3",
      ["./test/fixtures/source_local/runners/echo_server.py"],
      env,
      ".",
      input,
      config,
      interface,
      Some(port),
    )
    |> test_assertions.assert_ok

  #(server, port, input.context.trace_id)
}

fn echo_server_interface() -> types_profile.Interface {
  let assert Ok(contents) =
    simplifile.read(
      from: "test/fixtures/source_local/profiles/echo_server.json",
    )

  let assert Ok(profile) = json.parse(contents, decoders.profile_decoder())

  let types_profile.Profile(interface: interface, ..) = profile
  interface
}
