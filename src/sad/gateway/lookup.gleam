//// Gateway lookup helpers for core actors.
////
//// Mission: centralize common gateway lookups (registry/profiles) without
//// introducing HTTP-specific concerns.
////
//// Responsibilities:
//// - Lookup agent refs in the Registry actor.
//// - Lookup profiles in the Profiles actor.
////
//// Non-responsibilities:
//// - Mapping failures to HTTP responses (handled by gateway handlers).
//// - Parsing path parameters or applying access control.
////
//// Relationships:
//// - Wraps `sad/otp/safe_call.call`.
//// - Used by gateway endpoints such as `agents_api` and `ui_proxy_api`.

import gleam/erlang/process
import gleam/option
import sad/core/agent
import sad/otp/safe_call
import sad/core/messages
import sad/types/core as types_core
import sad/types/profile as types_profile

pub fn lookup_agent_ref(
  registry: process.Subject(messages.RegistryMsg),
  timeout_ms: Int,
  instance_id: types_core.InstanceId,
) -> Result(option.Option(agent.AgentRef), safe_call.CallError) {
  safe_call.call(registry, timeout_ms, fn(reply_to) {
    messages.LookupByInstanceId(instance_id, reply_to)
  })
}

pub fn get_profile(
  profiles: process.Subject(messages.ProfilesMsg),
  timeout_ms: Int,
  profile_id: types_core.ProfileId,
) -> Result(option.Option(types_profile.Profile), safe_call.CallError) {
  safe_call.call(profiles, timeout_ms, fn(reply_to) {
    messages.GetProfile(profile_id, reply_to)
  })
}
