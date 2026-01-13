import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/string
import gleeunit
import gleeunit/should
import sad/core/boundary_call
import sad/core/messages
import sad/core/profiles
import sad/profiles_sources
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/profile as types_profile
import simplifile
import test_assertions

pub fn main() {
  gleeunit.main()
}

pub fn reload_dir_source_ok_test() {
  let profiles_actor = start_profiles(dict.new())
  let cfg = config_with_dir_source("test/fixtures/source_local")

  let profiles_sources.ReloadSummary(count: count, profile_ids: ids) =
    profiles_sources.reload_profiles(profiles_actor, cfg, 5000)
    |> test_assertions.assert_ok

  count |> should.equal(7)

  ids
  |> list.map(types_core.profile_id_to_string)
  |> list.sort(string.compare)
  |> should.equal([
    "artifact_gen",
    "crasher",
    "echo_cli",
    "echo_server",
    "greedy_logger",
    "slow_poke",
    "streaming_echo",
  ])
}

pub fn reload_missing_runner_fails_test() {
  let tmp_root = "build/test-workspaces/source-missing-runner"
  let _ = simplifile.delete(file_or_dir_at: tmp_root)

  simplifile.copy_directory(at: "test/fixtures/source_local", to: tmp_root)
  |> test_assertions.assert_ok

  let missing = tmp_root <> "/runners/echo_cli.py"
  simplifile.delete(file_or_dir_at: missing) |> test_assertions.assert_ok

  let profiles_actor = start_profiles(dict.new())
  let cfg = config_with_dir_source(tmp_root)

  let err =
    profiles_sources.reload_profiles(profiles_actor, cfg, 5000)
    |> test_assertions.assert_error

  case err {
    profiles_sources.RunnerMissing(
      profile_id: "echo_cli",
      runner_type: "echo_cli",
    ) -> Nil
    other ->
      panic as { "Expected RunnerMissing, got " <> string.inspect(other) }
  }
}

pub fn reload_git_source_failure_keeps_previous_test() {
  let profiles_actor = start_profiles(dict.new())

  // First: load from a valid dir source.
  profiles_sources.reload_profiles(
    profiles_actor,
    config_with_dir_source("test/fixtures/source_local"),
    5000,
  )
  |> should.be_ok

  let assert Ok(before_ids) =
    boundary_call.call(profiles_actor, 1000, fn(reply_to) {
      messages.ListProfiles(reply_to)
    })
  list.length(before_ids) |> should.equal(7)

  // Then: reload from a failing git source; it must not swap.
  let cfg =
    config_with_git_source(
      "./does-not-exist-repo",
      "build/test-workspaces/git-cache",
    )

  profiles_sources.reload_profiles(profiles_actor, cfg, 5000)
  |> should.be_error

  let assert Ok(after_ids) =
    boundary_call.call(profiles_actor, 1000, fn(reply_to) {
      messages.ListProfiles(reply_to)
    })
  list.length(after_ids) |> should.equal(7)
}

fn config_with_dir_source(path: String) -> types_config.SadConfig {
  let cfg = types_config.default_sad_config()
  let types_config.SadConfig(profiles: profiles_cfg, ..) = cfg
  let types_config.ProfilesConfig(git_cache_dir: git_cache_dir, ..) =
    profiles_cfg

  let profiles_cfg =
    types_config.ProfilesConfig(
      sources: [types_config.ProfileSourceDir(path: path)],
      git_cache_dir: git_cache_dir,
    )

  types_config.SadConfig(..cfg, profiles: profiles_cfg)
}

fn config_with_git_source(
  url: String,
  cache_dir: String,
) -> types_config.SadConfig {
  let cfg = types_config.default_sad_config()

  let profiles_cfg =
    types_config.ProfilesConfig(
      sources: [types_config.ProfileSourceGit(url: url, ref: option.None)],
      git_cache_dir: cache_dir,
    )

  types_config.SadConfig(..cfg, profiles: profiles_cfg)
}

fn start_profiles(
  initial: dict.Dict(types_core.ProfileId, types_profile.Profile),
) -> process.Subject(messages.ProfilesMsg) {
  let name = process.new_name("test_profiles_reload")
  let assert Ok(actor.Started(data: subject, ..)) =
    profiles.start(name, initial)
  subject
}
