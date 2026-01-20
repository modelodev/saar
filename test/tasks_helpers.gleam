// Shared helpers for deferred task integration tests.
import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/int
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

pub fn load_cfg0() -> types_config.SaarConfig {
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

fn start_saar_with_cfg_and_profiles(
  cfg0: types_config.SaarConfig,
  initial_profiles: dict.Dict(types_core.ProfileId, types_profile.Profile),
) -> String {
  port_helpers.ensure_wrapper_path()

  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)
  tcp_listener.close(listener)

  let names = supervisor_names.new_names_with_suffix(int.to_string(port))

  let cfg = types_config.SaarConfig(..cfg0, server_port: port)
  let state = app_state.AppState(config: cfg, initial_profiles: initial_profiles)

  let assert Ok(_) = root_supervisor.start(state, names)

  "http://" <> host <> ":" <> int.to_string(port)
}
