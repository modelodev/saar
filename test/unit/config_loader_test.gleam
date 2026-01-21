import envoy
import gleam/dict
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

pub fn params_table_is_accepted() {
  ensure_test_workspace_dir()

  let path = "build/test-workspaces/config-params-ok.toml"
  let contents =
    "[auth]\n"
    <> "api_key = \"ok\"\n"
    <> "\n"
    <> "[params]\n"
    <> "model = \"gpt-4\"\n"
    <> "max_tokens = 123\n"
    <> "ratio = 1.5\n"
    <> "enabled = true\n"
    <> "tags = [\"a\", \"b\"]\n"

  simplifile.write(to: path, contents: contents)
  |> test_assertions.assert_ok

  let cfg =
    config_loader.load_from_path(path, envoy.get, simplifile.read)
    |> test_assertions.assert_ok

  let _ = simplifile.delete(file_or_dir_at: path)

  let types_config.SaarConfig(params: params, ..) = cfg

  dict.get(params, "model")
  |> should.equal(Ok(types_core.StringVal("gpt-4")))

  dict.get(params, "max_tokens")
  |> should.equal(Ok(types_core.IntVal(123)))

  dict.get(params, "ratio")
  |> should.equal(Ok(types_core.FloatVal(1.5)))

  dict.get(params, "enabled")
  |> should.equal(Ok(types_core.BoolVal(True)))

  dict.get(params, "tags")
  |> should.equal(Ok(types_core.ListVal(["a", "b"])))
}

pub fn params_table_rejects_unknown_types() {
  ensure_test_workspace_dir()

  let path = "build/test-workspaces/config-params-bad.toml"
  let contents =
    "[auth]\n"
    <> "api_key = \"ok\"\n"
    <> "\n"
    <> "[params]\n"
    <> "bad = { nested = 1 }\n"

  simplifile.write(to: path, contents: contents)
  |> test_assertions.assert_ok

  let err =
    config_loader.load_from_path(path, envoy.get, simplifile.read)
    |> test_assertions.assert_error

  let _ = simplifile.delete(file_or_dir_at: path)

  case err {
    config_loader.InvalidValue(key: "params.bad", message: message) ->
      should.equal(string.contains(message, "expected"), True)
    other ->
      panic as { "Expected InvalidValue, got: " <> string.inspect(other) }
  }
}

fn ensure_test_workspace_dir() {
  simplifile.create_directory_all("build/test-workspaces")
  |> test_assertions.assert_ok
}
