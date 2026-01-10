//// Unit tests for `sad/artifacts.collect`.
////
//// Mission: validate artifact filtering behavior (include/exclude globs), path
//// validation boundaries, and output shape.
////
//// Responsibilities:
//// - Assert expected `Result` behavior for valid/invalid paths.
//// - Assert glob semantics (`*`, `?`, `**`) at a black-box level.
////
//// Non-responsibilities:
//// - Verifying UUID/id generation details.

import gleam/option
import gleeunit
import gleeunit/should
import sad/artifacts
import sad/types/output as types_output
import sad/types/runner as types_runner

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
    Ok([types_output.PublicArtifact(id: _, name: name, url: url, mime: mime)]) -> {
      name |> should.equal("log")
      url |> should.equal(option.None)
      mime |> should.equal("text/plain")
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
      types_output.PublicArtifact(id: _, name: n1, url: _, mime: _),
      types_output.PublicArtifact(id: _, name: n2, url: _, mime: _),
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
