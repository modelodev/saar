import agent_helpers
import gleam/dict
import gleam/erlang/process
import gleam/option
import gleam/otp/actor
import gleeunit
import gleeunit/should
import sad/app_state
import sad/core/agent
import sad/core/agent_manager_api
import sad/core/messages
import sad/core/profiles_api
import sad/core/registry_api
import sad/core/root_supervisor
import sad/core/supervisor_names
import sad/types/agent as types_agent
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/profile as types_profile
import sad/types/runner as types_runner
import test_assertions

pub fn main() {
  gleeunit.main()
}

pub fn start_agent_same_key_one_wins_test() {
  let cfg = agent_helpers.default_config()
  let names = supervisor_names.new_names()

  let state = app_state.AppState(config: cfg, initial_profiles: dict.new())

  let assert Ok(actor.Started(data: _ref, ..)) =
    root_supervisor.start(state, names)

  let supervisor_names.RootNames(registry_name, _, _, _, agent_manager_name, _) =
    names

  let registry = process.named_subject(registry_name)
  let manager = process.named_subject(agent_manager_name)

  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-one-wins")

  let args =
    messages.StartArgs(
      profile: profile,
      instance_id: instance_id,
      params: dict.new(),
      workspace: agent_helpers.workspace_root(),
      config: cfg,
    )

  let out1 = process.new_subject()
  let out2 = process.new_subject()

  let _ =
    process.spawn(fn() {
      process.send(out1, agent_manager_api.start_agent(manager, args, 5000))
    })

  let _ =
    process.spawn(fn() {
      process.send(out2, agent_manager_api.start_agent(manager, args, 5000))
    })

  let assert Ok(r1) = process.receive(out1, 5000)
  let assert Ok(r2) = process.receive(out2, 5000)

  assert_one_ok_one_already_exists(r1, r2)

  let assert Ok(count) = registry_api.count(registry, 1000)
  count |> should.equal(1)
}

pub fn create_agent_profile_not_found_test() {
  let cfg = agent_helpers.default_config()
  let names = supervisor_names.new_names()

  let state = app_state.AppState(config: cfg, initial_profiles: dict.new())

  let assert Ok(actor.Started(..)) = root_supervisor.start(state, names)

  let supervisor_names.RootNames(_, _, _, _profiles_name, agent_manager_name, _) =
    names

  let manager = process.named_subject(agent_manager_name)

  let assert Ok(instance_id) = types_core.instance_id("inst-missing-profile")

  agent_manager_api.create_agent(
    manager,
    types_core.profile_id("missing"),
    instance_id,
    dict.new(),
    5000,
  )
  |> should.equal(
    Error(
      agent_manager_api.ActorError(
        messages.ProfileNotFound(types_core.profile_id("missing")),
      ),
    ),
  )
}

pub fn create_agent_uses_profiles_actor_test() {
  let cfg = agent_helpers.default_config()
  let names = supervisor_names.new_names()

  let state = app_state.AppState(config: cfg, initial_profiles: dict.new())

  let assert Ok(actor.Started(..)) = root_supervisor.start(state, names)

  let supervisor_names.RootNames(
    registry_name,
    _,
    _,
    profiles_name,
    agent_manager_name,
    _,
  ) = names

  let registry = process.named_subject(registry_name)
  let profiles = process.named_subject(profiles_name)
  let manager = process.named_subject(agent_manager_name)

  let parameters =
    dict.from_list([
      #(
        "host",
        types_profile.ConfigParam(
          "server.host",
          option.None,
          types_profile.ParamString,
        ),
      ),
    ])

  let profile =
    types_profile.Profile(
      meta: types_profile.ProfileMeta(
        id: types_core.profile_id("p1"),
        name: option.None,
        lifecycle: types_enums.Transient,
        description: "test",
      ),
      parameters: parameters,
      runner: types_runner.Runner(
        type_: "test",
        tool_config: types_runner.ToolConfigScript(""),
        runtime: types_runner.default_runtime_config(),
        env_map: dict.new(),
        args: [],
        artifact_config: types_runner.default_artifact_config(),
      ),
      interface: types_profile.RunnerInterface(capabilities: dict.new()),
    )

  let assert Ok(_) =
    profiles_api.set_profiles(
      profiles,
      dict.from_list([#(profile.meta.id, profile)]),
      1000,
    )

  let assert Ok(instance_id) = types_core.instance_id("inst-from-profile")

  let _ =
    agent_manager_api.create_agent(
      manager,
      profile.meta.id,
      instance_id,
      dict.new(),
      5000,
    )
    |> test_assertions.assert_ok

  let assert Ok(count) = registry_api.count(registry, 1000)
  count |> should.equal(1)
}

pub fn start_agent_registration_failed_rolls_back_test() {
  let cfg = agent_helpers.default_config()
  let names = supervisor_names.new_names()

  let state = app_state.AppState(config: cfg, initial_profiles: dict.new())

  let assert Ok(actor.Started(data: _ref, ..)) =
    root_supervisor.start(state, names)

  let supervisor_names.RootNames(registry_name, _, _, _, agent_manager_name, _) =
    names

  let registry = process.named_subject(registry_name)
  let manager = process.named_subject(agent_manager_name)

  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-already-exists")

  // Pre-register a dummy agent to force `AlreadyExists`.
  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      agent_helpers.workspace_root(),
      cfg,
      agent.default_deps(),
      1000,
    )

  let status =
    types_agent.AgentStatusView(
      profile_id: profile.meta.id,
      instance_id: instance_id,
      lifecycle: profile.meta.lifecycle,
      phase: types_agent.Created,
      mode: types_agent.RunIdle,
      assigned_port: option.None,
      failure_reason: option.None,
    )

  let assert Ok(_) = registry_api.register(registry, status, agent_ref, 1000)

  let args =
    messages.StartArgs(
      profile: profile,
      instance_id: instance_id,
      params: dict.new(),
      workspace: agent_helpers.workspace_root(),
      config: cfg,
    )

  agent_manager_api.start_agent(manager, args, 5000)
  |> should.equal(
    Error(
      agent_manager_api.ActorError(messages.RegistrationFailed(
        messages.AlreadyExists,
      )),
    ),
  )

  let assert Ok(count) = registry_api.count(registry, 1000)
  count |> should.equal(1)
}

fn assert_one_ok_one_already_exists(
  r1: Result(
    agent.AgentRef,
    agent_manager_api.ApiCallError(messages.StartError),
  ),
  r2: Result(
    agent.AgentRef,
    agent_manager_api.ApiCallError(messages.StartError),
  ),
) -> Nil {
  case r1, r2 {
    Ok(_),
      Error(agent_manager_api.ActorError(messages.RegistrationFailed(
        messages.AlreadyExists,
      )))
    -> Nil

    Error(agent_manager_api.ActorError(messages.RegistrationFailed(
      messages.AlreadyExists,
    ))),
      Ok(_)
    -> Nil

    _, _ -> panic as "Expected one Ok and one AlreadyExists"
  }
}
