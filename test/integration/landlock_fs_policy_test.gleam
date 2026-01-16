import envoy
import filepath
import gleam/dict
import gleam/http
import gleam/int
import gleam/option
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

pub fn landlock_enforced_allows_workspace_read_write_and_denies_outside_test() {
  port_helpers.ensure_wrapper_path()
  envoy.set("SAAR_TEST_API_KEY", api_key)

  let cfg0 =
    config_loader.load_from_path(
      "test/fixtures/config/test_config_landlock_enforced_strict.toml",
      envoy.get,
      simplifile.read,
    )
    |> test_assertions.assert_ok

  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)
  tcp_listener.close(listener)

  let names = supervisor_names.new_names_with_suffix(int.to_string(port))
  let cfg = types_config.SaarConfig(..cfg0, server_port: port)

  let profiles =
    profiles_sources.load_profiles_from_sources(cfg)
    |> test_assertions.assert_ok

  let state = app_state.AppState(config: cfg, initial_profiles: profiles)
  let assert Ok(_) = root_supervisor.start(state, names)

  let base_url = "http://" <> host <> ":" <> int.to_string(port)

  // Create an existing directory outside the instance workspace.
  let types_config.SaarConfig(storage: storage, ..) = cfg
  let types_config.StorageConfig(workspaces_directory: workspaces_dir, ..) =
    storage

  let denied_dir = filepath.join(workspaces_dir, "denied")
  let _ = simplifile.delete(file_or_dir_at: denied_dir)
  simplifile.create_directory_all(denied_dir) |> test_assertions.assert_ok

  // Pre-create a file outside the instance workspace so reads fail with EACCES/EPERM
  // (as opposed to ENOENT).
  simplifile.write(to: filepath.join(denied_dir, "out.txt"), contents: "deny")
  |> test_assertions.assert_ok

  // Create agent and interact. The fs_probe runner reports deny/allow.
  let instance_id = "inst-fs-probe-1"

  // Create agent
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

  // Interact
  let interact_body =
    "{"
    <> "\"capability\":\"probe\","
    <> "\"inputs\":{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]},"
    <> "\"context\":{\"trace_id\":\"trace-fs-probe-1\"}"
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

  // The interaction must succeed and include flags in metadata.
  case resp.status {
    200 -> Nil
    other ->
      panic as {
        "Expected 200, got " <> int.to_string(other) <> ": " <> resp.body
      }
  }
  case string.contains(resp.body, "\"outside_write_denied\":true") {
    True -> Nil
    False ->
      panic as { "Expected outside_write_denied=true, got: " <> resp.body }
  }
  case string.contains(resp.body, "\"outside_read_denied\":true") {
    True -> Nil
    False ->
      panic as { "Expected outside_read_denied=true, got: " <> resp.body }
  }
  case string.contains(resp.body, "\"inside_ok\":true") {
    True -> Nil
    False -> panic as { "Expected inside_ok=true, got: " <> resp.body }
  }

  envoy.unset("SAAR_TEST_API_KEY")
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
