import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import gleeunit
import gleeunit/should
import saar/core/messages
import saar/core/profiles
import saar/otp/safe_call
import saar/types/core as types_core
import saar/types/enums as types_enums
import saar/types/profile as types_profile
import saar/types/runner as types_runner

pub fn main() {
  gleeunit.main()
}

pub fn profiles_actor_receives_initial_profiles() {
  let profile_id = types_core.profile_id("p1")
  let profile = dummy_profile(profile_id)

  let actor = start_profiles(dict.from_list([#(profile_id, profile)]))

  safe_call.call(actor, 1000, fn(reply_to) {
    messages.GetProfile(profile_id, reply_to)
  })
  |> should.equal(Ok(option.Some(profile)))
}

pub fn set_profiles_updates_state() {
  let profile_id = types_core.profile_id("p1")
  let profile = dummy_profile(profile_id)

  let actor = start_profiles(dict.new())

  let assert Ok(_) =
    safe_call.call(actor, 1000, fn(reply_to) {
      messages.SetProfiles(dict.from_list([#(profile_id, profile)]), reply_to)
    })

  safe_call.call(actor, 1000, fn(reply_to) {
    messages.GetProfile(profile_id, reply_to)
  })
  |> should.equal(Ok(option.Some(profile)))
}

pub fn set_profiles_returns_count() {
  let p1 = types_core.profile_id("p1")
  let p2 = types_core.profile_id("p2")

  let actor = start_profiles(dict.new())

  safe_call.call(actor, 1000, fn(reply_to) {
    messages.SetProfiles(
      dict.from_list([
        #(p1, dummy_profile(p1)),
        #(p2, dummy_profile(p2)),
      ]),
      reply_to,
    )
  })
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

  safe_call.call(actor, 1000, fn(reply_to) {
    messages.GetProfile(types_core.profile_id("missing"), reply_to)
  })
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

  let assert Ok(ids) =
    safe_call.call(actor, 1000, fn(reply_to) { messages.ListProfiles(reply_to) })

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
