import envoy
import gleam/dict
import gleam/http
import gleam/int
import gleam/option.{type Option, None, Some}
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
import test_assertions

const api_key = "test-key"

const host = "127.0.0.1"

pub fn main() {
  gleeunit.main()
}

pub fn reload_applies_valid_config_without_restart() {
  let label = "valid"
  let config_path = config_path_for(label)
  let root_base = profiles_root_for(label, "base")
  let root_alt = profiles_root_for(label, "alt")

  ensure_test_workspace_dir()
  envoy.set("SAAR_TEST_API_KEY", api_key)

  reset_profiles_source(root_base)
  reset_profiles_source(root_alt)
  write_profile(root_alt, "reload_new")

  write_config(config_path, root_base, "", None)
  let base_url = start_saar(config_path)

  write_config(config_path, root_alt, "", None)

  let reload = post_reload(base_url)
  reload.status |> should.equal(200)

  let profiles = get_profiles(base_url)
  should.equal(string.contains(profiles.body, "reload_new"), True)

  envoy.unset("SAAR_TEST_API_KEY")
}

pub fn reload_invalid_config_keeps_previous_values() {
  let label = "invalid-config"
  let config_path = config_path_for(label)
  let root_base = profiles_root_for(label, "base")

  ensure_test_workspace_dir()
  envoy.set("SAAR_TEST_API_KEY", api_key)

  reset_profiles_source(root_base)
  write_config(config_path, root_base, "", None)
  let base_url = start_saar(config_path)

  let before = get_profiles(base_url)
  should.equal(string.contains(before.body, "echo_cli"), True)

  write_config(config_path, root_base, "unknown = 1\n", None)

  let reload = post_reload(base_url)
  reload.status |> should.equal(400)

  let after = get_profiles(base_url)
  should.equal(string.contains(after.body, "echo_cli"), True)

  envoy.unset("SAAR_TEST_API_KEY")
}

pub fn reload_invalid_config_logs_error() {
  let label = "invalid-logs"
  let config_path = config_path_for(label)
  let root_base = profiles_root_for(label, "base")

  ensure_test_workspace_dir()
  envoy.set("SAAR_TEST_API_KEY", api_key)

  reset_profiles_source(root_base)
  write_config(config_path, root_base, "", None)
  let base_url = start_saar(config_path)

  write_config(config_path, root_base, "unknown = 1\n", None)

  let reload = post_reload(base_url)
  reload.status |> should.equal(400)
  should.equal(string.contains(reload.body, "CONFIG_RELOAD_FAILED"), True)

  envoy.unset("SAAR_TEST_API_KEY")
}

pub fn reload_profiles_invalid_returns_400_with_profile_id() {
  let label = "bad-profiles"
  let config_path = config_path_for(label)
  let root_base = profiles_root_for(label, "base")
  let root_bad = profiles_root_for(label, "bad")

  ensure_test_workspace_dir()
  envoy.set("SAAR_TEST_API_KEY", api_key)

  reset_profiles_source(root_base)
  reset_profiles_source(root_bad)
  write_missing_runner_profile(root_bad, "missing_runner")

  write_config(config_path, root_base, "", None)
  let base_url = start_saar(config_path)

  write_config(config_path, root_bad, "", None)

  let reload = post_reload(base_url)
  reload.status |> should.equal(400)
  should.equal(string.contains(reload.body, "missing_runner"), True)

  envoy.unset("SAAR_TEST_API_KEY")
}

pub fn reload_config_invalid_returns_400_with_detail() {
  let label = "invalid-detail"
  let config_path = config_path_for(label)
  let root_base = profiles_root_for(label, "base")

  ensure_test_workspace_dir()
  envoy.set("SAAR_TEST_API_KEY", api_key)

  reset_profiles_source(root_base)
  write_config(config_path, root_base, "", None)
  let base_url = start_saar(config_path)

  write_config(config_path, root_base, "unknown = 1\n", None)
  let reload = post_reload(base_url)

  reload.status |> should.equal(400)
  should.equal(string.contains(reload.body, "server.unknown"), True)

  envoy.unset("SAAR_TEST_API_KEY")
}

pub fn reload_error_includes_code() {
  let label = "error-code"
  let config_path = config_path_for(label)
  let root_base = profiles_root_for(label, "base")

  ensure_test_workspace_dir()
  envoy.set("SAAR_TEST_API_KEY", api_key)

  reset_profiles_source(root_base)
  write_config(config_path, root_base, "", None)
  let base_url = start_saar(config_path)

  write_config(config_path, root_base, "unknown = 1\n", None)
  let reload = post_reload(base_url)

  reload.status |> should.equal(400)
  should.equal(string.contains(reload.body, "\"code\""), True)
  should.equal(string.contains(reload.body, "CONFIG_RELOAD_FAILED"), True)

  envoy.unset("SAAR_TEST_API_KEY")
}

fn post_reload(base_url: String) {
  http_client.request_sync_string(
    http.Post,
    base_url <> "/sys/reload",
    auth_headers(),
    None,
    5000,
    1024 * 1024,
  )
  |> assert_ok
}

fn get_profiles(base_url: String) {
  http_client.request_sync_string(
    http.Get,
    base_url <> "/sys/profiles",
    auth_headers(),
    None,
    2000,
    1024 * 1024,
  )
  |> assert_ok
}

fn start_saar(config_path: String) -> String {
  port_helpers.ensure_wrapper_path()

  let cfg0 =
    config_loader.load_from_path(config_path, envoy.get, simplifile.read)
    |> assert_ok

  let profiles = profiles_sources.load_profiles_from_sources(cfg0) |> assert_ok

  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)
  tcp_listener.close(listener)

  let names = supervisor_names.new_names_with_suffix(int.to_string(port))
  let cfg = types_config.SaarConfig(..cfg0, server_port: port)

  let state =
    app_state.AppState(
      config: cfg,
      config_path: config_path,
      initial_profiles: profiles,
    )

  let assert Ok(_) = root_supervisor.start(state, names)

  "http://" <> host <> ":" <> int.to_string(port)
}

fn write_config(
  path: String,
  profiles_root: String,
  server_extra: String,
  params_block: Option(String),
) {
  let base =
    "[server]\n"
    <> "host = \"127.0.0.1\"\n"
    <> "port = 0\n"
    <> server_extra
    <> "\n"
    <> "[auth]\n"
    <> "api_key = \"${SAAR_TEST_API_KEY}\"\n"
    <> "\n"
    <> "[profiles]\n"
    <> "sources = [\n"
    <> "  {type = \"dir\", path = \""
    <> profiles_root
    <> "\"}\n"
    <> "]\n"
    <> "git_cache_dir = \"./test/fixtures/.cache/git\"\n"
    <> "\n"
    <> "[workspaces]\n"
    <> "directory = \"./test-workspaces\"\n"

  let contents = case params_block {
    None -> base
    Some(block) -> base <> "\n[params]\n" <> block
  }

  simplifile.write(to: path, contents: contents) |> test_assertions.assert_ok
}

fn write_profile(root: String, profile_id: String) {
  let path = root <> "/profiles/" <> profile_id <> ".json"
  let contents =
    "{\n"
    <> "  \"meta\": {\n"
    <> "    \"id\": \""
    <> profile_id
    <> "\",\n"
    <> "    \"lifecycle\": \"transient\",\n"
    <> "    \"description\": \"Reload test profile\"\n"
    <> "  },\n"
    <> "  \"parameters\": {},\n"
    <> "  \"runner\": {\n"
    <> "    \"type\": \"echo_cli\",\n"
    <> "    \"tool_config\": {\"script\": \"echo_cli.py\"}\n"
    <> "  },\n"
    <> "  \"interface\": {\n"
    <> "    \"protocol\": \"runner\",\n"
    <> "    \"capabilities\": {\"echo\": {\"input_schema\": \"std:chat\", \"streaming\": false}}\n"
    <> "  }\n"
    <> "}\n"

  simplifile.write(to: path, contents: contents) |> test_assertions.assert_ok
}

fn write_missing_runner_profile(root: String, profile_id: String) {
  let path = root <> "/profiles/" <> profile_id <> ".json"
  let contents =
    "{\n"
    <> "  \"meta\": {\n"
    <> "    \"id\": \""
    <> profile_id
    <> "\",\n"
    <> "    \"lifecycle\": \"transient\",\n"
    <> "    \"description\": \"Broken profile\"\n"
    <> "  },\n"
    <> "  \"parameters\": {},\n"
    <> "  \"runner\": {\n"
    <> "    \"type\": \"missing_runner\",\n"
    <> "    \"tool_config\": {\"script\": \"missing_runner.py\"}\n"
    <> "  },\n"
    <> "  \"interface\": {\n"
    <> "    \"protocol\": \"runner\",\n"
    <> "    \"capabilities\": {\"echo\": {\"input_schema\": \"std:chat\", \"streaming\": false}}\n"
    <> "  }\n"
    <> "}\n"

  simplifile.write(to: path, contents: contents) |> test_assertions.assert_ok
}

fn reset_profiles_source(root: String) {
  let _ = simplifile.delete(file_or_dir_at: root)

  simplifile.copy_directory(at: "test/fixtures/source_local", to: root)
  |> test_assertions.assert_ok
}

fn ensure_test_workspace_dir() {
  simplifile.create_directory_all("build/test-workspaces")
  |> test_assertions.assert_ok
}

fn config_path_for(label: String) -> String {
  "build/test-workspaces/config-reload-" <> label <> ".toml"
}

fn profiles_root_for(label: String, suffix: String) -> String {
  "build/test-workspaces/config-reload-" <> label <> "/" <> suffix
}

fn auth_headers() -> dict.Dict(String, String) {
  dict.from_list([#("authorization", "Bearer " <> api_key)])
}

fn assert_ok(value: Result(a, e)) -> a {
  case value {
    Ok(v) -> v
    Error(e) -> panic as string.inspect(e)
  }
}
