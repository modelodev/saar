import filepath
import gleam/option
import gleam/string
import saar/types/profile as types_profile
import saar/types/runner as types_runner
import simplifile

pub fn resolve_fixture_runner(
  profile: types_profile.Profile,
) -> types_profile.Profile {
  let types_profile.Profile(runner: runner, ..) = profile
  let types_runner.Runner(tool_config: tool_config, ..) = runner

  case tool_config {
    types_runner.ToolConfigScript(script) -> {
      let script_path = fixture_script_path(script)
      let next_tool_config = types_runner.ToolConfigScript(script: script_path)
      let next_runner =
        types_runner.Runner(
          ..runner,
          tool_config: next_tool_config,
          exec_path: option.Some(script_path),
        )
      types_profile.Profile(..profile, runner: next_runner)
    }

    _ -> profile
  }
}

fn fixture_script_path(script: String) -> String {
  case filepath.is_absolute(script) {
    True -> script
    False ->
      case string.contains(script, "/") {
        True -> join_with_cwd(script)
        False -> filepath.join(fixture_root(), filepath.join("runners", script))
      }
  }
}

fn fixture_root() -> String {
  case simplifile.current_directory() {
    Ok(cwd) -> filepath.join(cwd, "test/fixtures/source_local")
    Error(_) -> "test/fixtures/source_local"
  }
}

fn join_with_cwd(path: String) -> String {
  case simplifile.current_directory() {
    Ok(cwd) -> filepath.join(cwd, path)
    Error(_) -> path
  }
}
