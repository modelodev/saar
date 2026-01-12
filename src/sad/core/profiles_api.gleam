////
//// Mission: provide a typed API for interacting with the `ProfilesActor`.
////
//// Responsibilities:
//// - Encapsulate message construction.
//// - Ensure timeouts are always explicit.
////
//// Non-responsibilities:
//// - Loading profiles from disk/git.
//// - Applying default timeouts.
////
//// Relationships:
//// - Targets `sad/core/messages.ProfilesMsg`.
//// - Uses `sad/otp/safe_call.call_within` for safe boundary calls.

import gleam/dict
import gleam/erlang/process
import gleam/option.{type Option}
import sad/core/messages
import sad/otp/safe_call
import sad/types/core as types_core
import sad/types/profile as types_profile

/// Replaces the current set of profiles.
///
/// Returns the number of profiles stored.
pub fn set_profiles(
  profiles: process.Subject(messages.ProfilesMsg),
  new_profiles: dict.Dict(types_core.ProfileId, types_profile.Profile),
  timeout_ms: Int,
) -> Result(Int, safe_call.CallError) {
  safe_call.call_within(profiles, timeout_ms, fn(reply_to) {
    messages.SetProfiles(new_profiles, reply_to)
  })
}

/// Returns a profile snapshot, if present.
pub fn get_profile(
  profiles: process.Subject(messages.ProfilesMsg),
  profile_id: types_core.ProfileId,
  timeout_ms: Int,
) -> Result(Option(types_profile.Profile), safe_call.CallError) {
  safe_call.call_within(profiles, timeout_ms, fn(reply_to) {
    messages.GetProfile(profile_id, reply_to)
  })
}

/// Lists all profile ids in a deterministic order.
pub fn list_profiles(
  profiles: process.Subject(messages.ProfilesMsg),
  timeout_ms: Int,
) -> Result(List(types_core.ProfileId), safe_call.CallError) {
  safe_call.call_within(profiles, timeout_ms, fn(reply_to) {
    messages.ListProfiles(reply_to)
  })
}
