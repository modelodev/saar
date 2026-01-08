import gleam/dict
import gleam/option
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/input as types_input
import sad/types/runner as types_runner

pub fn base_input(
  payload: types_input.InputPayload,
  artifact_config: types_runner.ArtifactConfig,
) -> types_input.SadInput {
  types_input.SadInput(
    meta: types_input.SadInputMeta(
      spec_version: "v0",
      profile_id: types_core.profile_id("profile-1"),
      instance_id: option.Some(types_core.instance_id("inst-1")),
      mode: types_enums.Transient,
    ),
    params: dict.from_list([#("model", "gpt-4")]),
    input: payload,
    context: types_input.RequestContext(
      trace_id: types_core.trace_id("trace-1"),
      extra: dict.new(),
    ),
    helpers: option.None,
    runner_def: types_runner.Runner(
      type_: "generic_uvx",
      tool_config: types_runner.ToolConfig(
        package: "aider-chat",
        command: "aider",
        with_packages: [],
      ),
      runtime: types_runner.default_runtime_config(),
      env_map: dict.new(),
      args: [],
      artifact_config: artifact_config,
    ),
  )
}

pub fn default_chat_payload() -> types_input.InputPayload {
  types_input.PayloadChat(
    [
      types_input.ChatMessage(role: "user", content: "Hello"),
    ],
    dict.new(),
  )
}
