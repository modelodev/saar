import envoy
import filepath
import gleam/dict
import gleam/http
import gleam/int
import gleam/json
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should
import port_helpers
import saar/app_state
import saar/bridge/http_client
import saar/bridge/port_process
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

fn run_fs_probe_interaction(config_path: String, instance_id: String) -> String {
  port_helpers.ensure_wrapper_path()
  envoy.set("SAAR_TEST_API_KEY", api_key)

  let #(cfg, base_url) = start_saar_with_config(config_path)
  prepare_denied_directory(cfg)
  create_fs_probe_agent(base_url, instance_id)

  let interact_body =
    "{"
    <> "\"capability\":\"probe\","
    <> "\"inputs\":{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]},"
    <> "\"context\":{\"trace_id\":\"trace-"
    <> instance_id
    <> "\"}"
    <> "}"

  let resp =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/agents/" <> instance_id <> "/interact",
      dict.from_list([
        #("authorization", "Bearer " <> api_key),
        #("content-type", "application/json"),
      ]),
      option.Some(interact_body),
      5000,
      1024 * 1024,
    )
    |> test_assertions.assert_ok

  case resp.status {
    200 -> Nil
    other ->
      panic as {
        "Expected 200, got " <> int.to_string(other) <> ": " <> resp.body
      }
  }

  envoy.unset("SAAR_TEST_API_KEY")
  resp.body
}

fn start_saar_with_config(
  config_path: String,
) -> #(types_config.SaarConfig, String) {
  let cfg0 =
    config_loader.load_from_path(config_path, envoy.get, simplifile.read)
    |> test_assertions.assert_ok

  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)
  tcp_listener.close(listener)

  let names = supervisor_names.new_names_with_suffix(int.to_string(port))
  let cfg = types_config.SaarConfig(..cfg0, server_port: port)

  let profiles =
    profiles_sources.load_profiles_from_sources(cfg)
    |> test_assertions.assert_ok

  let state =
    app_state.AppState(
      config: cfg,
      config_path: config_path,
      initial_profiles: profiles,
    )
  let assert Ok(_) = root_supervisor.start(state, names)

  #(cfg, "http://" <> host <> ":" <> int.to_string(port))
}

fn prepare_denied_directory(cfg: types_config.SaarConfig) {
  let types_config.SaarConfig(storage: storage, ..) = cfg
  let types_config.StorageConfig(workspaces_directory: workspaces_dir, ..) =
    storage

  let denied_dir = filepath.join(workspaces_dir, "denied")
  let _ = simplifile.delete(file_or_dir_at: denied_dir)
  simplifile.create_directory_all(denied_dir) |> test_assertions.assert_ok

  simplifile.write(to: filepath.join(denied_dir, "out.txt"), contents: "deny")
  |> test_assertions.assert_ok
}

fn create_fs_probe_agent(base_url: String, instance_id: String) {
  let body =
    "{"
    <> "\"profile_id\":\"fs_probe\","
    <> "\"instance_id\":\""
    <> instance_id
    <> "\""
    <> "}"

  http_client.request_sync_string(
    http.Post,
    base_url <> "/sys/agents",
    dict.from_list([
      #("authorization", "Bearer " <> api_key),
      #("content-type", "application/json"),
    ]),
    option.Some(body),
    5000,
    1024 * 1024,
  )
  |> test_assertions.assert_ok
}

pub fn landlock_enforced_allows_workspace_read_write_test() {
  let body =
    run_fs_probe_interaction(
      "test/fixtures/config/test_config_landlock_enforced_strict.toml",
      "inst-fs-probe-allow",
    )

  case string.contains(body, "\"inside_ok\":true") {
    True -> Nil
    False -> panic as { "Expected inside_ok=true, got: " <> body }
  }
}

pub fn landlock_enforced_denies_outside_read_test() {
  let body =
    run_fs_probe_interaction(
      "test/fixtures/config/test_config_landlock_enforced_strict.toml",
      "inst-fs-probe-read",
    )

  case string.contains(body, "\"outside_read_denied\":true") {
    True -> Nil
    False -> panic as { "Expected outside_read_denied=true, got: " <> body }
  }
}

pub fn landlock_enforced_denies_outside_write_test() {
  let body =
    run_fs_probe_interaction(
      "test/fixtures/config/test_config_landlock_enforced_strict.toml",
      "inst-fs-probe-write",
    )

  case string.contains(body, "\"outside_write_denied\":true") {
    True -> Nil
    False -> panic as { "Expected outside_write_denied=true, got: " <> body }
  }
}

pub fn landlock_enforced_deny_is_permission_error_test() {
  let body =
    run_fs_probe_interaction(
      "test/fixtures/config/test_config_landlock_enforced_strict.toml",
      "inst-fs-probe-perm",
    )

  case string.contains(body, "\"outside_read_denied\":true") {
    True -> Nil
    False -> panic as { "Expected outside_read_denied=true, got: " <> body }
  }

  case string.contains(body, "\"outside_write_denied\":true") {
    True -> Nil
    False -> panic as { "Expected outside_write_denied=true, got: " <> body }
  }
}

pub fn landlock_enforced_wrapper_is_dumb_policy_must_include_workspace_test() {
  port_helpers.ensure_wrapper_path()

  let workspace = "/tmp/saar-landlock-policy-missing-workspace"
  let _ = simplifile.delete(file_or_dir_at: workspace)
  simplifile.create_directory_all(workspace) |> test_assertions.assert_ok

  let policy_json =
    json.object([
      #("allow_read", json.array(["/etc"], json.string)),
      #(
        "allow_exec",
        json.array(["/usr", "/bin", "/lib", "/lib64"], json.string),
      ),
      #("allow_write", json.array(["/var/tmp"], json.string)),
    ])
    |> json.to_string

  let target = filepath.join(workspace, "out.txt")
  let env =
    port_helpers.base_env(200, [
      #("SAAR_LANDLOCK_MODE", "enforced"),
      #("SAAR_LANDLOCK_POLICY_JSON", policy_json),
      #("SAAR_WORKSPACE", workspace),
    ])

  let process =
    port_process.start(
      "/bin/sh",
      ["-c", "echo hi > " <> target],
      env,
      ".",
      262_144,
    )
    |> test_assertions.assert_ok

  let exit_code =
    wait_for_exit_code(process, 200, 40) |> test_assertions.assert_ok

  exit_code |> should.not_equal(0)

  let _ = simplifile.delete(file_or_dir_at: workspace)
}

pub fn landlock_enforced_policy_requires_absolute_paths_fails_early_test() {
  envoy.set("SAAR_TEST_API_KEY", api_key)

  let err =
    config_loader.load_from_path(
      "test/fixtures/config/test_config_landlock_enforced_invalid_relative.toml",
      envoy.get,
      simplifile.read,
    )
    |> test_assertions.assert_error

  string.contains(string.inspect(err), "LANDLOCK_POLICY_PATH_NOT_ABSOLUTE")
  |> should.equal(True)

  envoy.unset("SAAR_TEST_API_KEY")
}

pub fn landlock_enforced_policy_missing_fails_early_test() {
  envoy.set("SAAR_TEST_API_KEY", api_key)

  let err =
    config_loader.load_from_path(
      "test/fixtures/config/test_config_landlock_enforced_missing_policy.toml",
      envoy.get,
      simplifile.read,
    )
    |> test_assertions.assert_error

  string.contains(string.inspect(err), "LANDLOCK_POLICY_MISSING")
  |> should.equal(True)

  envoy.unset("SAAR_TEST_API_KEY")
}

pub fn landlock_enforced_policy_rejects_root_path_fails_early_test() {
  envoy.set("SAAR_TEST_API_KEY", api_key)

  let err =
    config_loader.load_from_path(
      "test/fixtures/config/test_config_landlock_enforced_invalid_root.toml",
      envoy.get,
      simplifile.read,
    )
    |> test_assertions.assert_error

  string.contains(string.inspect(err), "LANDLOCK_POLICY_PATH_IS_ROOT")
  |> should.equal(True)

  envoy.unset("SAAR_TEST_API_KEY")
}

pub fn landlock_enforced_policy_rejects_dotdot_segments_fails_early_test() {
  envoy.set("SAAR_TEST_API_KEY", api_key)

  let err =
    config_loader.load_from_path(
      "test/fixtures/config/test_config_landlock_enforced_invalid_dotdot.toml",
      envoy.get,
      simplifile.read,
    )
    |> test_assertions.assert_error

  string.contains(string.inspect(err), "LANDLOCK_POLICY_PATH_HAS_DOT_SEGMENT")
  |> should.equal(True)

  envoy.unset("SAAR_TEST_API_KEY")
}

pub fn landlock_enforced_policy_rejects_dot_segments_fails_early_test() {
  envoy.set("SAAR_TEST_API_KEY", api_key)

  let err =
    config_loader.load_from_path(
      "test/fixtures/config/test_config_landlock_enforced_invalid_dot.toml",
      envoy.get,
      simplifile.read,
    )
    |> test_assertions.assert_error

  string.contains(string.inspect(err), "LANDLOCK_POLICY_PATH_HAS_DOT_SEGMENT")
  |> should.equal(True)

  envoy.unset("SAAR_TEST_API_KEY")
}

pub fn landlock_enforced_policy_rejects_symlink_paths_fails_early_test() {
  // Create a symlink path used by the TOML.
  let link = "/tmp/saar-landlock-symlink"
  let target = "/tmp"
  let _ = simplifile.delete(file_or_dir_at: link)
  simplifile.create_symlink(to: target, from: link) |> test_assertions.assert_ok

  envoy.set("SAAR_TEST_API_KEY", api_key)

  let err =
    config_loader.load_from_path(
      "test/fixtures/config/test_config_landlock_enforced_invalid_symlink.toml",
      envoy.get,
      simplifile.read,
    )
    |> test_assertions.assert_error

  string.contains(string.inspect(err), "LANDLOCK_POLICY_PATH_IS_SYMLINK")
  |> should.equal(True)

  envoy.unset("SAAR_TEST_API_KEY")
  let _ = simplifile.delete(file_or_dir_at: link)
}

pub fn landlock_enforced_workspaces_dir_not_absolute_fails_early_test() {
  envoy.set("SAAR_TEST_API_KEY", api_key)

  let err =
    config_loader.load_from_path(
      "test/fixtures/config/test_config_landlock_enforced_invalid_workspace_dir.toml",
      envoy.get,
      simplifile.read,
    )
    |> test_assertions.assert_error

  string.contains(string.inspect(err), "LANDLOCK_WORKSPACES_DIR_NOT_ABSOLUTE")
  |> should.equal(True)

  envoy.unset("SAAR_TEST_API_KEY")
}

fn wait_for_exit_code(
  process: port_process.PortProcess,
  timeout_ms: Int,
  attempts: Int,
) -> Result(Int, Nil) {
  case attempts {
    0 -> Error(Nil)
    _ ->
      case port_process.receive(process, timeout_ms) {
        Ok(port_process.PortExit(code)) -> Ok(code)
        Ok(_) -> wait_for_exit_code(process, timeout_ms, attempts - 1)
        Error(_) -> wait_for_exit_code(process, timeout_ms, attempts - 1)
      }
  }
}
