//// Artifact collection and glob filtering.
////
//// Mission: take runner-provided artifact references and produce public-facing
//// artifact metadata after validating paths and applying include/exclude globs.
////
//// Responsibilities:
//// - Validate artifact paths against workspace rules.
//// - Apply glob filtering (`*`, `?`, `**`) over path segments.
//// - Produce `types_output.PublicArtifact` values with generated IDs.
////
//// Non-responsibilities:
//// - Reading artifact contents or uploading files.
//// - Resolving URLs; `url` stays `None`.
////
//// Relationships:
//// - Consumes `types_runner.ArtifactRef` and `types_runner.ArtifactConfig`.
//// - Produces `types_output.PublicArtifact`.
//// - Delegates path safety to `sad/workspace`.

import gleam/list
import gleam/option
import gleam/result
import gleam/string
import sad/types/core
import sad/types/output as types_output
import sad/types/runner as types_runner
import sad/workspace
import youid/uuid

/// Errors that can occur while collecting public artifacts.
///
/// `InvalidPath` indicates a workspace path validation failure.
pub type ArtifactError {
  InvalidPath(String)
}

/// Collects public artifacts from runner references.
///
/// The function validates each artifact `path` using `sad/workspace` and then
/// filters it using `config.include` and `config.exclude` globs.
///
/// - If `config.include` is empty, the result is `Ok([])`.
/// - A path is included when it matches any `include` pattern and matches no
///   `exclude` pattern.
///
/// Example:
/// ```gleam
/// collect(artifacts, config)
/// ```
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
          True -> {
            let id = core.artifact_id(uuid.v7_string())
            Ok([
              types_output.PublicArtifact(
                id: id,
                name: artifact.name,
                url: option.None,
                mime: artifact.mime,
              ),
              ..collected
            ])
          }
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
