import gleam/list
import gleam/string
import gleeunit/should
import qcheck
import saar/workspace

const test_count: Int = 200

pub fn prop_valid_path_has_no_dotdot_segments_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  qcheck.run(config, qcheck.string(), fn(raw) {
    case workspace.workspace_path_validate(raw) {
      Ok(path) -> {
        let segments =
          path
          |> workspace.workspace_path_to_string
          |> string.split("/")

        segments
        |> list.any(fn(segment) { segment == ".." })
        |> should.equal(False)
      }

      Error(_) -> Nil
    }
  })
}

pub fn prop_valid_path_has_no_null_char_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  qcheck.run(config, qcheck.string(), fn(raw) {
    case workspace.workspace_path_validate(raw) {
      Ok(path) -> {
        path
        |> workspace.workspace_path_to_string
        |> string.contains("\u{0}")
        |> should.equal(False)
      }

      Error(_) -> Nil
    }
  })
}

pub fn prop_validate_is_idempotent_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  qcheck.run(config, qcheck.string(), fn(raw) {
    case workspace.workspace_path_validate(raw) {
      Ok(path1) -> {
        let normalized = workspace.workspace_path_to_string(path1)
        let assert Ok(path2) = workspace.workspace_path_validate(normalized)
        workspace.workspace_path_to_string(path2)
        |> should.equal(normalized)
      }

      Error(_) -> Nil
    }
  })
}

pub fn prop_to_absolute_starts_with_root_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  qcheck.run(config, qcheck.string(), fn(raw) {
    case workspace.workspace_path_validate(raw) {
      Ok(path) -> {
        let root = "/tmp/saar-workspace-prop"

        workspace.workspace_path_to_absolute(root, path)
        |> string.starts_with(root)
        |> should.equal(True)
      }

      Error(_) -> Nil
    }
  })
}
