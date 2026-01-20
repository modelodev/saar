import envoy
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import saar/config_loader
import saar/types/config as types_config
import saar/types/core as types_core
import simplifile
import test_assertions

pub fn main() {
  gleeunit.main()
}

pub fn resolve_config_path_precedence_test() {
  envoy.unset("SAAR_CONFIG_PATH")

  config_loader.resolve_config_path_with_env(None, envoy.get)
  |> should.equal("./config.toml")

  envoy.set("SAAR_CONFIG_PATH", "./from-env.toml")

  config_loader.resolve_config_path_with_env(None, envoy.get)
  |> should.equal("./from-env.toml")

  config_loader.resolve_config_path_with_env(Some("./from-cli.toml"), envoy.get)
  |> should.equal("./from-cli.toml")

  envoy.unset("SAAR_CONFIG_PATH")
}

pub fn env_interpolation_works_test() {
  envoy.set("SAAR_TEST_API_KEY", "abc")

  let cfg =
    config_loader.load_from_path(
      "test/fixtures/config/test_config.toml",
      envoy.get,
      simplifile.read,
    )
    |> test_assertions.assert_ok

  envoy.unset("SAAR_TEST_API_KEY")

  let types_config.SaarConfig(api_key: api_key, ..) = cfg
  types_core.secret_to_env_value(api_key) |> should.equal("abc")
}

pub fn missing_env_var_fails_test() {
  envoy.unset("SAAR_TEST_API_KEY")

  let err =
    config_loader.load_from_path(
      "test/fixtures/config/test_config.toml",
      envoy.get,
      simplifile.read,
    )
    |> test_assertions.assert_error

  case err {
    config_loader.EnvVarMissing(name: "SAAR_TEST_API_KEY") -> Nil
    other ->
      panic as { "Expected EnvVarMissing, got: " <> string.inspect(other) }
  }
}

pub fn unknown_key_fails_test() {
  ensure_test_workspace_dir()
  let path = "build/test-workspaces/config-unknown-key.toml"

  let contents =
    "[server]\n"
    <> "host = \"127.0.0.1\"\n"
    <> "port = 0\n"
    <> "unknown = 1\n"
    <> "\n"
    <> "[auth]\n"
    <> "api_key = \"ok\"\n"

  simplifile.write(to: path, contents: contents)
  |> test_assertions.assert_ok

  let err =
    config_loader.load_from_path(path, envoy.get, simplifile.read)
    |> test_assertions.assert_error

  let _ = simplifile.delete(file_or_dir_at: path)

  case err {
    config_loader.UnknownKey(key: "server.unknown") -> Nil
    other -> panic as { "Expected UnknownKey, got: " <> string.inspect(other) }
  }
}

pub fn missing_config_file_fails_test() {
  let err =
    config_loader.load_from_path(
      "build/test-workspaces/does-not-exist.toml",
      envoy.get,
      simplifile.read,
    )
    |> test_assertions.assert_error

  case err {
    config_loader.ConfigFileNotFound(..) -> Nil
    other ->
      panic as { "Expected ConfigFileNotFound, got: " <> string.inspect(other) }
  }
}

pub fn missing_api_key_fails_test() {
  ensure_test_workspace_dir()
  let path = "build/test-workspaces/config-missing-api-key.toml"

  let contents = "[server]\n" <> "host = \"127.0.0.1\"\n" <> "port = 0\n"

  simplifile.write(to: path, contents: contents)
  |> test_assertions.assert_ok

  let err =
    config_loader.load_from_path(path, envoy.get, simplifile.read)
    |> test_assertions.assert_error

  let _ = simplifile.delete(file_or_dir_at: path)

  case err {
    config_loader.MissingApiKey -> Nil
    other ->
      panic as { "Expected MissingApiKey, got: " <> string.inspect(other) }
  }
}

pub fn limits_values_are_loaded_test() {
  envoy.set("SAAR_TEST_API_KEY", "abc")

  ensure_test_workspace_dir()

  let path = "build/test-workspaces/config-limits.toml"

  let contents =
    "[auth]\n"
    <> "api_key = \"${SAAR_TEST_API_KEY}\"\n"
    <> "\n"
    <> "[limits]\n"
    <> "max_request_body_bytes = 123\n"
    <> "sse_keep_alive_interval_ms = 456\n"

  simplifile.write(to: path, contents: contents)
  |> test_assertions.assert_ok

  let cfg =
    config_loader.load_from_path(path, envoy.get, simplifile.read)
    |> test_assertions.assert_ok

  let _ = simplifile.delete(file_or_dir_at: path)
  envoy.unset("SAAR_TEST_API_KEY")

  let types_config.SaarConfig(limits: limits, stream: stream, ..) = cfg

  let types_config.SaarLimits(max_request_body_bytes: max_body, ..) = limits
  max_body |> should.equal(123)

  let types_config.StreamConfig(sse_keep_alive_interval_ms: keep_alive, ..) =
    stream
  keep_alive |> should.equal(456)
}

fn ensure_test_workspace_dir() {
  simplifile.create_directory_all("build/test-workspaces")
  |> test_assertions.assert_ok
}
