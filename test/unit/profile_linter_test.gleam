import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import saar/types/core as types_core
import saar/types/enums as types_enums
import saar/types/profile as types_profile
import saar/types/runner as types_runner
import saar/validation/profile_linter

pub fn main() {
  gleeunit.main()
}

pub fn lint_duplicate_capability_id_test() {
  let profile = sample_profile()
  let ctx =
    profile_linter.LintContext(
      expected_schema_version: "saar.profile/1.0",
      available_runners: ["echo"],
      file: None,
      capability_ids: Some(["chat", "chat"]),
    )

  let diags =
    profile_linter.lint_profile(profile, Some("saar.profile/1.0"), ctx)

  diags
  |> list.map(fn(d) { d.code })
  |> list.any(fn(code) { code == "duplicate_capability_id" })
  |> should.equal(True)
}

pub fn lint_runner_missing_test() {
  let profile = sample_profile()
  let ctx =
    profile_linter.LintContext(
      expected_schema_version: "saar.profile/1.0",
      available_runners: [],
      file: None,
      capability_ids: None,
    )

  let diags =
    profile_linter.lint_profile(profile, Some("saar.profile/1.0"), ctx)

  diags
  |> list.map(fn(d) { d.code })
  |> list.any(fn(code) { code == "runner_missing" })
  |> should.equal(True)
}

pub fn lint_schema_version_mismatch_test() {
  let profile = sample_profile()
  let ctx =
    profile_linter.LintContext(
      expected_schema_version: "saar.profile/1.0",
      available_runners: ["echo"],
      file: None,
      capability_ids: None,
    )

  let diags =
    profile_linter.lint_profile(profile, Some("saar.profile/9.9"), ctx)

  diags
  |> list.map(fn(d) { d.code })
  |> list.any(fn(code) { code == "schema_version_mismatch" })
  |> should.equal(True)
}

fn sample_profile() -> types_profile.Profile {
  let profile_id = types_core.profile_id("echo")
  let meta =
    types_profile.ProfileMeta(
      id: profile_id,
      name: None,
      lifecycle: types_enums.Transient,
      description: "sample",
    )

  let runner =
    types_runner.Runner(
      type_: "echo",
      tool_config: types_runner.ToolConfigScript("echo.py"),
      runtime: types_runner.default_runtime_config(),
      env_map: dict.new(),
      args: [],
      artifact_config: types_runner.default_artifact_config(),
      exec_path: None,
    )

  let interface = types_profile.RunnerInterface(dict.new())

  types_profile.Profile(
    meta: meta,
    parameters: dict.new(),
    runner: runner,
    interface: interface,
  )
}
