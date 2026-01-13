import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/otp/actor

import gleam/int
import gleam/option.{None, Some}

import gleam/string
import gleeunit
import gleeunit/should
import port_helpers
import sad/app_state
import sad/bridge/http_client
import sad/config_loader
import sad/core/root_supervisor
import sad/core/supervisor_names
import sad/net/tcp_listener
import sad/profiles_sources
import sad/types/config as types_config
import simplifile

const api_key = "test-key"

const host = "127.0.0.1"

pub fn main() {
  gleeunit.main()
}

pub fn get_agent_capabilities() {
  let base_url = start_sad()

  let instance_id = "inst-cap-1"
  create_agent(base_url, "echo_cli", instance_id)

  wait_phase(base_url, instance_id, "ready_transient", 200)

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/agents/" <> instance_id,
      auth_headers(),
      None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(200)
  should.equal(string.contains(resp.body, "\"capabilities\""), True)
  should.equal(string.contains(resp.body, "\"echo\""), True)
}

pub fn post_agents_interact_transient() {
  let base_url = start_sad()

  let instance_id = "inst-transient-1"
  create_agent(base_url, "echo_cli", instance_id)

  wait_phase(base_url, instance_id, "ready_transient", 200)

  let body =
    "{"
    <> "\"capability\":\"echo\","
    <> "\"inputs\":{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]},"
    <> "\"context\":{\"trace_id\":\"trace-transient-1\"}"
    <> "}"

  let resp =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/agents/" <> instance_id <> "/interact",
      dict.insert(auth_headers(), "content-type", "application/json"),
      Some(body),
      5000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(200)
  should.equal(string.contains(resp.body, "\"trace_id\""), True)
}

pub fn post_agents_interact_streaming_defaults_to_agui() {
  let base_url = start_sad()

  let instance_id = "inst-stream-1"
  create_agent(base_url, "streaming_echo", instance_id)

  wait_phase(base_url, instance_id, "ready_transient", 200)

  let url = base_url <> "/agents/" <> instance_id <> "/interact"

  let body =
    "{"
    <> "\"capability\":\"echo\","
    <> "\"inputs\":{\"messages\":[{\"role\":\"user\",\"content\":\"hello world\"}]},"
    <> "\"context\":{\"trace_id\":\"trace-stream-1\"}"
    <> "}"

  let conn =
    http_client.open_sse(
      http.Post,
      url,
      dict.insert(auth_headers(), "content-type", "application/json"),
      Some(body),
      2000,
    )
    |> assert_ok

  let first = wait_sse_data(conn, 2000)
  should.equal(string.contains(first, "\"type\":\"RUN_STARTED\""), True)

  http_client.close_sse(conn)
}

pub fn post_agents_interact_continuous() {
  let base_url = start_sad()

  let instance_id = "inst-continuous-1"
  create_agent(base_url, "echo_server", instance_id)
  wait_phase(base_url, instance_id, "ready_continuous", 200)

  let body =
    "{"
    <> "\"capability\":\"echo\","
    <> "\"inputs\":{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]},"
    <> "\"context\":{\"trace_id\":\"trace-cont-1\"}"
    <> "}"

  let resp =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/agents/" <> instance_id <> "/interact",
      dict.insert(auth_headers(), "content-type", "application/json"),
      Some(body),
      5000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(200)
  should.equal(string.contains(resp.body, "\"trace_id\""), True)
}

pub fn post_agents_interact_timeout() {
  let base_url = start_sad()

  let instance_id = "inst-timeout-1"
  create_agent(base_url, "echo_cli", instance_id)
  wait_phase(base_url, instance_id, "ready_transient", 200)

  let body =
    "{"
    <> "\"capability\":\"echo\","
    <> "\"inputs\":{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]},"
    <> "\"context\":{\"trace_id\":\"trace-timeout-1\"}"
    <> "}"

  let resp =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/agents/" <> instance_id <> "/interact",
      dict.insert(auth_headers(), "content-type", "application/json"),
      Some(body),
      5000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(504)
}

pub fn post_agents_interact_streaming_a2ui_header_switches_wire() {
  let base_url = start_sad()

  let instance_id = "inst-a2ui-1"
  create_agent(base_url, "streaming_echo", instance_id)

  wait_phase(base_url, instance_id, "ready_transient", 200)

  let url = base_url <> "/agents/" <> instance_id <> "/interact"

  let body =
    "{"
    <> "\"capability\":\"echo\","
    <> "\"inputs\":{\"messages\":[{\"role\":\"user\",\"content\":\"hello world\"}]},"
    <> "\"context\":{\"trace_id\":\"trace-a2ui-1\"}"
    <> "}"

  let headers =
    auth_headers()
    |> dict.insert("content-type", "application/json")
    |> dict.insert("x-sad-ui-protocol", "a2ui/v0.8")

  let conn =
    http_client.open_sse(http.Post, url, headers, Some(body), 2000) |> assert_ok

  let first = wait_sse_data(conn, 2000)
  // A2UI is sent without AG-UI envelope.
  should.equal(string.contains(first, "\"beginRendering\""), True)
  should.equal(string.contains(first, "\"type\":"), False)

  http_client.close_sse(conn)
}

fn start_sad() -> String {
  port_helpers.ensure_wrapper_path()

  let names = supervisor_names.new_names()

  let cfg0 =
    config_loader.load_from_path(
      "./test/fixtures/config/test_config.toml",
      fn(name) {
        case name {
          "SAD_TEST_API_KEY" -> Ok(api_key)
          _ -> Error(Nil)
        }
      },
      simplifile.read,
    )
    |> assert_ok

  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)
  tcp_listener.close(listener)

  let cfg = types_config.SadConfig(..cfg0, server_port: port)

  let profiles = profiles_sources.load_profiles_from_sources(cfg) |> assert_ok

  let state = app_state.AppState(config: cfg, initial_profiles: profiles)
  let assert Ok(actor.Started(..)) = root_supervisor.start(state, names)

  "http://" <> host <> ":" <> int.to_string(port)
}

fn auth_headers() -> dict.Dict(String, String) {
  dict.from_list([#("authorization", "Bearer " <> api_key)])
}

fn create_agent(
  base_url: String,
  profile_id: String,
  instance_id: String,
) -> Nil {
  let body =
    "{"
    <> "\"profile_id\":\""
    <> profile_id
    <> "\","
    <> "\"instance_id\":\""
    <> instance_id
    <> "\""
    <> "}"

  http_client.request_sync_string(
    http.Post,
    base_url <> "/sys/agents",
    dict.insert(auth_headers(), "content-type", "application/json"),
    Some(body),
    5000,
    1024 * 1024,
  )
  |> assert_ok
  |> fn(resp) { resp.status |> should.equal(201) }

  Nil
}

fn wait_phase(
  base_url: String,
  instance_id: String,
  expected_phase: String,
  attempts: Int,
) -> Nil {
  case attempts {
    0 -> panic as "Timed out waiting for phase"

    _ -> {
      let resp =
        http_client.request_sync_string(
          http.Get,
          base_url <> "/sys/agents/" <> instance_id <> "/status",
          auth_headers(),
          None,
          1000,
          1024 * 1024,
        )
        |> assert_ok

      case
        string.contains(resp.body, "\"phase\":\"" <> expected_phase <> "\"")
      {
        True -> Nil
        False -> {
          process.sleep(25)
          wait_phase(base_url, instance_id, expected_phase, attempts - 1)
        }
      }
    }
  }
}

fn wait_sse_data(conn: http_client.SseConnection, timeout_ms: Int) -> String {
  case http_client.sse_receive(conn, timeout_ms) {
    http_client.SseData(data) -> data
    http_client.SseClosed -> panic as "SSE closed"
    http_client.SseTimeout -> wait_sse_data(conn, timeout_ms)
  }
}

fn assert_ok(value: Result(a, e)) -> a {
  case value {
    Ok(v) -> v
    Error(e) -> panic as string.inspect(e)
  }
}
