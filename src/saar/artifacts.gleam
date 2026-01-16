//// Artifact collection and glob filtering.
////
//// Mission: take runner-provided artifact references and produce a list of
//// validated artifacts (paths + metadata) that can later be registered.
////
//// Responsibilities:
//// - Validate artifact paths against workspace rules.
//// - Apply glob filtering (`*`, `?`, `**`) over path segments.
////
//// Non-responsibilities:
//// - Generating artifact ids.
//// - Reading artifact contents or uploading files.
//// - Resolving URLs.
////
//// Relationships:
//// - Consumes `types_runner.ArtifactRef` and `types_runner.ArtifactConfig`.
//// - Produces `CollectedArtifact` with a `workspace.WorkspacePath`.
//// - Delegates path safety to `saar/workspace`.

import gleam/list
import gleam/result
import gleam/string
import saar/types/runner as types_runner
import saar/workspace

/// Errors that can occur while collecting artifacts.
///
/// `InvalidPath` indicates a workspace path validation failure.
pub type ArtifactError {
  InvalidPath(String)
}

/// A runner artifact that passed validation and glob filtering.
pub type CollectedArtifact {
  CollectedArtifact(name: String, path: workspace.WorkspacePath, mime: String)
}

/// Collects validated artifacts from runner references.
///
/// The function validates each artifact `path` using `saar/workspace` and then
/// filters it using `config.include` and `config.exclude` globs.
///
/// - If `config.include` is empty, the result is `Ok([])`.
/// - A path is included when it matches any `include` pattern and matches no
///   `exclude` pattern.
pub fn collect(
  artifacts: List(types_runner.ArtifactRef),
  config: types_runner.ArtifactConfig,
) -> Result(List(CollectedArtifact), ArtifactError) {
  case config.include {
    [] -> Ok([])
    _ ->
      artifacts
      |> list.fold(Ok([]), fn(acc, artifact) {
        use collected <- result.try(acc)
        use validated <- result.try(validate_path(artifact.path))

        let normalized = workspace.workspace_path_to_string(validated)

        case matches_globs(normalized, config.include, config.exclude) {
          True ->
            Ok([
              CollectedArtifact(
                name: artifact.name,
                path: validated,
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

fn validate_path(path: String) -> Result(workspace.WorkspacePath, ArtifactError) {
  workspace.workspace_path_validate(path)
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
  case patterns, paths {
    [], _ -> paths == []
    ["**", ..rest], _ -> match_double_star(rest, paths)
    [pattern, ..rest], [segment, ..tail] ->
      match_segment(pattern, segment) && match_segments(rest, tail)
    [_pattern, ..], [] -> False
  }
}

fn match_double_star(rest: List(String), paths: List(String)) -> Bool {
  case rest {
    [] -> True
    _ -> match_double_star_step(rest, paths)
  }
}

fn match_double_star_step(rest: List(String), paths: List(String)) -> Bool {
  case match_segments(rest, paths), paths {
    True, _ -> True
    False, [] -> False
    False, [_head, ..tail] -> match_double_star(rest, tail)
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
