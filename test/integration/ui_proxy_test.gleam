import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/string
import gleeunit
import gleeunit/should
import port_helpers
import saar/app_state
import saar/bridge/http_client
import saar/config_loader
import saar/core/root_supervisor
import saar/core/supervisor_names
import saar/net/tcp_listener
import saar/profiles_sources
import saar/types/config as types_config
import simplifile

const api_key = "test-key"

const host = "127.0.0.1"

const default_config_path = "test/fixtures/config/test_config.toml"

pub fn main() {
  gleeunit.main()
}

pub fn proxy_ui_agui_test() {
  let base_url = start_saar()

  let instance_id = "inst-ui-health-1"
  create_agent(base_url, "echo_server", instance_id)
  wait_phase(base_url, instance_id, "ready_continuous", 300)

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/agents/" <> instance_id <> "/ui/health",
      auth_headers(),
      option.None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(200)
  should.equal(string.contains(resp.body, "healthy"), True)
}

pub fn ui_proxy_auth_required_test() {
  let base_url = start_saar()

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/agents/inst-any/ui/health",
      dict.new(),
      option.None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(401)
}

pub fn proxy_ui_server_down_test() {
  let base_url = start_saar()

  let instance_id = "inst-ui-down-1"
  create_agent(base_url, "echo_server", instance_id)
  wait_phase(base_url, instance_id, "ready_continuous", 300)

  http_client.request_sync_string(
    http.Post,
    base_url <> "/sys/agents/" <> instance_id <> "/stop",
    auth_headers(),
    option.None,
    5000,
    1024 * 1024,
  )
  |> assert_ok

  wait_phase(base_url, instance_id, "stopped", 300)

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/agents/" <> instance_id <> "/ui/health",
      auth_headers(),
      option.None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(502)
}

pub fn ui_proxy_upstream_not_client_controlled_test() {
  let base_url = start_saar()

  let instance_id = "inst-ui-headers-1"
  create_agent(base_url, "echo_server", instance_id)
  wait_phase(base_url, instance_id, "ready_continuous", 300)

  let headers =
    auth_headers()
    |> dict.insert("x-saar-upstream", "http://evil.invalid")

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/agents/" <> instance_id <> "/ui/headers",
      headers,
      option.None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(200)
  // Not an open proxy: only allowlisted headers are forwarded.
  should.equal(string.contains(resp.body, "x-saar-upstream"), False)
}

pub fn ui_proxy_does_not_forward_authorization_test() {
  let base_url = start_saar()

  let instance_id = "inst-ui-auth-1"
  create_agent(base_url, "echo_server", instance_id)
  wait_phase(base_url, instance_id, "ready_continuous", 300)

  let headers =
    auth_headers()
    |> dict.insert("cookie", "session=secret")

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/agents/" <> instance_id <> "/ui/headers",
      headers,
      option.None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(200)

  let upstream_headers = decode_headers_object(resp.body)

  should.equal(
    dict.get(upstream_headers, "authorization")
      |> option.from_result,
    option.None,
  )
  should.equal(
    dict.get(upstream_headers, "cookie") |> option.from_result,
    option.None,
  )

  // Business context headers are injected.
  should.equal(
    dict.get(upstream_headers, "x-saar-instance-id")
      |> option.from_result,
    option.Some(instance_id),
  )
  should.equal(
    dict.get(upstream_headers, "x-saar-profile-id")
      |> option.from_result,
    option.Some("echo_server"),
  )
}

pub fn ui_proxy_does_not_add_cors_headers_test() {
  let base_url = start_saar()

  let instance_id = "inst-ui-cors-1"
  create_agent(base_url, "echo_server", instance_id)
  wait_phase(base_url, instance_id, "ready_continuous", 300)

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/agents/" <> instance_id <> "/ui/health",
      auth_headers(),
      option.None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(200)
  should.equal(has_header(resp.headers, "access-control-allow-origin"), False)
  should.equal(
    has_header(resp.headers, "access-control-allow-credentials"),
    False,
  )
}

pub fn ui_proxy_problem_details_does_not_leak_secrets_test() {
  let base_url = start_saar()

  let instance_id = "inst-ui-secrets-1"
  create_agent(base_url, "echo_server", instance_id)
  wait_phase(base_url, instance_id, "ready_continuous", 300)

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/agents/" <> instance_id <> "/ui/big?size=10485761",
      auth_headers(),
      option.None,
      5000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(502)
  should.equal(string.contains(resp.body, api_key), False)
  should.equal(string.contains(resp.body, "Bearer"), False)
}

pub fn ui_proxy_rejects_path_traversal_test() {
  let base_url = start_saar()

  let resp1 =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/agents/inst-any/ui/../health",
      auth_headers(),
      option.None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp1.status |> should.equal(400)

  let resp2 =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/agents/inst-any/ui/%2e%2e/health",
      auth_headers(),
      option.None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp2.status |> should.equal(400)
}

pub fn ui_proxy_invalid_instance_id_test() {
  let base_url = start_saar()

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/agents/!bad!/ui/health",
      auth_headers(),
      option.None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(400)
  should.equal(string.contains(resp.body, "invalid instance id"), True)
}

pub fn ui_proxy_unknown_instance_returns_404_test() {
  let base_url = start_saar()

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/agents/inst-missing/ui/health",
      auth_headers(),
      option.None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(404)
}

pub fn ui_proxy_rejects_non_http_profile_test() {
  let base_url = start_saar()

  let instance_id = "inst-ui-non-http-1"
  create_agent(base_url, "runner_only_continuous", instance_id)
  wait_phase(base_url, instance_id, "ready_continuous", 300)

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/agents/" <> instance_id <> "/ui/health",
      auth_headers(),
      option.None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(400)
  should.equal(string.contains(resp.body, "profile is not http-capable"), True)
}

pub fn ui_proxy_invalid_base_url_returns_400_test() {
  let base_url = start_saar()

  let instance_id = "inst-ui-bad-base-url-1"
  create_agent(base_url, "bad_base_url", instance_id)
  wait_phase(base_url, instance_id, "ready_continuous", 300)

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/agents/" <> instance_id <> "/ui/health",
      auth_headers(),
      option.None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(400)
  should.equal(string.contains(resp.body, "invalid base_url"), True)
}

pub fn ui_proxy_request_body_too_large_returns_413_test() {
  let base_url = start_saar()

  let instance_id = "inst-ui-body-too-large-1"
  create_agent(base_url, "echo_server", instance_id)
  wait_phase(base_url, instance_id, "ready_continuous", 300)

  // Oversized body relative to test config's max_request_body_bytes.
  let big = string.repeat("a", 2_000_000)

  let resp =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/agents/" <> instance_id <> "/ui/echo",
      dict.insert(auth_headers(), "content-type", "text/plain"),
      option.Some(big),
      5000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(413)
}

pub fn ui_proxy_rejects_websocket_upgrade_test() {
  let base_url = start_saar()

  let headers =
    auth_headers()
    |> dict.insert("upgrade", "websocket")
    |> dict.insert("connection", "Upgrade")

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/agents/inst-any/ui/health",
      headers,
      option.None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(400)
  should.equal(
    string.contains(resp.body, "\"code\":\"websocket_not_supported\""),
    True,
  )
}

pub fn ui_proxy_binary_passthrough_test() {
  let base_url = start_saar()

  let instance_id = "inst-ui-bin-1"
  create_agent(base_url, "echo_server", instance_id)
  wait_phase(base_url, instance_id, "ready_continuous", 300)

  let resp =
    http_client.request_sync_bits(
      http.Get,
      base_url <> "/agents/" <> instance_id <> "/ui/bin?size=16",
      auth_headers(),
      option.None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  let http_client.HttpResponseBits(status: status, body: body, ..) = resp
  status |> should.equal(200)
  bit_array.byte_size(body) |> should.equal(16)
}

fn start_saar() -> String {
  port_helpers.ensure_wrapper_path()

  let cfg0 =
    config_loader.load_from_path(
      "./test/fixtures/config/test_config.toml",
      fn(name) {
        case name {
          "SAAR_TEST_API_KEY" -> Ok(api_key)
          _ -> Error(Nil)
        }
      },
      simplifile.read,
    )
    |> assert_ok

  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)
  tcp_listener.close(listener)

  let names = supervisor_names.new_names_with_suffix(int.to_string(port))

  let cfg = types_config.SaarConfig(..cfg0, server_port: port)

  let profiles = profiles_sources.load_profiles_from_sources(cfg) |> assert_ok

  let state =
    app_state.AppState(
      config: cfg,
      config_path: default_config_path,
      initial_profiles: profiles,
    )
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
    option.Some(body),
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
          option.None,
          1000,
          1024 * 1024,
        )
        |> assert_ok

      case resp.status {
        200 -> Nil
        _ -> {
          let msg =
            "Unexpected status: "
            <> int.to_string(resp.status)
            <> " body="
            <> resp.body
          panic as msg
        }
      }

      case string.contains(resp.body, "\"phase\":\"failed\"") {
        True -> {
          let msg = "Agent failed: " <> resp.body
          panic as msg
        }
        False -> Nil
      }

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

fn decode_headers_object(body: String) -> dict.Dict(String, String) {
  let assert Ok(dynamic_body) = json.parse(body, decode.dynamic)

  let decoder = {
    use headers <- decode.field(
      "headers",
      decode.dict(decode.string, decode.string),
    )
    decode.success(headers)
  }

  let assert Ok(headers) = decode.run(dynamic_body, decoder)
  headers
}

fn has_header(headers: List(#(String, String)), key: String) -> Bool {
  list.any(headers, fn(pair) { string.lowercase(pair.0) == key })
}

fn assert_ok(value: Result(a, e)) -> a {
  case value {
    Ok(v) -> v
    Error(e) -> panic as string.inspect(e)
  }
}
