import envoy
import gleam/dict
import gleam/int
import gleam/list
import gleam/option
import gleeunit
import gleeunit/should
import sad/bridge/runner
import sad/types

const max_event_bytes = 262_144
const max_stdout_bytes = 10_485_760

pub fn main() {
  gleeunit.main()
}

pub fn transient_echo_happy_test() {
  ensure_wrapper_path()
  let input = base_input()

  let result =
    runner.execute_transient(
      "python3",
      ["./test/fixtures/source_local/runners/echo_cli.py"],
      base_env(500),
      ".",
      input,
      max_event_bytes,
      max_stdout_bytes,
    )

  let assert Ok(output) = result
  let types.InteractionResult(data: data, artifacts: artifacts, trace_id: trace_id) =
    output

  trace_id |> should.equal(input.context.trace_id)
  artifacts |> should.equal([])

  let types.ResponseData(content: content, metadata: metadata) = data
  content |> should.equal(option.None)
  dict.has_key(metadata, "raw") |> should.equal(True)
}

pub fn transient_invalid_json_fails_test() {
  ensure_wrapper_path()
  let input = base_input()
  let script = "print('not-json')"

  let result =
    runner.execute_transient(
      "python3",
      ["-c", script],
      base_env(500),
      ".",
      input,
      max_event_bytes,
      max_stdout_bytes,
    )

  let assert Error(err) = result
  let types.InteractionError(kind: kind, ..) = err
  kind |> should.equal(types.InfraError)
}

pub fn provision_requires_single_result_test() {
  ensure_wrapper_path()
  let input = base_input()
  let script =
    "import json; print(json.dumps({'t':'provision_result','status':'success','log_files':[]})); print(json.dumps({'t':'provision_result','status':'success','log_files':[]}))"

  let result =
    runner.run_provision(
      "python3",
      ["-c", script],
      base_env(500),
      ".",
      input,
      max_event_bytes,
      max_stdout_bytes,
    )

  let assert Error(err) = result
  let types.InteractionError(kind: kind, ..) = err
  kind |> should.equal(types.InfraError)
}

fn base_input() -> types.SadInput {
  types.SadInput(
    meta: types.SadInputMeta(
      spec_version: "v0",
      profile_id: types.profile_id("profile-1"),
      instance_id: option.Some(types.instance_id("inst-1")),
      mode: types.Transient,
    ),
    params: dict.from_list([#("model", "gpt-4")]),
    input: types.PayloadChat([
      types.ChatMessage(role: "user", content: "Hello"),
    ], dict.new()),
    context: types.RequestContext(
      trace_id: types.trace_id("trace-1"),
      extra: dict.new(),
    ),
    helpers: option.None,
    runner_def: types.Runner(
      type_: "generic_uvx",
      tool_config: types.ToolConfig(
        package: "aider-chat",
        command: "aider",
        with_packages: [],
      ),
      runtime: types.default_runtime_config(),
      env_map: dict.new(),
      args: [],
      artifact_config: types.ArtifactConfig(include: [], exclude: []),
    ),
  )
}

fn ensure_wrapper_path() {
  envoy.set("SAD_WRAPPER_PATH", "./priv/sad_wrapper")
}

fn base_env(shutdown_ms: Int) -> List(#(String, String)) {
  let path_env = case envoy.get("PATH") {
    Ok(path) -> [#("PATH", path)]
    Error(_) -> []
  }

  list.append(path_env, [
    #("SAD_SHUTDOWN_MS", int.to_string(shutdown_ms)),
    #("SAD_WRAPPER_FORCE_FALLBACK", "1"),
  ])
}
