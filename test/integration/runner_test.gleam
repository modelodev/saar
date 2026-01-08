import gleam/dict
import gleam/list
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should
import port_helpers
import runner_fixtures
import sad/bridge/runner
import sad/types/enums as types_enums
import sad/types/output as types_output
import sad/types/runner as types_runner
import simplifile
import youid/uuid

const max_event_bytes = 262_144

const max_stdout_bytes = 10_485_760

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

  let result =
    runner.execute_transient(
      "python3",
      ["./test/fixtures/source_local/runners/echo_cli.py"],
      port_helpers.base_env(500, []),
      ".",
      input,
      max_event_bytes,
      max_stdout_bytes,
      False,
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
  let script = "print('not-json')"

  let result =
    runner.execute_transient(
      "python3",
      ["-c", script],
      port_helpers.base_env(500, []),
      ".",
      input,
      max_event_bytes,
      max_stdout_bytes,
      False,
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
  let script =
    "import json; print(json.dumps({'t':'provision_result','status':'success','log_files':[]})); print(json.dumps({'t':'provision_result','status':'success','log_files':[]}))"

  let result =
    runner.run_provision(
      "python3",
      ["-c", script],
      port_helpers.base_env(500, []),
      ".",
      input,
      max_event_bytes,
      max_stdout_bytes,
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

  let result =
    runner.execute_transient(
      "python3",
      ["./test/fixtures/source_local/runners/streaming_echo.py"],
      port_helpers.base_env(500, []),
      ".",
      input,
      max_event_bytes,
      max_stdout_bytes,
      True,
    )

  let assert Ok(_) = result

  let result =
    runner.execute_transient(
      "python3",
      ["./test/fixtures/source_local/runners/streaming_echo.py"],
      port_helpers.base_env(500, []),
      ".",
      input,
      max_event_bytes,
      max_stdout_bytes,
      False,
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

  let result =
    runner.execute_transient(
      "python3",
      ["./test/fixtures/source_local/runners/crasher.py"],
      port_helpers.base_env(500, []),
      ".",
      input,
      max_event_bytes,
      max_stdout_bytes,
      False,
    )

  let assert Error(err) = result
  let types_output.InteractionError(kind: kind, ..) = err
  kind |> should.equal(types_enums.InfraError)
}

pub fn artifact_collection_respects_globs_test() {
  port_helpers.ensure_wrapper_path()
  let workspace = "./build/test-workspaces/artifacts"
  let _ = ensure_workspace(workspace)

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
      max_event_bytes,
      max_stdout_bytes,
      False,
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
      max_event_bytes,
      max_stdout_bytes,
      False,
    )

  let assert Ok(types_output.InteractionResult(artifacts: artifacts, ..)) =
    result
  list.length(artifacts) |> should.equal(0)
}

pub fn artifact_id_is_uuid_v7_test() {
  port_helpers.ensure_wrapper_path()
  let workspace = "./build/test-workspaces/artifacts-uuid"
  let _ = ensure_workspace(workspace)

  let config = types_runner.ArtifactConfig(include: ["outputs/**"], exclude: [])

  let input =
    runner_fixtures.base_input(runner_fixtures.default_chat_payload(), config)
  let env = port_helpers.env_with_workspace(500, workspace)

  let result =
    runner.execute_transient(
      "python3",
      ["./test/fixtures/source_local/runners/artifact_gen.py"],
      env,
      ".",
      input,
      max_event_bytes,
      max_stdout_bytes,
      False,
    )

  let assert Ok(types_output.InteractionResult(artifacts: artifacts, ..)) =
    result

  case artifacts {
    [only] -> {
      let types_output.PublicArtifact(url: url, ..) = only
      let id = artifact_id_from_url(url)
      let assert Ok(parsed) = uuid.from_string(id)
      uuid.version(parsed) |> should.equal(uuid.V7)
    }
    _ -> panic as "Expected one artifact"
  }
}

fn ensure_workspace(path: String) {
  let _ = simplifile.delete(file_or_dir_at: path)
  let assert Ok(_) = simplifile.create_directory_all(path)
}

fn artifact_id_from_url(url: String) -> String {
  let prefix = "/artifacts/"

  case string.starts_with(url, prefix) {
    True -> string.drop_start(url, string.length(prefix))
    False -> url
  }
}
