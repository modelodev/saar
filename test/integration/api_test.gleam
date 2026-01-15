import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/list
import gleam/otp/actor
import httpp/streaming

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
import sad/types/core as types_core
import sad/types/profile as types_profile
import simplifile

const api_key = "test-key"

const host = "127.0.0.1"

pub fn main() {
  gleeunit.main()
}

pub fn auth_required_elsewhere() {
  let base_url = start_sad()

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/sys/agents",
      dict.new(),
      None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(401)
}

pub fn get_health_ok_without_auth() {
  let base_url = start_sad()

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/health",
      dict.new(),
      None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(200)
}

pub fn get_health_ready_requires_profiles() {
  // When profiles are loaded, /health/ready must return 200.
  let base_url = start_sad()

  let ok =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/health/ready",
      dict.new(),
      None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  ok.status |> should.equal(200)

  // With zero profiles, /health/ready must return 503.
  let base_url_empty = start_sad_with_profiles(dict.new())

  let not_ready =
    http_client.request_sync_string(
      http.Get,
      base_url_empty <> "/health/ready",
      dict.new(),
      None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  not_ready.status |> should.equal(503)
}

pub fn post_sys_agents_201_provisioning() {
  let base_url = start_sad()

  let instance_id = "inst-sys-create-1"

  let body =
    "{"
    <> "\"profile_id\":\"echo_cli\","
    <> "\"instance_id\":\""
    <> instance_id
    <> "\""
    <> "}"

  let resp =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/sys/agents",
      dict.insert(auth_headers(), "content-type", "application/json"),
      Some(body),
      5000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(201)
}

pub fn get_sys_agents_lists() {
  let base_url = start_sad()

  let instance_id = "inst-sys-list-1"
  create_agent(base_url, "echo_cli", instance_id)

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/sys/agents",
      auth_headers(),
      None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(200)
  should.equal(string.contains(resp.body, instance_id), True)
}

pub fn get_sys_agents_includes_a2a_base_url() {
  let base_url = start_sad()

  let instance_id = "inst-sys-a2a-1"
  create_agent(base_url, "echo_cli", instance_id)

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/sys/agents",
      auth_headers(),
      None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(200)
  should.equal(string.contains(resp.body, "\"a2a_base_url\""), True)
  should.equal(string.contains(resp.body, "/instances/" <> instance_id), True)
}

pub fn logs_stream_takeover() {
  // Reduce keep-alive interval so the test completes quickly.
  let base_url = start_sad_with_sse_keep_alive_interval_ms(50)

  // Validate keep-alive format is emitted as a comment.
  let quiet_id = "inst-sys-logs-keepalive-1"
  create_agent(base_url, "runner_only_continuous", quiet_id)
  wait_phase(base_url, quiet_id, "ready_continuous", 300)

  let keep_alive_url = base_url <> "/sys/agents/" <> quiet_id <> "/logs/stream"

  let raw = open_raw_sse_get(keep_alive_url, auth_headers(), 2000)
  wait_raw_sse_contains(raw, ": keep-alive\n\n", 50)
  close_raw_sse(raw)

  // Validate takeover + payload fields.
  let instance_id = "inst-sys-logs-1"
  create_agent(base_url, "greedy_logger", instance_id)
  wait_phase(base_url, instance_id, "ready_continuous", 300)

  let url = base_url <> "/sys/agents/" <> instance_id <> "/logs/stream"

  let conn1 =
    http_client.open_sse(http.Get, url, auth_headers(), None, 2000) |> assert_ok
  let first = wait_sse_data(conn1, 2000)
  assert_log_payload_fields(first)

  let conn2 =
    http_client.open_sse(http.Get, url, auth_headers(), None, 2000) |> assert_ok
  let second = wait_sse_data(conn2, 2000)
  assert_log_payload_fields(second)

  // After takeover, new events should go to the latest subscriber.
  case http_client.sse_receive(conn1, 200) {
    http_client.SseTimeout -> Nil
    http_client.SseClosed -> Nil
    http_client.SseData(_) -> panic as "Expected log stream takeover"
  }

  http_client.close_sse(conn1)
  http_client.close_sse(conn2)
}

pub fn post_reload_profiles_auth_required() {
  let base_url = start_sad()

  let resp =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/sys/reload-profiles",
      dict.new(),
      None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(401)
}

pub fn post_reload_profiles_success() {
  let root = "build/test-workspaces/api-reload-success"
  reset_profiles_source(root)

  let base_url = start_sad_with_profile_source_dir(root)

  let resp =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/sys/reload-profiles",
      auth_headers(),
      None,
      5000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(200)
  should.equal(string.contains(resp.body, "\"count\""), True)
  should.equal(string.contains(resp.body, "\"profile_ids\""), True)
}

pub fn post_reload_profiles_io_error() {
  let root = "build/test-workspaces/api-reload-io-error"
  reset_profiles_source(root)

  let base_url = start_sad_with_profile_source_dir(root)

  // Simulate IO error by removing the source directory.
  let _ = simplifile.delete(file_or_dir_at: root)

  let resp =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/sys/reload-profiles",
      auth_headers(),
      None,
      5000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(500)
}

pub fn post_reload_profiles_invalid_json() {
  let root = "build/test-workspaces/api-reload-invalid-json"
  reset_profiles_source(root)

  // Break one profile.
  simplifile.write(to: root <> "/profiles/broken.json", contents: "{not json")
  |> assert_ok

  let base_url = start_sad_with_profile_source_dir(root)

  let resp =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/sys/reload-profiles",
      auth_headers(),
      None,
      5000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(500)
}

pub fn post_reload_profiles_keeps_old_on_error() {
  let root = "build/test-workspaces/api-reload-keeps-old"
  reset_profiles_source(root)

  let base_url = start_sad_with_profile_source_dir(root)

  // Ensure the initial profile set is visible.
  let before =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/sys/profiles",
      auth_headers(),
      None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  before.status |> should.equal(200)
  should.equal(string.contains(before.body, "echo_cli"), True)

  // Now corrupt the source and reload.
  simplifile.write(to: root <> "/profiles/broken.json", contents: "{not json")
  |> assert_ok

  let reload =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/sys/reload-profiles",
      auth_headers(),
      None,
      5000,
      1024 * 1024,
    )
    |> assert_ok

  reload.status |> should.equal(500)

  // The old set must still be served.
  let after =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/sys/profiles",
      auth_headers(),
      None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  after.status |> should.equal(200)
  should.equal(string.contains(after.body, "echo_cli"), True)
}

pub fn post_reload_profiles_does_not_affect_existing_instances() {
  let root = "build/test-workspaces/api-reload-existing"
  reset_profiles_source(root)

  let base_url = start_sad_with_profile_source_dir(root)

  let instance_id = "inst-reload-existing-1"
  create_agent(base_url, "echo_cli", instance_id)
  wait_phase(base_url, instance_id, "ready_transient", 300)

  // Break reload and ensure the instance is still queryable.
  simplifile.write(to: root <> "/profiles/broken.json", contents: "{not json")
  |> assert_ok

  let reload =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/sys/reload-profiles",
      auth_headers(),
      None,
      5000,
      1024 * 1024,
    )
    |> assert_ok

  reload.status |> should.equal(500)

  let status =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/sys/agents/" <> instance_id <> "/status",
      auth_headers(),
      None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  status.status |> should.equal(200)
  should.equal(string.contains(status.body, "\"phase\""), True)
}

pub fn get_sys_profiles_returns_meta() {
  let base_url = start_sad()

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/sys/profiles",
      auth_headers(),
      None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(200)

  // Must not leak the full runner/tool config.
  should.equal(string.contains(resp.body, "\"tool_config\""), False)
  should.equal(string.contains(resp.body, "\"runtime\""), False)
  should.equal(string.contains(resp.body, "\"meta\""), True)
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

pub fn post_agents_interact_timeout_then_next_request_ok() {
  let base_url = start_sad()

  let timed_out_id = "inst-timeout-then-ok-1"
  create_agent(base_url, "echo_cli", timed_out_id)
  wait_phase(base_url, timed_out_id, "ready_transient", 200)

  let body =
    "{"
    <> "\"capability\":\"echo\","
    <> "\"inputs\":{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]},"
    <> "\"context\":{\"trace_id\":\"trace-timeout-then-ok-1\"}"
    <> "}"

  let resp1 =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/agents/" <> timed_out_id <> "/interact",
      dict.insert(auth_headers(), "content-type", "application/json"),
      Some(body),
      5000,
      1024 * 1024,
    )
    |> assert_ok

  resp1.status |> should.equal(504)

  // After a timeout, the gateway must still be able to serve subsequent requests.
  let ok_id = "inst-timeout-then-ok-2"
  create_agent(base_url, "echo_server", ok_id)
  wait_phase(base_url, ok_id, "ready_continuous", 200)

  let body2 =
    "{"
    <> "\"capability\":\"echo\","
    <> "\"inputs\":{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]},"
    <> "\"context\":{\"trace_id\":\"trace-timeout-then-ok-2\"}"
    <> "}"

  let resp2 =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/agents/" <> ok_id <> "/interact",
      dict.insert(auth_headers(), "content-type", "application/json"),
      Some(body2),
      5000,
      1024 * 1024,
    )
    |> assert_ok

  resp2.status |> should.equal(200)
  should.equal(string.contains(resp2.body, "\"trace_id\""), True)
}

pub fn post_agents_interact_streaming_a2ui_message_shape() {
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

pub fn post_agents_interact_streaming_a2ui_disconnect_is_terminal() {
  let base_url = start_sad()

  let instance_id = "inst-a2ui-terminal-1"
  create_agent(base_url, "streaming_echo", instance_id)

  wait_phase(base_url, instance_id, "ready_transient", 200)

  let url = base_url <> "/agents/" <> instance_id <> "/interact"

  let body =
    "{"
    <> "\"capability\":\"echo\","
    <> "\"inputs\":{\"messages\":[{\"role\":\"user\",\"content\":\"hello world\"}]},"
    <> "\"context\":{\"trace_id\":\"trace-a2ui-terminal-1\"}"
    <> "}"

  let headers =
    auth_headers()
    |> dict.insert("content-type", "application/json")
    |> dict.insert("x-sad-ui-protocol", "a2ui/v0.8")

  let conn =
    http_client.open_sse(http.Post, url, headers, Some(body), 2000) |> assert_ok

  wait_a2ui_and_then_close(conn, False, 40)
}

fn wait_a2ui_and_then_close(
  conn: http_client.SseConnection,
  saw_begin_rendering: Bool,
  attempts: Int,
) -> Nil {
  case attempts {
    0 -> panic as "Timed out waiting for A2UI stream to close"

    _ ->
      case http_client.sse_receive(conn, 250) {
        http_client.SseTimeout ->
          wait_a2ui_and_then_close(conn, saw_begin_rendering, attempts - 1)

        http_client.SseClosed -> {
          saw_begin_rendering |> should.equal(True)
          http_client.close_sse(conn)
        }

        http_client.SseData(data) -> {
          // A2UI frames are not wrapped in AG-UI envelopes.
          should.equal(string.contains(data, "\"type\":"), False)

          let saw =
            saw_begin_rendering || string.contains(data, "\"beginRendering\"")

          wait_a2ui_and_then_close(conn, saw, attempts - 1)
        }
      }
  }
}

pub fn get_agent_card_auth_required() {
  let base_url = start_sad()

  let url =
    base_url <> "/instances/inst-agent-card-auth-1/.well-known/agent-card.json"

  let resp =
    http_client.request_sync_string(
      http.Get,
      url,
      dict.new(),
      None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(401)
}

pub fn post_a2a_send_auth_required() {
  let base_url = start_sad()

  let url = base_url <> "/instances/inst-a2a-send-auth-1/a2a/message:send"

  let resp =
    http_client.request_sync_string(
      http.Post,
      url,
      dict.new(),
      None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(401)
}

pub fn post_a2a_stream_auth_required() {
  let base_url = start_sad()

  let url = base_url <> "/instances/inst-a2a-stream-auth-1/a2a/message:stream"

  let resp =
    http_client.request_sync_string(
      http.Post,
      url,
      dict.new(),
      None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(401)
}

pub fn post_a2a_message_send_ok() {
  let base_url = start_sad()

  let instance_id = "inst-a2a-send-1"
  create_agent(base_url, "echo_cli", instance_id)
  wait_phase(base_url, instance_id, "ready_transient", 200)

  let url = base_url <> "/instances/" <> instance_id <> "/a2a/message:send"

  let body =
    "{"
    <> "\"message\":{"
    <> "\"messageId\":\"msg-a2a-1\","
    <> "\"role\":\"user\","
    <> "\"parts\":[{\"text\":\"hi\"}]"
    <> "}"
    <> "}"

  let resp =
    http_client.request_sync_string(
      http.Post,
      url,
      dict.insert(auth_headers(), "content-type", "application/json"),
      Some(body),
      5000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(200)
  should.equal(string.contains(resp.body, "\"result\""), True)
  should.equal(string.contains(resp.body, "\"contextId\""), True)
  should.equal(string.contains(resp.body, "\"state\":\"completed\""), True)
}

pub fn post_a2a_message_stream_ok() {
  let base_url = start_sad_with_sse_keep_alive_interval_ms(50)

  let instance_id = "inst-a2a-stream-1"
  create_agent(base_url, "streaming_echo", instance_id)
  wait_phase(base_url, instance_id, "ready_transient", 200)

  let url = base_url <> "/instances/" <> instance_id <> "/a2a/message:stream"

  let body =
    "{"
    <> "\"message\":{"
    <> "\"messageId\":\"msg-a2a-stream-1\","
    <> "\"role\":\"user\","
    <> "\"parts\":[{\"text\":\"hello\"}]"
    <> "}"
    <> "}"

  let headers =
    auth_headers()
    |> dict.insert("content-type", "application/json")

  let conn =
    http_client.open_sse(http.Post, url, headers, Some(body), 2000) |> assert_ok

  let started = wait_sse_contains(conn, "\"state\":\"working\"", 40)
  should.equal(string.contains(started, "\"taskId\""), True)

  let msg = wait_sse_contains(conn, "\"role\":\"assistant\"", 80)
  should.equal(string.contains(msg, "\"text\""), True)

  let _done = wait_sse_contains(conn, "\"state\":\"completed\"", 120)
  http_client.close_sse(conn)
}

pub fn post_a2a_message_stream_a2ui_extension() {
  let base_url = start_sad_with_sse_keep_alive_interval_ms(50)

  let instance_id = "inst-a2a-a2ui-1"
  create_agent(base_url, "streaming_echo", instance_id)
  wait_phase(base_url, instance_id, "ready_transient", 200)

  let url = base_url <> "/instances/" <> instance_id <> "/a2a/message:stream"

  let body =
    "{"
    <> "\"message\":{"
    <> "\"messageId\":\"msg-a2a-a2ui-1\","
    <> "\"role\":\"user\","
    <> "\"parts\":[{\"text\":\"hello\"}]"
    <> "}"
    <> "}"

  let headers =
    auth_headers()
    |> dict.insert("content-type", "application/json")
    |> dict.insert(
      "x-a2a-extensions",
      "https://a2ui.org/a2a-extension/a2ui/v0.8",
    )

  let conn =
    http_client.open_sse(http.Post, url, headers, Some(body), 2000) |> assert_ok

  let _started = wait_sse_contains(conn, "\"state\":\"working\"", 40)

  let msg =
    wait_sse_contains(conn, "\"mimeType\":\"application/json+a2ui\"", 120)

  should.equal(string.contains(msg, "\"data\""), True)

  http_client.close_sse(conn)
}

fn wait_sse_contains(
  conn: http_client.SseConnection,
  needle: String,
  attempts: Int,
) -> String {
  case attempts {
    0 -> panic as "Timed out waiting for SSE payload"

    _ ->
      case http_client.sse_receive(conn, 250) {
        http_client.SseTimeout -> wait_sse_contains(conn, needle, attempts - 1)

        http_client.SseClosed -> panic as "SSE closed"

        http_client.SseData(data) ->
          case string.contains(data, needle) {
            True -> data
            False -> wait_sse_contains(conn, needle, attempts - 1)
          }
      }
  }
}

fn load_cfg0() -> types_config.SadConfig {
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
}

fn start_sad_with_cfg_and_profiles(
  cfg0: types_config.SadConfig,
  initial_profiles: dict.Dict(types_core.ProfileId, types_profile.Profile),
) -> String {
  port_helpers.ensure_wrapper_path()

  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)
  tcp_listener.close(listener)

  let names = supervisor_names.new_names_with_suffix(int.to_string(port))

  let cfg = types_config.SadConfig(..cfg0, server_port: port)

  let state =
    app_state.AppState(config: cfg, initial_profiles: initial_profiles)

  let assert Ok(actor.Started(..)) = root_supervisor.start(state, names)

  "http://" <> host <> ":" <> int.to_string(port)
}

fn start_sad_with_profiles(
  initial_profiles: dict.Dict(types_core.ProfileId, types_profile.Profile),
) -> String {
  start_sad_with_cfg_and_profiles(load_cfg0(), initial_profiles)
}

fn cfg_with_sse_keep_alive_interval_ms(
  cfg0: types_config.SadConfig,
  keep_alive_ms: Int,
) -> types_config.SadConfig {
  let types_config.SadConfig(stream: stream0, ..) = cfg0
  let stream1 =
    types_config.StreamConfig(
      ..stream0,
      sse_keep_alive_interval_ms: keep_alive_ms,
    )

  types_config.SadConfig(..cfg0, stream: stream1)
}

fn start_sad_with_sse_keep_alive_interval_ms(keep_alive_ms: Int) -> String {
  let cfg0 = load_cfg0()
  let cfg1 = cfg_with_sse_keep_alive_interval_ms(cfg0, keep_alive_ms)
  let profiles = profiles_sources.load_profiles_from_sources(cfg1) |> assert_ok
  start_sad_with_cfg_and_profiles(cfg1, profiles)
}

fn start_sad() -> String {
  let cfg0 = load_cfg0()
  let profiles = profiles_sources.load_profiles_from_sources(cfg0) |> assert_ok
  start_sad_with_cfg_and_profiles(cfg0, profiles)
}

fn start_sad_with_profile_source_dir(root: String) -> String {
  let cfg0 = load_cfg0()

  let types_config.SadConfig(profiles: profiles0, ..) = cfg0

  let profiles_cfg =
    types_config.ProfilesConfig(..profiles0, sources: [
      types_config.ProfileSourceDir(path: root),
    ])

  let cfg1 = types_config.SadConfig(..cfg0, profiles: profiles_cfg)

  let profiles = profiles_sources.load_profiles_from_sources(cfg1) |> assert_ok
  start_sad_with_cfg_and_profiles(cfg1, profiles)
}

fn reset_profiles_source(root: String) -> Nil {
  let _ = simplifile.delete(file_or_dir_at: root)

  simplifile.copy_directory(at: "test/fixtures/source_local", to: root)
  |> assert_ok

  Nil
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

fn assert_log_payload_fields(payload: String) -> Nil {
  should.equal(string.contains(payload, "\"ts_ms\""), True)
  should.equal(string.contains(payload, "\"line\""), True)
  should.equal(string.contains(payload, "\"trace_id\""), True)
  Nil
}

type RawSseConnection {
  RawSseConnection(
    control: process.Subject(RawSseManagerMessage),
    events: process.Subject(RawSseEvent),
  )
}

type RawSseEvent {
  RawSseChunk(String)
  RawSseClosed
}

type RawSseManagerMessage {
  Shutdown
}

fn open_raw_sse_get(
  url: String,
  headers: dict.Dict(String, String),
  initial_response_timeout_ms: Int,
) -> RawSseConnection {
  let req0 = request.to(url) |> assert_ok

  let req1 = request.set_method(req0, http.Get)

  let req2 =
    headers
    |> dict.to_list
    |> list.fold(req1, fn(r, pair) { request.set_header(r, pair.0, pair.1) })

  let req =
    req2
    |> request.set_header("accept", "text/event-stream")
    |> request.set_header("connection", "keep-alive")

  let req_bytes = req |> request.map(bytes_tree.from_string)

  let events: process.Subject(RawSseEvent) = process.new_subject()

  let handler =
    streaming.StreamingRequestHandler(
      req: req_bytes,
      initial_state: Nil,
      on_data: fn(message, _response, state) {
        raw_sse_on_data(events, message)
        Ok(state)
      },
      on_message: fn(message, _response, _state) {
        case message {
          Shutdown -> {
            process.send(events, RawSseClosed)
            Error(process.Normal)
          }
        }
      },
      on_error: fn(_err, _response, _state) {
        process.send(events, RawSseClosed)
        Error(process.Normal)
      },
      initial_response_timeout: int.max(initial_response_timeout_ms, 1),
    )

  let started = streaming.start(handler) |> assert_ok
  let #(_client_ref, control) = started
  RawSseConnection(control: control, events: events)
}

fn close_raw_sse(conn: RawSseConnection) -> Nil {
  process.send(conn.control, Shutdown)
}

fn wait_raw_sse_contains(
  conn: RawSseConnection,
  needle: String,
  attempts: Int,
) -> Nil {
  wait_raw_sse_contains_loop(conn, needle, "", attempts)
}

fn wait_raw_sse_contains_loop(
  conn: RawSseConnection,
  needle: String,
  buffer: String,
  attempts: Int,
) -> Nil {
  case attempts {
    0 -> panic as "Timed out waiting for SSE keep-alive"

    _ ->
      case process.receive(conn.events, 100) {
        Ok(RawSseChunk(chunk)) -> {
          let updated = buffer <> chunk
          proceed_or_wait(
            string.contains(updated, needle),
            conn,
            needle,
            updated,
            attempts - 1,
          )
        }

        Ok(RawSseClosed) -> panic as "SSE closed"

        Error(_) ->
          wait_raw_sse_contains_loop(conn, needle, buffer, attempts - 1)
      }
  }
}

fn proceed_or_wait(
  found: Bool,
  conn: RawSseConnection,
  needle: String,
  buffer: String,
  attempts: Int,
) -> Nil {
  case found {
    True -> Nil
    False -> wait_raw_sse_contains_loop(conn, needle, buffer, attempts)
  }
}

fn raw_sse_on_data(
  events: process.Subject(RawSseEvent),
  message: streaming.Message,
) -> Nil {
  case message {
    streaming.Done -> process.send(events, RawSseClosed)

    streaming.Bits(bits) ->
      case bit_array.to_string(bits) {
        Ok(chunk) -> process.send(events, RawSseChunk(chunk))
        Error(_) -> process.send(events, RawSseClosed)
      }
  }
}

fn assert_ok(value: Result(a, e)) -> a {
  case value {
    Ok(v) -> v
    Error(e) -> panic as string.inspect(e)
  }
}
