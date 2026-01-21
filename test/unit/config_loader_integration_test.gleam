import envoy
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should
import saar/config_loader
import saar/config_reloader
import saar/types/config as types_config
import simplifile
import test_assertions

pub fn main() {
  gleeunit.main()
}

pub fn reload_uses_config_loader_and_returns_error_marker() {
  ensure_test_workspace_dir()
  envoy.set("SAAR_TEST_API_KEY", "abc")

  let path = "build/test-workspaces/reload-invalid-config.toml"

  let contents =
    "[server]\n"
    <> "host = \"127.0.0.1\"\n"
    <> "port = 0\n"
    <> "unknown = 1\n"
    <> "\n"
    <> "[auth]\n"
    <> "api_key = \"${SAAR_TEST_API_KEY}\"\n"

  simplifile.write(to: path, contents: contents)
  |> test_assertions.assert_ok

  let state0 =
    config_reloader.ReloadState(
      config: types_config.default_saar_config(),
      config_path: path,
      last_reload_ms: None,
      debounce_ms: 0,
    )

  let #(state1, outcome) =
    config_reloader.reload(
      state0,
      0,
      fn(cfg_path) {
        config_loader.load_from_path(cfg_path, envoy.get, simplifile.read)
      },
      fn(_) { panic as "profiles reload should not run" },
    )

  state1 |> should.equal(state0)

  case outcome {
    config_reloader.Rejected(err) -> {
      config_reloader.reload_error_code(err)
      |> should.equal(config_reloader.config_reload_failed_code)

      config_reloader.reload_error_detail(err)
      |> fn(detail) {
        should.equal(string.contains(detail, "UnknownKey"), True)
      }
    }

    _ -> panic as "Expected ConfigReloadFailed"
  }

  let _ = simplifile.delete(file_or_dir_at: path)
  envoy.unset("SAAR_TEST_API_KEY")
}

fn ensure_test_workspace_dir() {
  simplifile.create_directory_all("build/test-workspaces")
  |> test_assertions.assert_ok
}
