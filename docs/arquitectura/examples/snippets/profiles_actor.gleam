// Extracted reference snippet (v0)
// Source: arquitectura/actores.md
// Purpose: documentation-only; may not compile as-is.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/option.{type Option}
import gleam/option
import gleam/otp/actor
import sad/core/messages.{
  type ProfilesMsg, GetProfile, ListProfiles, SetProfiles,
}
import sad/types.{type Profile, type ProfileId}

type State =
  Dict(ProfileId, Profile)

/// Arranca el ProfilesActor con un snapshot inicial.
pub fn start(
  name: Name(ProfilesMsg),
  initial_profiles: Dict(ProfileId, Profile),
) -> actor.StartResult(Subject(ProfilesMsg)) {
  let init = fn(self) {
    actor.initialised(initial_profiles)
    |> actor.returning(self)
  }

  actor.new_with_initialiser(5000, init)
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  state: State,
  msg: ProfilesMsg,
) -> actor.Next(State, ProfilesMsg) {
  case msg {
    SetProfiles(profiles, reply_to) -> {
      process.send(reply_to, dict.size(profiles))
      actor.continue(profiles)
    }
    GetProfile(profile_id, reply_to) -> {
      process.send(reply_to, dict.get(state, profile_id) |> option.from_result)
      actor.continue(state)
    }
    ListProfiles(reply_to) -> {
      process.send(reply_to, dict.keys(state))
      actor.continue(state)
    }
  }
}
