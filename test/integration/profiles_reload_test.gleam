import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/string
import gleeunit
import gleeunit/should
import saar/core/messages
import saar/core/profiles
import saar/ffi
import saar/otp/safe_call
import saar/profiles_sources
import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/profile as types_profile
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

  count |> should.equal(18)

  ids
  |> list.map(types_core.profile_id_to_string)
  |> list.sort(string.compare)
  |> should.equal([
    "artifact_gen",
    "artifact_gen_deferred",
    "bad_base_url",
    "crasher",
    "echo_cli",
    "echo_cli_deferred",
    "echo_cli_deferred_slow",
    "echo_files_one",
    "echo_files_zero",
    "echo_server",
    "echo_server_files_missing",
    "echo_server_files_track",
    "error_cli_deferred",
    "fs_probe",
    "greedy_logger",
    "runner_only_continuous",
    "slow_poke",
    "streaming_echo",
  ])
}

pub fn reload_duplicate_ids_first_source_wins_test() {
  let root_a = "build/test-workspaces/source-first"
  let root_b = "build/test-workspaces/source-second"

  reset_two_sources(root_a, root_b)

  // Mutate a profile in the second source; it must be ignored.
  write_profile(
    root_b,
    "echo_cli.json",
    echo_cli_profile_json("echo_cli", "Echo CLI overridden"),
  )

  let profiles_actor = start_profiles(dict.new())
  let cfg = config_with_dir_sources([root_a, root_b])

  let profiles_sources.ReloadSummary(count: count, ..) =
    profiles_sources.reload_profiles(profiles_actor, cfg, 5000)
    |> test_assertions.assert_ok

  count |> should.equal(18)
  assert_profile_description(profiles_actor, "echo_cli", "Echo CLI for testing")
}

pub fn reload_duplicate_ids_order_inverts_winner_test() {
  let root_a = "build/test-workspaces/source-first-order"
  let root_b = "build/test-workspaces/source-second-order"

  reset_two_sources(root_a, root_b)

  write_profile(
    root_b,
    "echo_cli.json",
    echo_cli_profile_json("echo_cli", "Echo CLI overridden"),
  )

  let profiles_actor = start_profiles(dict.new())
  // Winner changes when order changes.
  let cfg = config_with_dir_sources([root_b, root_a])

  let profiles_sources.ReloadSummary(count: count, ..) =
    profiles_sources.reload_profiles(profiles_actor, cfg, 5000)
    |> test_assertions.assert_ok

  count |> should.equal(18)
  assert_profile_description(profiles_actor, "echo_cli", "Echo CLI overridden")
}

pub fn reload_duplicate_ids_three_sources_keeps_first_test() {
  let root_a = "build/test-workspaces/source-first-3"
  let root_b = "build/test-workspaces/source-second-3"
  let root_c = "build/test-workspaces/source-third-3"

  let _ = simplifile.delete(file_or_dir_at: root_a)
  let _ = simplifile.delete(file_or_dir_at: root_b)
  let _ = simplifile.delete(file_or_dir_at: root_c)

  simplifile.copy_directory(at: "test/fixtures/source_local", to: root_a)
  |> test_assertions.assert_ok
  simplifile.copy_directory(at: "test/fixtures/source_local", to: root_b)
  |> test_assertions.assert_ok
  simplifile.copy_directory(at: "test/fixtures/source_local", to: root_c)
  |> test_assertions.assert_ok

  write_profile(
    root_b,
    "echo_cli.json",
    echo_cli_profile_json("echo_cli", "Echo CLI overridden"),
  )
  write_profile(
    root_c,
    "echo_cli.json",
    echo_cli_profile_json("echo_cli", "Echo CLI overridden 2"),
  )

  let profiles_actor = start_profiles(dict.new())
  let cfg = config_with_dir_sources([root_a, root_b, root_c])

  let profiles_sources.ReloadSummary(count: count, ..) =
    profiles_sources.reload_profiles(profiles_actor, cfg, 5000)
    |> test_assertions.assert_ok

  count |> should.equal(18)
  assert_profile_description(profiles_actor, "echo_cli", "Echo CLI for testing")
}

pub fn reload_duplicate_ids_within_dir_keeps_first_and_adds_new_test() {
  let root = "build/test-workspaces/source-within-dir-plus"
  let _ = simplifile.delete(file_or_dir_at: root)
  simplifile.copy_directory(at: "test/fixtures/source_local", to: root)
  |> test_assertions.assert_ok

  write_profile(
    root,
    "0_override_echo_cli.json",
    echo_cli_profile_json("echo_cli", "Echo CLI overridden"),
  )

  write_profile(
    root,
    "extra_echo_cli.json",
    echo_cli_profile_json("extra_echo_cli", "Extra profile"),
  )

  let profiles_actor = start_profiles(dict.new())
  let cfg = config_with_dir_source(root)

  let profiles_sources.ReloadSummary(count: count, ..) =
    profiles_sources.reload_profiles(profiles_actor, cfg, 5000)
    |> test_assertions.assert_ok

  count |> should.equal(19)
  assert_profile_description(profiles_actor, "echo_cli", "Echo CLI overridden")
  assert_profile_description(profiles_actor, "extra_echo_cli", "Extra profile")
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

pub fn reload_git_source_failure_keeps_previous() {
  let profiles_actor = start_profiles(dict.new())

  // First: load from a valid dir source.
  profiles_sources.reload_profiles(
    profiles_actor,
    config_with_dir_source("test/fixtures/source_local"),
    5000,
  )
  |> should.be_ok

  let assert Ok(before_ids) =
    safe_call.call(profiles_actor, 1000, fn(reply_to) {
      messages.ListProfiles(reply_to)
    })
  list.length(before_ids) |> should.equal(10)

  // Then: reload from a failing git source; it must not swap.
  let cfg =
    config_with_git_source(
      "./does-not-exist-repo",
      "build/test-workspaces/git-cache",
    )

  profiles_sources.reload_profiles(profiles_actor, cfg, 5000)
  |> should.be_error

  let assert Ok(after_ids) =
    safe_call.call(profiles_actor, 1000, fn(reply_to) {
      messages.ListProfiles(reply_to)
    })
  list.length(after_ids) |> should.equal(10)
}

fn init_git_repo(path: String) -> Nil {
  run_git(["init"], path)
  run_git(["add", "."], path)

  run_git(
    [
      "-c",
      "user.email=test@example.com",
      "-c",
      "user.name=test",
      "commit",
      "-m",
      "init",
    ],
    path,
  )
}

fn run_git(args: List(String), cwd: String) -> Nil {
  let port = ffi.open_port("git", args, [], cwd) |> test_assertions.assert_ok
  wait_git_exit(port)
}

fn wait_git_exit(port) -> Nil {
  case ffi.port_receive(port, 30_000) {
    Ok(ffi.PortDataChunk(_)) -> wait_git_exit(port)
    Ok(ffi.PortExit(0)) -> Nil
    Ok(ffi.PortExit(code)) -> panic as { "git exit " <> int.to_string(code) }
    Error(_) -> panic as "git timeout"
  }
}

pub fn reload_git_source_corrupt_reclone() {
  let origin = "build/test-workspaces/git-origin-corrupt"
  let cache = "build/test-workspaces/git-cache-corrupt"

  let _ = simplifile.delete(file_or_dir_at: origin)
  let _ = simplifile.delete(file_or_dir_at: cache)

  simplifile.copy_directory(at: "test/fixtures/source_local", to: origin)
  |> test_assertions.assert_ok

  init_git_repo(origin)

  let profiles_actor = start_profiles(dict.new())
  let cfg = config_with_git_source(origin, cache)

  profiles_sources.reload_profiles(profiles_actor, cfg, 5000)
  |> should.be_ok

  let entries_1 =
    simplifile.read_directory(at: cache)
    |> test_assertions.assert_ok

  let assert [repo_dir_name] = entries_1
  let repo_dir = cache <> "/" <> repo_dir_name

  // Corrupt the cached checkout by removing its .git metadata.
  simplifile.delete(file_or_dir_at: repo_dir <> "/.git")
  |> test_assertions.assert_ok

  profiles_sources.reload_profiles(profiles_actor, cfg, 5000)
  |> should.be_ok

  let entries_2 =
    simplifile.read_directory(at: cache)
    |> test_assertions.assert_ok

  entries_2
  |> list.any(fn(name) { string.starts_with(name, repo_dir_name <> ".broken-") })
  |> should.equal(True)
}

fn config_with_dir_source(path: String) -> types_config.SaarConfig {
  config_with_dir_sources([path])
}

fn config_with_dir_sources(paths: List(String)) -> types_config.SaarConfig {
  let cfg = types_config.default_saar_config()
  let types_config.SaarConfig(profiles: profiles_cfg, ..) = cfg
  let types_config.ProfilesConfig(git_cache_dir: git_cache_dir, ..) =
    profiles_cfg

  let sources =
    paths
    |> list.map(fn(path) { types_config.ProfileSourceDir(path: path) })

  let profiles_cfg =
    types_config.ProfilesConfig(sources: sources, git_cache_dir: git_cache_dir)

  types_config.SaarConfig(..cfg, profiles: profiles_cfg)
}

fn reset_two_sources(root_a: String, root_b: String) -> Nil {
  let _ = simplifile.delete(file_or_dir_at: root_a)
  let _ = simplifile.delete(file_or_dir_at: root_b)

  simplifile.copy_directory(at: "test/fixtures/source_local", to: root_a)
  |> test_assertions.assert_ok

  simplifile.copy_directory(at: "test/fixtures/source_local", to: root_b)
  |> test_assertions.assert_ok
}

fn write_profile(root: String, filename: String, contents: String) -> Nil {
  simplifile.write(to: root <> "/profiles/" <> filename, contents: contents)
  |> test_assertions.assert_ok
}

fn assert_profile_description(
  profiles_actor: process.Subject(messages.ProfilesMsg),
  id: String,
  expected: String,
) -> Nil {
  let profile_id = types_core.profile_id(id)

  let assert Ok(option.Some(profile)) =
    safe_call.call(profiles_actor, 1000, fn(reply_to) {
      messages.GetProfile(profile_id, reply_to)
    })

  let types_profile.Profile(meta: meta, ..) = profile
  meta.description |> should.equal(expected)
}

fn echo_cli_profile_json(id: String, description: String) -> String {
  "{\n"
  <> "  \"meta\": {\n"
  <> "    \"id\": \""
  <> id
  <> "\",\n"
  <> "    \"lifecycle\": \"transient\",\n"
  <> "    \"description\": \""
  <> description
  <> "\"\n"
  <> "  },\n"
  <> "  \"parameters\": {\n"
  <> "    \"delay_ms\": {\"source\": \"fixed\", \"value\": 100, \"type\": \"int\"}\n"
  <> "  },\n"
  <> "  \"runner\": {\n"
  <> "    \"type\": \"echo_cli\",\n"
  <> "    \"tool_config\": {\"script\": \"echo_cli.py\"}\n"
  <> "  },\n"
  <> "  \"interface\": {\n"
  <> "    \"protocol\": \"runner\",\n"
  <> "    \"capabilities\": {\n"
  <> "      \"echo\": {\"input_schema\": \"std:chat\", \"streaming\": false}\n"
  <> "    }\n"
  <> "  }\n"
  <> "}\n"
}

fn config_with_git_source(
  url: String,
  cache_dir: String,
) -> types_config.SaarConfig {
  let cfg = types_config.default_saar_config()

  let profiles_cfg =
    types_config.ProfilesConfig(
      sources: [types_config.ProfileSourceGit(url: url, ref: option.None)],
      git_cache_dir: cache_dir,
    )

  types_config.SaarConfig(..cfg, profiles: profiles_cfg)
}

fn start_profiles(
  initial: dict.Dict(types_core.ProfileId, types_profile.Profile),
) -> process.Subject(messages.ProfilesMsg) {
  let name = process.new_name("test_profiles_reload")
  let assert Ok(actor.Started(data: subject, ..)) =
    profiles.start(name, initial)
  subject
}
