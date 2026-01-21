// Shared helpers for deferred task integration tests.
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/json
import gleam/option
import gleam/string
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
import saar/types/core as types_core
import saar/types/profile as types_profile
import simplifile
import test_assertions

const api_key = "test-key"

const host = "127.0.0.1"

const default_config_path = "test/fixtures/config/test_config.toml"

pub fn load_cfg0() -> types_config.SaarConfig {
  config_loader.load_from_path(
    default_config_path,
    fn(name) {
      case name {
        "SAAR_TEST_API_KEY" -> Ok(api_key)
        _ -> Error(Nil)
      }
    },
    simplifile.read,
  )
  |> test_assertions.assert_ok
}

pub fn start_saar() -> String {
  let cfg0 = load_cfg0()
  start_saar_with_cfg(cfg0)
}

pub fn start_saar_with_cfg(cfg0: types_config.SaarConfig) -> String {
  let profiles = profiles_sources.load_profiles_from_sources(cfg0)
  let initial_profiles = test_assertions.assert_ok(profiles)
  start_saar_with_cfg_and_profiles(cfg0, initial_profiles)
}

pub fn auth_headers() -> dict.Dict(String, String) {
  dict.from_list([#("authorization", "Bearer " <> api_key)])
}

pub fn create_agent(
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
  |> test_assertions.assert_ok
  |> fn(resp) { resp.status |> should.equal(201) }

  Nil
}

pub fn wait_phase(
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
        |> test_assertions.assert_ok

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

pub fn post_deferred(
  base_url: String,
  instance_id: String,
  capability: String,
  trace_id: String,
  content: String,
) -> http_client.HttpResponse {
  let body =
    "{"
    <> "\"capability\":\""
    <> capability
    <> "\","
    <> "\"inputs\":{\"messages\":[{\"role\":\"user\",\"content\":\""
    <> content
    <> "\"}]},"
    <> "\"context\":{\"trace_id\":\""
    <> trace_id
    <> "\"}"
    <> "}"

  http_client.request_sync_string(
    http.Post,
    base_url <> "/agents/" <> instance_id <> "/interact",
    dict.insert(auth_headers(), "content-type", "application/json"),
    option.Some(body),
    5000,
    1024 * 1024,
  )
  |> test_assertions.assert_ok
}

pub fn get_task_raw(
  base_url: String,
  task_id: String,
) -> http_client.HttpResponse {
  http_client.request_sync_string(
    http.Get,
    base_url <> "/tasks/" <> task_id,
    auth_headers(),
    option.None,
    2000,
    1024 * 1024,
  )
  |> test_assertions.assert_ok
}

pub fn get_task(base_url: String, task_id: String) -> http_client.HttpResponse {
  let resp = get_task_raw(base_url, task_id)
  resp.status |> should.equal(200)
  resp
}

pub fn delete_task(
  base_url: String,
  task_id: String,
) -> http_client.HttpResponse {
  http_client.request_sync_string(
    http.Delete,
    base_url <> "/tasks/" <> task_id,
    auth_headers(),
    option.None,
    2000,
    1024 * 1024,
  )
  |> test_assertions.assert_ok
}

pub fn wait_task_state(
  base_url: String,
  task_id: String,
  expected_state: String,
  attempts: Int,
) -> String {
  case attempts {
    0 -> panic as "Timed out waiting for task state"

    _ -> {
      let resp = get_task(base_url, task_id)
      let state = decode_task_state(resp.body)

      case state == expected_state {
        True -> resp.body
        False -> {
          process.sleep(50)
          wait_task_state(base_url, task_id, expected_state, attempts - 1)
        }
      }
    }
  }
}

pub fn decode_task_id(body: String) -> String {
  let dynamic_body = parse_dynamic(body)
  let decoder = {
    use task_id <- decode.field("task_id", decode.string)
    decode.success(task_id)
  }
  decode.run(dynamic_body, decoder) |> test_assertions.assert_ok
}

pub fn decode_task_state(body: String) -> String {
  let dynamic_body = parse_dynamic(body)
  let decoder = {
    use state <- decode.field("state", decode.string)
    decode.success(state)
  }
  decode.run(dynamic_body, decoder) |> test_assertions.assert_ok
}

pub fn wait_for_sse_data(
  conn: http_client.SseConnection,
  attempts: Int,
) -> String {
  case attempts {
    0 -> panic as "Timed out waiting for SSE data"

    _ ->
      case http_client.sse_receive(conn, 200) {
        http_client.SseTimeout -> wait_for_sse_data(conn, attempts - 1)
        http_client.SseClosed -> panic as "SSE closed before data"
        http_client.SseData(data) -> data
      }
  }
}

pub fn wait_for_sse_close(conn: http_client.SseConnection, attempts: Int) -> Nil {
  case attempts {
    0 -> panic as "Timed out waiting for SSE close"

    _ ->
      case http_client.sse_receive(conn, 200) {
        http_client.SseTimeout -> wait_for_sse_close(conn, attempts - 1)
        http_client.SseClosed -> Nil
        http_client.SseData(_) -> wait_for_sse_close(conn, attempts - 1)
      }
  }
}

fn start_saar_with_cfg_and_profiles(
  cfg0: types_config.SaarConfig,
  initial_profiles: dict.Dict(types_core.ProfileId, types_profile.Profile),
) -> String {
  port_helpers.ensure_wrapper_path()

  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)
  tcp_listener.close(listener)

  let names = supervisor_names.new_names_with_suffix(int.to_string(port))

  let cfg = types_config.SaarConfig(..cfg0, server_port: port)
  let state =
    app_state.AppState(
      config: cfg,
      config_path: default_config_path,
      initial_profiles: initial_profiles,
    )

  let assert Ok(_) = root_supervisor.start(state, names)

  "http://" <> host <> ":" <> int.to_string(port)
}

fn parse_dynamic(body: String) {
  json.parse(body, decode.dynamic) |> test_assertions.assert_ok
}
