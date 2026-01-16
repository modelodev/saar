import gleam/list
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should
import saar/bridge/wrapper_env
import saar/types/config as types_config
import saar/types/enums as types_enums

pub fn main() {
  gleeunit.main()
}

pub fn wrapper_env_includes_landlock_policy_json_with_workspace_test() {
  let wrapper =
    types_config.WrapperConfig(
      read_buffer_bytes: 1,
      control_line_bytes: 2,
      poll_interval_ms: 3,
      post_kill_wait_ms: 4,
    )

  let policy =
    types_config.LandlockPolicyConfig(
      allow_read: ["/etc"],
      allow_exec: ["/usr"],
      allow_write: [],
    )

  let env =
    wrapper_env.append(
      [],
      wrapper,
      10,
      types_enums.LandlockEnforced,
      option.Some(policy),
      "/tmp/workspace-x",
    )

  // Ensure workspace is appended into allow lists.
  let json =
    env
    |> list.filter(fn(pair) { pair.0 == "SAAR_LANDLOCK_POLICY_JSON" })
    |> list.first
    |> option.from_result
    |> option.map(fn(pair) { pair.1 })
    |> option.unwrap("")

  string.contains(json, "\"/tmp/workspace-x\"")
  |> should.equal(True)
}
