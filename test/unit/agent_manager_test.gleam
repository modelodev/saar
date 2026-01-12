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
import sad/core/registry_api
import sad/core/root_supervisor
import sad/core/supervisor_names
import sad/types/agent as types_agent
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums

pub fn main() {
  gleeunit.main()
}

pub fn start_agent_same_key_one_wins_test() {
  let cfg = types_config.default_sad_config()
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

pub fn start_agent_registration_failed_rolls_back_test() {
  let cfg = types_config.default_sad_config()
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
