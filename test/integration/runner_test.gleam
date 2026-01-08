import gleam/dict
import gleam/list
import gleam/option
import gleeunit
import gleeunit/should
import port_helpers
import runner_fixtures
import sad/bridge/runner
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/output as types_output
import sad/types/runner as types_runner
import simplifile
import youid/uuid

pub fn main() {
  gleeunit.main()
}

pub fn transient_echo_happy_test() {
  port_helpers.ensure_wrapper_path()
  let input =
    runner_fixtures.base_input(
      runner_fixtures.default_chat_payload(),
      types_runner.ArtifactConfig(include: [], exclude: []),
    )
  let config = default_config()

  let result =
    runner.execute_transient(
      "python3",
      ["./test/fixtures/source_local/runners/echo_cli.py"],
      port_helpers.base_env(500, []),
      ".",
      input,
      config,
      False,
      config.call_timeout_ms,
    )

  let assert Ok(output) = result
  let types_output.InteractionResult(
    data: data,
    artifacts: artifacts,
    trace_id: trace_id,
  ) = output

  trace_id |> should.equal(input.context.trace_id)
  artifacts |> should.equal([])

  let types_output.ResponseData(content: content, metadata: metadata) = data
  content |> should.equal(option.None)
  dict.has_key(metadata, "raw") |> should.equal(True)
}

pub fn transient_invalid_json_fails_test() {
  port_helpers.ensure_wrapper_path()
  let input =
    runner_fixtures.base_input(
      runner_fixtures.default_chat_payload(),
      types_runner.ArtifactConfig(include: [], exclude: []),
    )
  let config = default_config()
  let script = "print('not-json')"

  let result =
    runner.execute_transient(
      "python3",
      ["-c", script],
      port_helpers.base_env(500, []),
      ".",
      input,
      config,
      False,
      config.call_timeout_ms,
    )

  let assert Error(err) = result
  let types_output.InteractionError(kind: kind, ..) = err
  kind |> should.equal(types_enums.InfraError)
}

pub fn provision_requires_single_result_test() {
  port_helpers.ensure_wrapper_path()
  let input =
    runner_fixtures.base_input(
      runner_fixtures.default_chat_payload(),
      types_runner.ArtifactConfig(include: [], exclude: []),
    )
  let config = default_config()
  let script =
    "import json; print(json.dumps({'t':'provision_result','status':'success','log_files':[]})); print(json.dumps({'t':'provision_result','status':'success','log_files':[]}))"

  let result =
    runner.run_provision(
      "python3",
      ["-c", script],
      port_helpers.base_env(500, []),
      ".",
      input,
      config,
      config.call_timeout_ms,
    )

  let assert Error(err) = result
  let types_output.InteractionError(kind: kind, ..) = err
  kind |> should.equal(types_enums.InfraError)
}

pub fn streaming_chunks_ok_test() {
  port_helpers.ensure_wrapper_path()
  let input =
    runner_fixtures.base_input(
      runner_fixtures.default_chat_payload(),
      types_runner.ArtifactConfig(include: [], exclude: []),
    )
  let config = default_config()

  let result =
    runner.execute_transient(
      "python3",
      ["./test/fixtures/source_local/runners/streaming_echo.py"],
      port_helpers.base_env(500, []),
      ".",
      input,
      config,
      True,
      config.call_timeout_ms,
    )

  let assert Ok(_) = result

  let result =
    runner.execute_transient(
      "python3",
      ["./test/fixtures/source_local/runners/streaming_echo.py"],
      port_helpers.base_env(500, []),
      ".",
      input,
      config,
      False,
      config.call_timeout_ms,
    )

  let assert Error(err) = result
  let types_output.InteractionError(kind: kind, ..) = err
  kind |> should.equal(types_enums.InfraError)
}

pub fn runner_crash_returns_infra_error_test() {
  port_helpers.ensure_wrapper_path()
  let input =
    runner_fixtures.base_input(
      runner_fixtures.default_chat_payload(),
      types_runner.ArtifactConfig(include: [], exclude: []),
    )
  let config = default_config()

  let result =
    runner.execute_transient(
      "python3",
      ["./test/fixtures/source_local/runners/crasher.py"],
      port_helpers.base_env(500, [#("SAD_CRASH_ON_START", "1")]),
      ".",
      input,
      config,
      False,
      config.call_timeout_ms,
    )

  let assert Error(err) = result
  let types_output.InteractionError(kind: kind, ..) = err
  kind |> should.equal(types_enums.InfraError)
}

pub fn transient_timeout_stops_runner_test() {
  port_helpers.ensure_wrapper_path()
  let workspace = "./build/test-workspaces/timeout"
  let _ = ensure_workspace(workspace)
  let marker = workspace <> "/stopped.txt"
  let config =
    types_config.SadConfig(..default_config(), shutdown_timeout_ms: 100)
  let input =
    runner_fixtures.base_input(
      runner_fixtures.default_chat_payload(),
      types_runner.ArtifactConfig(include: [], exclude: []),
    )
  let env =
    port_helpers.base_env(500, [#("SAD_TIMEOUT_MARKER", marker)])

  let result =
    runner.execute_transient(
      "python3",
      ["./test/fixtures/source_local/runners/timeout_sleep.py"],
      env,
      ".",
      input,
      config,
      False,
      50,
    )

  let assert Error(err) = result
  let types_output.InteractionError(kind: kind, ..) = err
  kind |> should.equal(types_enums.InfraError)
  simplifile.is_file(marker) |> should.equal(Ok(True))
}

pub fn artifact_collection_respects_globs_test() {
  port_helpers.ensure_wrapper_path()
  let workspace = "./build/test-workspaces/artifacts"
  let _ = ensure_workspace(workspace)
  let config = default_config()

  let include_only =
    types_runner.ArtifactConfig(include: ["outputs/**"], exclude: [])

  let input =
    runner_fixtures.base_input(
      runner_fixtures.default_chat_payload(),
      include_only,
    )
  let env = port_helpers.env_with_workspace(500, workspace)

  let result =
    runner.execute_transient(
      "python3",
      ["./test/fixtures/source_local/runners/artifact_gen.py"],
      env,
      ".",
      input,
      config,
      False,
      config.call_timeout_ms,
    )

  let assert Ok(types_output.InteractionResult(artifacts: artifacts, ..)) =
    result
  list.length(artifacts) |> should.equal(1)

  let exclude_pdf =
    types_runner.ArtifactConfig(include: ["outputs/**"], exclude: ["**/*.pdf"])

  let input =
    runner_fixtures.base_input(
      runner_fixtures.default_chat_payload(),
      exclude_pdf,
    )
  let result =
    runner.execute_transient(
      "python3",
      ["./test/fixtures/source_local/runners/artifact_gen.py"],
      env,
      ".",
      input,
      config,
      False,
      config.call_timeout_ms,
    )

  let assert Ok(types_output.InteractionResult(artifacts: artifacts, ..)) =
    result
  list.length(artifacts) |> should.equal(0)
}

pub fn artifact_id_is_uuid_v7_test() {
  port_helpers.ensure_wrapper_path()
  let workspace = "./build/test-workspaces/artifacts-uuid"
  let _ = ensure_workspace(workspace)
  let sad_config = default_config()

  let artifact_config =
    types_runner.ArtifactConfig(include: ["outputs/**"], exclude: [])

  let input =
    runner_fixtures.base_input(
      runner_fixtures.default_chat_payload(),
      artifact_config,
    )
  let env = port_helpers.env_with_workspace(500, workspace)

  let result =
    runner.execute_transient(
      "python3",
      ["./test/fixtures/source_local/runners/artifact_gen.py"],
      env,
      ".",
      input,
      sad_config,
      False,
      sad_config.call_timeout_ms,
    )

  let assert Ok(types_output.InteractionResult(artifacts: artifacts, ..)) =
    result

  case artifacts {
    [only] -> {
      let types_output.PublicArtifact(id: id, url: url, ..) = only
      url |> should.equal(option.None)
      let assert Ok(parsed) = uuid.from_string(types_core.artifact_id_to_string(id))
      uuid.version(parsed) |> should.equal(uuid.V7)
    }
    _ -> panic as "Expected one artifact"
  }
}

fn ensure_workspace(path: String) {
  let _ = simplifile.delete(file_or_dir_at: path)
  let assert Ok(_) = simplifile.create_directory_all(path)
}

fn default_config() -> types_config.SadConfig {
  types_config.default_sad_config()
}
