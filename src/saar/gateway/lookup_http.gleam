//// Gateway HTTP wrappers for common actor lookups.
////
//// Mission: reduce duplication in HTTP handlers by standardizing how common
//// lookups (registry/profiles) map call failures to Problem Details responses.
////
//// Responsibilities:
//// - Map `safe_call.CallError` failures to `problem.from_call_error`.
//// - Map missing entities to `problem.not_found`.
////
//// Non-responsibilities:
//// - Performing access control.
//// - Parsing path parameters.
//// - Implementing business logic after the lookup.
////
//// Relationships:
//// - Built on top of `saar/gateway/lookup` (lookup without HTTP concerns).
//// - Used by gateway handlers such as `agents_api` and `ui_proxy_api`.

import gleam/erlang/process
import gleam/http/response
import gleam/option
import mist
import saar/core/agent
import saar/core/messages
import saar/gateway/lookup
import saar/gateway/problem
import saar/types/core as types_core
import saar/types/profile as types_profile

pub fn with_agent_ref(
  registry: process.Subject(messages.RegistryMsg),
  timeout_ms: Int,
  trace_id: types_core.TraceId,
  path: String,
  instance_id: types_core.InstanceId,
  cont: fn(agent.AgentRef) -> response.Response(mist.ResponseData),
) -> response.Response(mist.ResponseData) {
  case lookup.lookup_agent_ref(registry, timeout_ms, instance_id) {
    Error(call_err) -> problem.from_call_error(call_err, trace_id, path)
    Ok(option.None) -> problem.not_found(trace_id, path)
    Ok(option.Some(agent_ref)) -> cont(agent_ref)
  }
}

pub fn with_profile_or_404(
  profiles: process.Subject(messages.ProfilesMsg),
  timeout_ms: Int,
  trace_id: types_core.TraceId,
  path: String,
  profile_id: types_core.ProfileId,
  cont: fn(types_profile.Profile) -> response.Response(mist.ResponseData),
) -> response.Response(mist.ResponseData) {
  case lookup.get_profile(profiles, timeout_ms, profile_id) {
    Error(call_err) -> problem.from_call_error(call_err, trace_id, path)
    Ok(option.None) -> problem.not_found(trace_id, path)
    Ok(option.Some(profile)) -> cont(profile)
  }
}
