import filepath
import gleeunit
import gleeunit/should
import sad/types
import sad/workspace
import simplifile

pub fn main() {
  gleeunit.main()
}

pub fn rejects_absolute_path_test() {
  workspace.workspace_path_validate("/etc/passwd")
  |> should.equal(
    Error(workspace.AbsolutePathNotAllowed("/etc/passwd")),
  )
}

pub fn rejects_dotdot_segments_test() {
  workspace.workspace_path_validate("../x")
  |> should.equal(
    Error(workspace.PathTraversalDetected("../x")),
  )

  workspace.workspace_path_validate("a/../../b")
  |> should.equal(
    Error(workspace.PathTraversalDetected("a/../../b")),
  )
}

pub fn rejects_empty_path_test() {
  workspace.workspace_path_validate("")
  |> should.equal(Error(workspace.EmptyPath))

  workspace.workspace_path_validate(".")
  |> should.equal(Error(workspace.EmptyPath))

  workspace.workspace_path_validate("////")
  |> should.equal(Error(workspace.EmptyPath))
}

pub fn normalizes_dot_segments_test() {
  let assert Ok(path) = workspace.workspace_path_validate("./a/./b")
  workspace.workspace_path_to_string(path)
  |> should.equal("a/b")
}

pub fn normalizes_double_slash_test() {
  let assert Ok(path) = workspace.workspace_path_validate("a//b")
  workspace.workspace_path_to_string(path)
  |> should.equal("a/b")
}

pub fn rejects_null_byte_test() {
  let raw = "a\u{0}b"
  workspace.workspace_path_validate(raw)
  |> should.equal(Error(workspace.InvalidCharacter(raw, "\\0")))
}

pub fn workspace_dir_name_format_test() {
  types.instance_id("abc123")
  |> workspace.workspace_dir_name
  |> should.equal("workspace-abc123")
}

pub fn symlink_escape_is_rejected_test() {
  let base_dir = "./build/test-workspaces/symlink-test"
  let outside_file = "./build/test-workspaces/outside.txt"
  let link_path = filepath.join(base_dir, "escape.txt")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ = simplifile.delete(file_or_dir_at: outside_file)

  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) =
    simplifile.write(to: outside_file, contents: "secret")
  let assert Ok(_) =
    simplifile.create_symlink(to: outside_file, from: link_path)

  let assert Ok(path) = workspace.workspace_path_validate("escape.txt")

  workspace.read_artifact_symlink_safe(base_dir, path)
  |> should.equal(
    Error(workspace.PathOutsideWorkspace("escape.txt", base_dir)),
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ = simplifile.delete(file_or_dir_at: outside_file)
}
