////
//// Mission: validate artifact filtering behavior (include/exclude globs) and
//// workspace path validation boundaries.
////
//// Responsibilities:
//// - Assert expected `Result` behavior for valid/invalid paths.
//// - Assert glob semantics (`*`, `?`, `**`) at a black-box level.

import gleeunit
import gleeunit/should
import sad/artifacts
import sad/types/runner as types_runner
import sad/workspace

/// Test entrypoint for gleeunit.
pub fn main() {
  gleeunit.main()
}

/// Returns `Ok([])` when `include` is empty (even with invalid paths).
pub fn collect_include_empty_returns_empty_test() {
  let items = [
    types_runner.ArtifactRef(name: "a", path: "/etc/passwd", mime: "text/plain"),
  ]

  let config = types_runner.ArtifactConfig(include: [], exclude: [])

  artifacts.collect(items, config)
  |> should.equal(Ok([]))
}

/// Includes matching artifacts and uses normalized workspace paths.
pub fn collect_includes_and_normalizes_paths_test() {
  let items = [
    types_runner.ArtifactRef(
      name: "log",
      path: "./logs/./a.log",
      mime: "text/plain",
    ),
    types_runner.ArtifactRef(
      name: "txt",
      path: "logs/b.txt",
      mime: "text/plain",
    ),
  ]

  let config = types_runner.ArtifactConfig(include: ["**/*.log"], exclude: [])

  case artifacts.collect(items, config) {
    Ok([artifacts.CollectedArtifact(name: name, path: path, mime: mime)]) -> {
      name |> should.equal("log")
      mime |> should.equal("text/plain")
      workspace.workspace_path_to_string(path) |> should.equal("logs/a.log")
    }
    _ -> should.fail()
  }
}

/// Applies `exclude` patterns and preserves input order.
pub fn collect_exclude_and_order_test() {
  let items = [
    types_runner.ArtifactRef(
      name: "one",
      path: "logs/1.log",
      mime: "text/plain",
    ),
    types_runner.ArtifactRef(
      name: "two",
      path: "secret/2.log",
      mime: "text/plain",
    ),
    types_runner.ArtifactRef(
      name: "three",
      path: "logs/3.log",
      mime: "text/plain",
    ),
  ]

  let config =
    types_runner.ArtifactConfig(include: ["**/*.log"], exclude: ["secret/**"])

  case artifacts.collect(items, config) {
    Ok([
      artifacts.CollectedArtifact(name: n1, ..),
      artifacts.CollectedArtifact(name: n2, ..),
    ]) -> {
      n1 |> should.equal("one")
      n2 |> should.equal("three")
    }
    _ -> should.fail()
  }
}

/// Returns `Error(InvalidPath(_))` when validation fails and `include` is set.
pub fn collect_invalid_path_errors_test() {
  let items = [
    types_runner.ArtifactRef(name: "bad", path: "../x", mime: "text/plain"),
  ]

  let config = types_runner.ArtifactConfig(include: ["**"], exclude: [])

  case artifacts.collect(items, config) {
    Error(artifacts.InvalidPath(_)) -> Nil
    _ -> should.fail()
  }
}
