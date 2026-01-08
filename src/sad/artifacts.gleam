import gleam/list
import gleam/result
import gleam/string
import sad/types/output as types_output
import sad/types/runner as types_runner
import sad/workspace
import youid/uuid

pub type ArtifactError {
  InvalidPath(String)
}

pub fn collect(
  artifacts: List(types_runner.ArtifactRef),
  config: types_runner.ArtifactConfig,
) -> Result(List(types_output.PublicArtifact), ArtifactError) {
  case config.include {
    [] -> Ok([])
    _ ->
      artifacts
      |> list.fold(Ok([]), fn(acc, artifact) {
        use collected <- result.try(acc)
        use normalized <- result.try(validate_path(artifact.path))

        case matches_globs(normalized, config.include, config.exclude) {
          True ->
            Ok([
              types_output.PublicArtifact(
                name: artifact.name,
                url: "/artifacts/" <> uuid.v7_string(),
                mime: artifact.mime,
              ),
              ..collected
            ])
          False -> Ok(collected)
        }
      })
      |> result.map(fn(items) { list.reverse(items) })
  }
}

fn validate_path(path: String) -> Result(String, ArtifactError) {
  workspace.workspace_path_validate(path)
  |> result.map(fn(valid) { workspace.workspace_path_to_string(valid) })
  |> result.map_error(fn(err) {
    InvalidPath(workspace.path_error_to_string(err))
  })
}

fn matches_globs(
  path: String,
  include: List(String),
  exclude: List(String),
) -> Bool {
  let included = include |> list.any(fn(pattern) { glob_match(pattern, path) })
  let excluded = exclude |> list.any(fn(pattern) { glob_match(pattern, path) })
  included && !excluded
}

fn glob_match(pattern: String, path: String) -> Bool {
  let pattern_segments = string.split(pattern, "/")
  let path_segments = string.split(path, "/")
  match_segments(pattern_segments, path_segments)
}

fn match_segments(patterns: List(String), paths: List(String)) -> Bool {
  case patterns {
    [] -> paths == []
    ["**", ..rest] ->
      case rest {
        [] -> True
        _ ->
          match_segments(rest, paths)
          || case paths {
            [] -> False
            [_, ..tail] -> match_segments(patterns, tail)
          }
      }
    [pattern, ..rest] ->
      case paths {
        [] -> False
        [segment, ..tail] ->
          match_segment(pattern, segment) && match_segments(rest, tail)
      }
  }
}

fn match_segment(pattern: String, segment: String) -> Bool {
  match_chars(string.to_graphemes(pattern), string.to_graphemes(segment))
}

fn match_chars(pattern: List(String), text: List(String)) -> Bool {
  case pattern {
    [] -> text == []
    ["*", ..rest] ->
      case text {
        [] -> match_chars(rest, [])
        [_, ..tail] -> match_chars(rest, text) || match_chars(pattern, tail)
      }
    ["?", ..rest] ->
      case text {
        [] -> False
        [_, ..tail] -> match_chars(rest, tail)
      }
    [char, ..rest] ->
      case text {
        [] -> False
        [head, ..tail] -> char == head && match_chars(rest, tail)
      }
  }
}
