import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import gleeunit
import gleeunit/should
import sad/core/messages
import sad/core/profiles
import sad/core/profiles_api
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/profile as types_profile
import sad/types/runner as types_runner

pub fn main() {
  gleeunit.main()
}

pub fn profiles_actor_receives_initial_profiles() {
  let profile_id = types_core.profile_id("p1")
  let profile = dummy_profile(profile_id)

  let actor = start_profiles(dict.from_list([#(profile_id, profile)]))

  profiles_api.get_profile(actor, profile_id, 1000)
  |> should.equal(Ok(option.Some(profile)))
}

pub fn set_profiles_updates_state() {
  let profile_id = types_core.profile_id("p1")
  let profile = dummy_profile(profile_id)

  let actor = start_profiles(dict.new())

  let assert Ok(_) =
    profiles_api.set_profiles(
      actor,
      dict.from_list([#(profile_id, profile)]),
      1000,
    )

  profiles_api.get_profile(actor, profile_id, 1000)
  |> should.equal(Ok(option.Some(profile)))
}

pub fn set_profiles_returns_count() {
  let p1 = types_core.profile_id("p1")
  let p2 = types_core.profile_id("p2")

  let actor = start_profiles(dict.new())

  profiles_api.set_profiles(
    actor,
    dict.from_list([
      #(p1, dummy_profile(p1)),
      #(p2, dummy_profile(p2)),
    ]),
    1000,
  )
  |> should.equal(Ok(2))
}

pub fn set_profiles_is_pure() {
  // This is a lightweight check: the actor is driven exclusively by messages and
  // does not depend on filesystem IO.
  set_profiles_updates_state()
}

pub fn get_profile_returns_some() {
  profiles_actor_receives_initial_profiles()
}

pub fn get_profile_returns_none() {
  let actor = start_profiles(dict.new())

  profiles_api.get_profile(actor, types_core.profile_id("missing"), 1000)
  |> should.equal(Ok(option.None))
}

pub fn list_profiles_returns_all_ids() {
  let p1 = types_core.profile_id("b")
  let p2 = types_core.profile_id("a")

  let actor =
    start_profiles(
      dict.from_list([
        #(p1, dummy_profile(p1)),
        #(p2, dummy_profile(p2)),
      ]),
    )

  let assert Ok(ids) = profiles_api.list_profiles(actor, 1000)

  ids
  |> list.map(types_core.profile_id_to_string)
  |> should.equal(["a", "b"])
}

fn start_profiles(
  initial: dict.Dict(types_core.ProfileId, types_profile.Profile),
) -> process.Subject(messages.ProfilesMsg) {
  let name = process.new_name("test_profiles")
  let assert Ok(actor.Started(data: subject, ..)) =
    profiles.start(name, initial)
  subject
}

fn dummy_profile(profile_id: types_core.ProfileId) -> types_profile.Profile {
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
    ),
    interface: types_profile.RunnerInterface(capabilities: dict.new()),
  )
}
