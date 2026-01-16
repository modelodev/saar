////
//// Mission: keep a SSOT of loaded profiles in memory.
////
//// Responsibilities:
//// - Store the current set of profiles as a pure in-memory dictionary.
//// - Replace the full set atomically via `SetProfiles`.
//// - Serve profile snapshots to other core components.
////
//// Non-responsibilities:
//// - Loading profiles from disk/git (boundary responsibility).
//// - Performing any IO.
////
//// Relationships:
//// - Message protocol lives in `saar/core/messages.ProfilesMsg`.
//// - Public calls are done via messages (see `saar/core/messages`).

import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/string
import saar/core/messages
import saar/types/core as types_core
import saar/types/profile as types_profile

pub fn start(
  name: process.Name(messages.ProfilesMsg),
  initial_profiles: dict.Dict(types_core.ProfileId, types_profile.Profile),
) -> actor.StartResult(process.Subject(messages.ProfilesMsg)) {
  actor.new(initial_profiles)
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

type State =
  dict.Dict(types_core.ProfileId, types_profile.Profile)

fn sort_profile_ids(
  ids: List(types_core.ProfileId),
) -> List(types_core.ProfileId) {
  ids
  |> list.sort(fn(a, b) {
    string.compare(
      types_core.profile_id_to_string(a),
      types_core.profile_id_to_string(b),
    )
  })
}

fn handle_message(
  state: State,
  msg: messages.ProfilesMsg,
) -> actor.Next(State, messages.ProfilesMsg) {
  case msg {
    messages.SetProfiles(profiles, reply_to) -> {
      process.send(reply_to, dict.size(profiles))
      actor.continue(profiles)
    }

    messages.GetProfile(profile_id, reply_to) -> {
      process.send(reply_to, dict.get(state, profile_id) |> option.from_result)
      actor.continue(state)
    }

    messages.ListProfiles(reply_to) -> {
      let ids = dict.keys(state) |> sort_profile_ids
      process.send(reply_to, ids)
      actor.continue(state)
    }
  }
}
