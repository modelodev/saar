import gleam/dict
import gleam/erlang/process
import gleam/option
import gleeunit
import gleeunit/should
import saar/core/messages
import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/enums as types_enums
import saar/types/profile as types_profile
import saar/types/runner as types_runner

pub fn main() {
  gleeunit.main()
}

pub fn instance_key_roundtrip() {
  let profile_id = types_core.profile_id("default")
  let assert Ok(instance_id) = types_core.instance_id("inst-1")

  let key = messages.InstanceKey(profile_id, instance_id)
  let encoded = messages.instance_key_to_string(key)

  messages.instance_key_from_string(encoded)
  |> should.equal(Ok(key))
}

pub fn start_args_contains_snapshot_fields() {
  let profile_id = types_core.profile_id("default")

  let profile =
    types_profile.Profile(
      meta: types_profile.ProfileMeta(
        id: profile_id,
        name: option.None,
        lifecycle: types_enums.Transient,
        description: "",
      ),
      parameters: dict.new(),
      runner: types_runner.Runner(
        type_: "test",
        tool_config: types_runner.ToolConfigScript(script: ""),
        runtime: types_runner.default_runtime_config(),
        env_map: dict.new(),
        args: [],
        artifact_config: types_runner.default_artifact_config(),
        exec_path: option.None,
      ),
      interface: types_profile.RunnerInterface(capabilities: dict.new()),
    )

  let assert Ok(instance_id) = types_core.instance_id("inst-2")
  let params = dict.new()
  let workspace = "/tmp/workspace"
  let config = types_config.default_saar_config()
  let artifact_registry = process.new_subject()

  let args =
    messages.StartArgs(
      profile: profile,
      instance_id: instance_id,
      params: params,
      workspace: workspace,
      config: config,
      artifact_registry: artifact_registry,
    )

  let messages.StartArgs(
    profile: snapshot,
    instance_id: got_instance_id,
    params: got_params,
    workspace: got_workspace,
    config: got_config,
    artifact_registry: _,
  ) = args

  snapshot.meta.id |> should.equal(profile_id)
  got_instance_id |> should.equal(instance_id)
  got_params |> should.equal(params)
  got_workspace |> should.equal(workspace)
  got_config |> should.equal(config)
}

pub fn messages_types_compile() {
  // This test exists to ensure the message ADTs remain linkable from callers.
  let _key =
    messages.InstanceKey(types_core.profile_id("p"), {
      let assert Ok(id) = types_core.instance_id("i")
      id
    })

  Nil
}
