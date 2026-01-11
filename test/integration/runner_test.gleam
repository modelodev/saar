import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import port_helpers
import runner_fixtures
import sad/bridge/client
import sad/bridge/http_client
import sad/bridge/runner
import sad/net/tcp_listener
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/input as types_input
import sad/types/output as types_output
import sad/types/runner as types_runner
import simplifile
import test_assertions
import youid/uuid

const host = "127.0.0.1"

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
      config.timeouts.call_timeout_ms,
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
      config.timeouts.call_timeout_ms,
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
      config.timeouts.call_timeout_ms,
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
      config.timeouts.call_timeout_ms,
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
      config.timeouts.call_timeout_ms,
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
      config.timeouts.call_timeout_ms,
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
  let base = default_config()
  let config =
    types_config.SadConfig(
      ..base,
      timeouts: types_config.SadTimeouts(
        ..base.timeouts,
        shutdown_timeout_ms: 100,
      ),
    )
  let input =
    runner_fixtures.base_input(
      runner_fixtures.default_chat_payload(),
      types_runner.ArtifactConfig(include: [], exclude: []),
    )
  let env = port_helpers.base_env(500, [#("SAD_TIMEOUT_MARKER", marker)])

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
      config.timeouts.call_timeout_ms,
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
      config.timeouts.call_timeout_ms,
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
      sad_config.timeouts.call_timeout_ms,
    )

  let assert Ok(types_output.InteractionResult(artifacts: artifacts, ..)) =
    result

  case artifacts {
    [only] -> {
      let types_output.PublicArtifact(id: id, url: url, ..) = only
      url |> should.equal(option.None)
      let assert Ok(parsed) =
        uuid.from_string(types_core.artifact_id_to_string(id))
      uuid.version(parsed) |> should.equal(uuid.V7)
    }
    _ -> panic as "Expected one artifact"
  }
}

pub fn continuous_start_health_ok_test() {
  port_helpers.ensure_wrapper_path()
  let config = default_config()

  let #(server, port, _trace_id) =
    start_continuous_server(
      "test/fixtures/source_local/profiles/echo_server.json",
      "./test/fixtures/source_local/runners/echo_server.py",
      config,
    )

  port_helpers.wait_for_http_200(
    "http://" <> host <> ":" <> int.to_string(port) <> "/health",
    40,
    25,
  )

  runner.stop_server(server)
}

pub fn continuous_health_check_timeout_test() {
  port_helpers.ensure_wrapper_path()

  let base = default_config()
  let config =
    types_config.SadConfig(
      ..base,
      timeouts: types_config.SadTimeouts(
        ..base.timeouts,
        health_check_timeout_ms: 50,
      ),
    )

  let #(server, port, _trace_id) =
    start_continuous_server(
      "test/fixtures/source_local/profiles/slow_poke.json",
      "./test/fixtures/source_local/runners/slow_poke.py",
      config,
    )

  port_helpers.wait_for_http_200(
    "http://" <> host <> ":" <> int.to_string(port) <> "/echo",
    40,
    25,
  )

  let health_url = "http://" <> host <> ":" <> int.to_string(port) <> "/health"

  case
    client.request_sync(http.Get, health_url, dict.new(), option.None, 50, 1024)
  {
    Error(http_client.Timeout) -> Nil
    other -> panic as { "Expected Timeout, got " <> string.inspect(other) }
  }

  runner.stop_server(server)
}

pub fn continuous_server_died_test() {
  port_helpers.ensure_wrapper_path()
  let config = default_config()

  let #(server, port, trace_id) =
    start_continuous_server(
      "test/fixtures/source_local/profiles/crasher.json",
      "./test/fixtures/source_local/runners/crasher.py",
      config,
    )

  port_helpers.wait_for_http_200(
    "http://" <> host <> ":" <> int.to_string(port) <> "/health",
    40,
    25,
  )

  let url = "http://" <> host <> ":" <> int.to_string(port) <> "/echo"

  client.request_sync(
    http.Post,
    url,
    dict.new(),
    option.Some("boom"),
    1000,
    1024,
  )
  |> should.be_ok

  wait_for_server_exit(server, trace_id, 40)
  |> should.be_error
}

fn wait_for_server_exit(
  server: runner.ServerHandle,
  trace_id: types_core.TraceId,
  attempts: Int,
) -> Result(Nil, types_output.InteractionError) {
  case runner.detect_server_exit(server, trace_id) {
    Ok(_) ->
      case attempts {
        0 -> Ok(Nil)
        _ -> {
          process.sleep(25)
          wait_for_server_exit(server, trace_id, attempts - 1)
        }
      }

    Error(err) -> Error(err)
  }
}

fn start_continuous_server(
  profile_path: String,
  runner_script: String,
  config: types_config.SadConfig,
) -> #(runner.ServerHandle, Int, types_core.TraceId) {
  start_continuous_server_result(profile_path, runner_script, config)
  |> test_assertions.assert_ok
}

fn start_continuous_server_result(
  _profile_path: String,
  runner_script: String,
  config: types_config.SadConfig,
) -> Result(
  #(runner.ServerHandle, Int, types_core.TraceId),
  types_output.InteractionError,
) {
  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)
  tcp_listener.close(listener)

  let runtime =
    types_runner.RuntimeConfig(
      mode: types_runner.ManagedPort,
      port_env_var: option.None,
      host_env_var: option.None,
    )

  let base_input =
    runner_fixtures.base_input(
      runner_fixtures.default_chat_payload(),
      types_runner.ArtifactConfig(include: [], exclude: []),
    )

  let input =
    types_input.SadInput(
      ..base_input,
      runner_def: types_runner.Runner(..base_input.runner_def, runtime: runtime),
    )

  let env = port_helpers.base_env(500, [])

  runner.start_server(
    "python3",
    [runner_script],
    env,
    ".",
    input,
    config,
    option.Some(port),
  )
  |> result.map(fn(server) { #(server, port, input.context.trace_id) })
}

fn ensure_workspace(path: String) {
  let _ = simplifile.delete(file_or_dir_at: path)
  let assert Ok(_) = simplifile.create_directory_all(path)
}

fn default_config() -> types_config.SadConfig {
  types_config.default_sad_config()
}
