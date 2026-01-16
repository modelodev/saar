import gleam/dict
import gleam/http
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import port_helpers
import runner_fixtures
import saar/bridge/http_client
import saar/bridge/runner
import saar/net/tcp_listener

import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/enums as types_enums
import saar/types/input as types_input
import saar/types/output as types_output
import saar/types/runner as types_runner
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
    http_client.request_sync_string(
      http.Post,
      url,
      dict.new(),
      Some("hello"),
      1000,
      1024,
    )

  runner.stop_server(server)

  let resp = test_assertions.assert_ok(result)
  resp.status |> should.equal(200)
  resp.body |> should.equal("hello")
}

pub fn execute_sync_respects_max_body_test() {
  port_helpers.ensure_wrapper_path()
  let #(server, port, _trace_id) = start_echo_server()

  let url = "http://" <> host <> ":" <> int.to_string(port) <> "/big?size=100"

  let result =
    http_client.request_sync_string(http.Get, url, dict.new(), None, 1000, 10)

  runner.stop_server(server)

  case result {
    Error(http_client.BodyTooLarge(..)) -> Nil
    other -> panic as { "Expected BodyTooLarge, got " <> string.inspect(other) }
  }
}

pub fn http_streaming_close_without_result_errors() {
  port_helpers.ensure_wrapper_path()
  let #(server, port, trace_id) = start_echo_server()

  let url =
    "http://" <> host <> ":" <> int.to_string(port) <> "/sse?mode=no_result"

  let conn =
    http_client.open_sse(http.Get, url, dict.new(), None, 1000)
    |> test_assertions.assert_ok

  let result = http_client.read_sse_until_result(conn, trace_id, 262_144, 200)

  http_client.close_sse(conn)
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
    http_client.open_sse(http.Get, url, dict.new(), None, 1000)
    |> test_assertions.assert_ok

  let result = http_client.read_sse_until_result(conn, trace_id, 262_144, 200)

  http_client.close_sse(conn)
  runner.stop_server(server)

  let err = test_assertions.assert_error(result)
  let types_output.InteractionError(kind: kind, ..) = err
  kind |> should.equal(types_enums.InfraError)
}

pub fn upstream_sse_event_too_large_fails_test() {
  port_helpers.ensure_wrapper_path()
  let #(server, port, trace_id) = start_echo_server()

  let url = "http://" <> host <> ":" <> int.to_string(port) <> "/sse?mode=ok"

  let conn =
    http_client.open_sse(http.Get, url, dict.new(), None, 1000)
    |> test_assertions.assert_ok

  let result = http_client.read_sse_until_result(conn, trace_id, 10, 200)

  http_client.close_sse(conn)
  runner.stop_server(server)

  let err = test_assertions.assert_error(result)
  let types_output.InteractionError(kind: kind, ..) = err
  kind |> should.equal(types_enums.InfraError)
}

pub fn upstream_sse_unexpected_tag_fails_test() {
  port_helpers.ensure_wrapper_path()
  let #(server, port, trace_id) = start_echo_server()

  let url =
    "http://"
    <> host
    <> ":"
    <> int.to_string(port)
    <> "/sse?mode=unexpected_tag"

  let conn =
    http_client.open_sse(http.Get, url, dict.new(), None, 1000)
    |> test_assertions.assert_ok

  let result = http_client.read_sse_until_result(conn, trace_id, 262_144, 200)

  http_client.close_sse(conn)
  runner.stop_server(server)

  let err = test_assertions.assert_error(result)
  let types_output.InteractionError(kind: kind, ..) = err
  kind |> should.equal(types_enums.InfraError)
}

pub fn execute_sync_invalid_utf8_body_fails_test() {
  port_helpers.ensure_wrapper_path()
  let #(server, port, _trace_id) = start_echo_server()

  let url = "http://" <> host <> ":" <> int.to_string(port) <> "/bin?size=16"

  let result =
    http_client.request_sync_string(http.Get, url, dict.new(), None, 1000, 1024)

  runner.stop_server(server)

  case result {
    Error(http_client.InvalidUtf8Body) -> Nil
    other ->
      panic as { "Expected InvalidUtf8Body, got " <> string.inspect(other) }
  }
}

pub fn continuous_timeout_does_not_kill_server_test() {
  port_helpers.ensure_wrapper_path()
  let #(server, port, _trace_id) = start_echo_server()

  let slow = "http://" <> host <> ":" <> int.to_string(port) <> "/sleep?ms=200"

  let timed_out =
    http_client.request_sync_string(http.Get, slow, dict.new(), None, 50, 1024)

  case timed_out {
    Error(http_client.Timeout) -> Nil
    other -> panic as { "Expected Timeout, got " <> string.inspect(other) }
  }

  let health = "http://" <> host <> ":" <> int.to_string(port) <> "/health"

  http_client.request_sync_string(
    http.Get,
    health,
    dict.new(),
    None,
    1000,
    1024,
  )
  |> should.be_ok

  runner.stop_server(server)
}

pub fn multipart_non_stream_ok_test() {
  port_helpers.ensure_wrapper_path()
  let #(server, port, trace_id) = start_echo_server()

  let file_url =
    "http://" <> host <> ":" <> int.to_string(port) <> "/bin?size=16"

  let check_url =
    "http://" <> host <> ":" <> int.to_string(port) <> "/multipart_check"

  let file =
    types_input.FileRef(
      url: file_url,
      mime: "application/pdf",
      name: "doc.pdf",
      context: None,
    )

  let result =
    http_client.request_multipart_files(
      trace_id,
      http.Post,
      check_url,
      dict.new(),
      dict.from_list([#("field", "value")]),
      "file",
      [file],
      False,
      types_config.default_saar_config(),
      1000,
    )

  runner.stop_server(server)

  let responses = test_assertions.assert_ok(result)
  list.length(responses) |> should.equal(1)

  let assert [resp] = responses
  resp.status |> should.equal(200)
  string.contains(resp.body, "\"contains_marker\": true") |> should.equal(True)
}

pub fn multipart_streaming_rejected_test() {
  port_helpers.ensure_wrapper_path()
  let #(server, port, trace_id) = start_echo_server()

  let file_url =
    "http://" <> host <> ":" <> int.to_string(port) <> "/file?size=1"
  let echo_url =
    "http://" <> host <> ":" <> int.to_string(port) <> "/multipart_check"

  let file =
    types_input.FileRef(
      url: file_url,
      mime: "text/plain",
      name: "doc.txt",
      context: None,
    )

  let result =
    http_client.request_multipart_files(
      trace_id,
      http.Post,
      echo_url,
      dict.new(),
      dict.new(),
      "file",
      [file],
      True,
      types_config.default_saar_config(),
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
  let echo_url =
    "http://" <> host <> ":" <> int.to_string(port) <> "/multipart_check"

  let file =
    types_input.FileRef(
      url: file_url,
      mime: "text/plain",
      name: "doc.txt",
      context: None,
    )

  let base = types_config.default_saar_config()
  let config =
    types_config.SaarConfig(
      ..base,
      limits: types_config.SaarLimits(..base.limits, max_file_fetch_bytes: 5),
    )

  let result =
    http_client.request_multipart_files(
      trace_id,
      http.Post,
      echo_url,
      dict.new(),
      dict.new(),
      "file",
      [file],
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

  let config = types_config.default_saar_config()

  let runtime =
    types_runner.ManagedPort(
      host_env_var: Some("TEST_HOST"),
      port_env_var: Some("TEST_PORT"),
    )

  let base_input =
    runner_fixtures.base_input(
      runner_fixtures.default_chat_payload(),
      types_runner.ArtifactConfig(include: [], exclude: []),
    )

  let input =
    types_input.SaarInput(
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
