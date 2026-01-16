////
//// Mission: build wrapper-related environment variables.
////
//// Responsibilities:
//// - Inject wrapper runtime tuning env vars.
//// - Encode and inject the Landlock policy JSON for the wrapper.
////
//// Non-responsibilities:
//// - Parsing configuration sources.
//// - Starting runner processes.
////
//// Relationships:
//// - Used by `sad/bridge/runner` and `sad/bridge/interaction`.
//// - Consumes `sad/types/config` values.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import sad/types/config as types_config
import sad/types/enums as types_enums

/// Appends wrapper-specific environment variables.
///
/// This is a pure helper that keeps wrapper env construction consistent across
/// the transient and streaming code paths.
pub fn append(
  env: List(#(String, String)),
  wrapper: types_config.WrapperConfig,
  shutdown_timeout_ms: Int,
  landlock_mode: types_enums.LandlockMode,
  landlock_policy: Option(types_config.LandlockPolicyConfig),
  workspace: String,
) -> List(#(String, String)) {
  let types_config.WrapperConfig(
    read_buffer_bytes: read_buffer_bytes,
    control_line_bytes: control_line_bytes,
    poll_interval_ms: poll_interval_ms,
    post_kill_wait_ms: post_kill_wait_ms,
  ) = wrapper

  let base = [
    #("SAD_SHUTDOWN_MS", int.to_string(shutdown_timeout_ms)),
    #("SAD_WRAPPER_READ_BUFFER_BYTES", int.to_string(read_buffer_bytes)),
    #("SAD_WRAPPER_CONTROL_LINE_BYTES", int.to_string(control_line_bytes)),
    #("SAD_WRAPPER_POLL_MS", int.to_string(poll_interval_ms)),
    #("SAD_WRAPPER_POST_KILL_WAIT_MS", int.to_string(post_kill_wait_ms)),
    #("SAD_LANDLOCK_MODE", types_enums.landlock_mode_to_string(landlock_mode)),
  ]

  let policy_json = landlock_policy_json(landlock_policy, workspace)

  let policy = case policy_json {
    option.Some(policy_json) -> [#("SAD_LANDLOCK_POLICY_JSON", policy_json)]
    option.None -> []
  }

  list.append(env, list.append(base, policy))
}

fn landlock_policy_json(
  policy_opt: Option(types_config.LandlockPolicyConfig),
  workspace: String,
) -> Option(String) {
  case policy_opt {
    option.None -> option.None
    option.Some(policy0) -> {
      let types_config.LandlockPolicyConfig(
        allow_read: allow_read0,
        allow_exec: allow_exec0,
        allow_write: allow_write0,
      ) = policy0

      let allow_read = list.append(allow_read0, [workspace])
      let allow_write = list.append(allow_write0, [workspace])

      json.object([
        #("allow_read", json.array(allow_read, json.string)),
        #("allow_exec", json.array(allow_exec0, json.string)),
        #("allow_write", json.array(allow_write, json.string)),
      ])
      |> json.to_string
      |> option.Some
    }
  }
}
