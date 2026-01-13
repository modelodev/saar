//// Profile sources loader.
////
//// Mission: load a complete set of profiles from `profiles.sources` (dir/git)
//// and validate runner resolution within each source.
////
//// Responsibilities:
//// - Scan `<root>/profiles/*.json` and parse them into `Profile` values.
//// - Resolve runner scripts strictly within `<root>/runners`.
//// - For git sources: maintain a local cache and `clone/fetch/checkout`.
//// - Provide an atomic reload helper that only swaps profiles on success.
////
//// Non-responsibilities:
//// - Owning the in-memory profiles state (handled by `sad/core/profiles`).
//// - Starting/stopping instances.
////
//// Relationships:
//// - Produces `Dict(ProfileId, Profile)` used by `/sys/reload-profiles`.
//// - Uses `sad/core/messages.ProfilesMsg.SetProfiles` to swap the full set.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/port
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sad/core/boundary_call
import sad/core/messages
import sad/decoders
import sad/ffi
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/profile as types_profile
import sad/types/runner as types_runner
import simplifile

/// Errors returned while loading profiles from sources.
pub type ProfilesSourceError {
  SourceIoError(message: String)
  JsonParseError(path: String, message: String)
  ProfileDecodeError(path: String, message: String)
  RunnerMissing(profile_id: String, runner_type: String)
  RunnerNotExecutable(path: String)
  GitCommandFailed(command: String)
}

/// Result summary returned on successful reload.
pub type ReloadSummary {
  ReloadSummary(count: Int, profile_ids: List(types_core.ProfileId))
}

/// Loads profiles from the configured sources.
///
/// This is an IO boundary function and is intended to be called by the gateway.
pub fn load_profiles_from_sources(
  cfg: types_config.SadConfig,
) -> Result(
  Dict(types_core.ProfileId, types_profile.Profile),
  ProfilesSourceError,
) {
  let types_config.SadConfig(profiles: profiles_cfg, ..) = cfg
  let types_config.ProfilesConfig(
    sources: sources,
    git_cache_dir: git_cache_dir,
  ) = profiles_cfg

  let init = LoadAcc(profiles: dict.new(), origins: dict.new())

  list.fold(sources, Ok(init), fn(acc, source) {
    use acc <- result.try(acc)
    use loaded <- result.try(load_source(source, git_cache_dir))

    Ok(insert_loaded_profiles(acc, loaded))
  })
  |> result.map(fn(acc) { acc.profiles })
}

type LoadAcc {
  LoadAcc(
    profiles: Dict(types_core.ProfileId, types_profile.Profile),
    origins: Dict(types_core.ProfileId, String),
  )
}

type LoadedProfile {
  LoadedProfile(
    id: types_core.ProfileId,
    profile: types_profile.Profile,
    origin: String,
  )
}

fn insert_loaded_profiles(acc: LoadAcc, loaded: List(LoadedProfile)) -> LoadAcc {
  loaded
  |> list.fold(acc, fn(acc, item) {
    let LoadedProfile(id: id, profile: profile, origin: origin) = item

    case dict.has_key(acc.profiles, id) {
      True -> {
        let kept_from = case dict.get(acc.origins, id) {
          Ok(s) -> s
          Error(_) -> "unknown"
        }

        log_profile_override_ignored(id, kept_from, origin)
        acc
      }

      False ->
        LoadAcc(
          profiles: dict.insert(acc.profiles, id, profile),
          origins: dict.insert(acc.origins, id, origin),
        )
    }
  })
}

fn log_profile_override_ignored(
  id: types_core.ProfileId,
  kept_from: String,
  ignored_from: String,
) -> Nil {
  io.println(
    "profiles.reload perfil_duplicado id="
    <> types_core.profile_id_to_string(id)
    <> " ignorado="
    <> ignored_from
    <> " conservado="
    <> kept_from,
  )
}

/// Reloads the `ProfilesActor` atomically.
///
/// If loading fails, the previous set is kept.
pub fn reload_profiles(
  profiles: process.Subject(messages.ProfilesMsg),
  cfg: types_config.SadConfig,
  timeout_ms: Int,
) -> Result(ReloadSummary, ProfilesSourceError) {
  use loaded <- result.try(load_profiles_from_sources(cfg))

  // Only swap on success.
  use count <- result.try(
    boundary_call.call(profiles, timeout_ms, fn(reply_to) {
      messages.SetProfiles(loaded, reply_to)
    })
    |> result.map_error(fn(call_err) {
      SourceIoError(
        message: "profiles actor call failed: " <> string.inspect(call_err),
      )
    }),
  )

  let ids = dict.keys(loaded)
  Ok(ReloadSummary(count: count, profile_ids: ids))
}

fn load_source(
  source: types_config.ProfileSource,
  git_cache_dir: String,
) -> Result(List(LoadedProfile), ProfilesSourceError) {
  case source {
    types_config.ProfileSourceDir(path: root) -> load_dir_source(root)

    types_config.ProfileSourceGit(url: url, ref: ref) -> {
      use root <- result.try(ensure_git_checkout(git_cache_dir, url, ref))
      load_git_source(url, ref, root)
    }
  }
}

fn load_dir_source(
  root: String,
) -> Result(List(LoadedProfile), ProfilesSourceError) {
  let profiles_dir = root <> "/profiles"

  use entries <- result.try(
    simplifile.read_directory(at: profiles_dir)
    |> result.map_error(fn(err) {
      SourceIoError(
        message: "failed to read directory '"
        <> profiles_dir
        <> "': "
        <> simplifile.describe_error(err),
      )
    }),
  )

  entries
  |> list.filter(fn(name) { string.ends_with(name, ".json") })
  |> list.sort(string.compare)
  |> list.try_map(fn(name) {
    let path = profiles_dir <> "/" <> name
    use pair <- result.try(load_profile_file(root, path))
    let #(id, profile) = pair
    Ok(LoadedProfile(id: id, profile: profile, origin: "dir:" <> path))
  })
}

fn load_git_source(
  url: String,
  ref: Option(String),
  root: String,
) -> Result(List(LoadedProfile), ProfilesSourceError) {
  let profiles_dir = root <> "/profiles"

  use entries <- result.try(
    simplifile.read_directory(at: profiles_dir)
    |> result.map_error(fn(err) {
      SourceIoError(
        message: "failed to read directory '"
        <> profiles_dir
        <> "': "
        <> simplifile.describe_error(err),
      )
    }),
  )

  let label =
    "git:"
    <> url
    <> case ref {
      Some(r) -> "@" <> r
      None -> ""
    }

  entries
  |> list.filter(fn(name) { string.ends_with(name, ".json") })
  |> list.sort(string.compare)
  |> list.try_map(fn(name) {
    let path = profiles_dir <> "/" <> name
    use pair <- result.try(load_profile_file(root, path))
    let #(id, profile) = pair
    Ok(LoadedProfile(
      id: id,
      profile: profile,
      origin: label <> ":profiles/" <> name,
    ))
  })
}

fn load_profile_file(
  source_root: String,
  path: String,
) -> Result(#(types_core.ProfileId, types_profile.Profile), ProfilesSourceError) {
  use raw <- result.try(
    simplifile.read(from: path)
    |> result.map_error(fn(err) {
      SourceIoError(
        message: "failed to read file '"
        <> path
        <> "': "
        <> simplifile.describe_error(err),
      )
    }),
  )

  use dynamic <- result.try(
    json.parse(raw, decode.dynamic)
    |> result.map_error(fn(errs) {
      JsonParseError(path: path, message: string.inspect(errs))
    }),
  )

  use profile <- result.try(
    decoders.decode_profile(dynamic)
    |> result.map_error(fn(errs) {
      ProfileDecodeError(path: path, message: string.inspect(errs))
    }),
  )

  use profile <- result.try(resolve_runner_in_source(source_root, profile))

  Ok(#(profile.meta.id, profile))
}

fn resolve_runner_in_source(
  source_root: String,
  profile: types_profile.Profile,
) -> Result(types_profile.Profile, ProfilesSourceError) {
  let types_profile.Profile(runner: runner, ..) = profile
  let types_runner.Runner(type_: runner_type, tool_config: tool_config, ..) =
    runner

  case tool_config {
    types_runner.ToolConfigScript(_) -> {
      let profile_id = types_core.profile_id_to_string(profile.meta.id)

      use script_path <- result.try(resolve_runner_script(
        source_root,
        profile_id,
        runner_type,
      ))
      let next_runner =
        types_runner.Runner(
          ..runner,
          tool_config: types_runner.ToolConfigScript(script: script_path),
        )
      Ok(types_profile.Profile(..profile, runner: next_runner))
    }

    _ -> Ok(profile)
  }
}

fn resolve_runner_script(
  source_root: String,
  profile_id: String,
  runner_type: String,
) -> Result(String, ProfilesSourceError) {
  let runners_dir = source_root <> "/runners"
  let candidate_exec = runners_dir <> "/" <> runner_type
  let candidate_py = runners_dir <> "/" <> runner_type <> ".py"

  // Prefer an executable file without extension.
  case is_executable_file(candidate_exec) {
    Ok(True) -> Ok(candidate_exec)
    Ok(False) | Error(_) -> {
      // For `.py` runners we only require that the file exists. The runner is
      // invoked via `python_bin`.
      case is_file(candidate_py) {
        Ok(True) -> Ok(candidate_py)
        Ok(False) ->
          Error(RunnerMissing(profile_id: profile_id, runner_type: runner_type))
        Error(err) -> Error(err)
      }
    }
  }
}

fn is_file(path: String) -> Result(Bool, ProfilesSourceError) {
  simplifile.is_file(path)
  |> result.map_error(fn(err) {
    SourceIoError(
      message: "failed to stat '"
      <> path
      <> "': "
      <> simplifile.describe_error(err),
    )
  })
}

fn is_executable_file(path: String) -> Result(Bool, ProfilesSourceError) {
  use is_file <- result.try(
    simplifile.is_file(path)
    |> result.map_error(fn(err) {
      SourceIoError(
        message: "failed to stat '"
        <> path
        <> "': "
        <> simplifile.describe_error(err),
      )
    }),
  )

  case is_file {
    False -> Ok(False)
    True -> {
      use info <- result.try(
        simplifile.file_info(path)
        |> result.map_error(fn(err) {
          SourceIoError(
            message: "failed to stat '"
            <> path
            <> "': "
            <> simplifile.describe_error(err),
          )
        }),
      )

      let simplifile.FileInfo(mode: mode, ..) = info
      // Any executable bit set (user/group/other).
      Ok(int.bitwise_and(mode, 73) != 0)
    }
  }
}

fn validate_local_git_url_exists(
  url: String,
) -> Result(Nil, ProfilesSourceError) {
  case is_local_git_url(url) {
    False -> Ok(Nil)
    True ->
      case simplifile.is_directory(url) {
        Ok(True) -> Ok(Nil)
        _ ->
          Error(GitCommandFailed(
            command: "git clone: local path not found: " <> url,
          ))
      }
  }
}

fn is_local_git_url(url: String) -> Bool {
  string.starts_with(url, ".") || string.starts_with(url, "/")
}

fn ensure_git_checkout(
  git_cache_dir: String,
  url: String,
  ref: Option(String),
) -> Result(String, ProfilesSourceError) {
  use _ <- result.try(
    simplifile.create_directory_all(git_cache_dir)
    |> result.map_error(fn(err) {
      SourceIoError(
        message: "failed to create git cache dir '"
        <> git_cache_dir
        <> "': "
        <> simplifile.describe_error(err),
      )
    }),
  )

  let repo_dir = git_cache_dir <> "/" <> sanitize_repo_dir(url)

  let should_clone = case simplifile.is_directory(repo_dir) {
    Ok(True) -> False
    _ -> True
  }

  case should_clone {
    True -> {
      use _ <- result.try(validate_local_git_url_exists(url))

      run_git(["clone", url, repo_dir], ".", "git clone")
      |> result.map(fn(_) { repo_dir })
    }

    False ->
      run_git(["-C", repo_dir, "fetch", "--all", "--prune"], ".", "git fetch")
      |> result.try(fn(_) {
        case ref {
          None -> Ok(repo_dir)
          Some(r) ->
            run_git(["-C", repo_dir, "checkout", r], ".", "git checkout")
            |> result.map(fn(_) { repo_dir })
        }
      })
  }
}

fn run_git(
  args: List(String),
  cwd: String,
  label: String,
) -> Result(Nil, ProfilesSourceError) {
  use port <- result.try(
    ffi.open_port("git", args, [], cwd)
    |> result.map_error(fn(reason) {
      GitCommandFailed(command: label <> ": " <> reason)
    }),
  )

  wait_port_exit(port, label)
}

fn wait_port_exit(
  port: port.Port,
  label: String,
) -> Result(Nil, ProfilesSourceError) {
  case ffi.port_receive(port, 30_000) {
    Error(_) -> Error(GitCommandFailed(command: label <> ": timeout"))

    Ok(ffi.PortDataChunk(_)) -> wait_port_exit(port, label)

    Ok(ffi.PortExit(code)) ->
      case code {
        0 -> Ok(Nil)
        _ ->
          Error(GitCommandFailed(
            command: label <> ": exit " <> int.to_string(code),
          ))
      }
  }
}

fn sanitize_repo_dir(url: String) -> String {
  url
  |> string.to_graphemes
  |> list.map(fn(ch) {
    case
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_",
        ch,
      )
    {
      True -> ch
      False -> "_"
    }
  })
  |> string.join(with: "")
  |> fn(name) {
    case string.length(name) > 60 {
      True -> string.slice(name, 0, 60)
      False -> name
    }
  }
}
