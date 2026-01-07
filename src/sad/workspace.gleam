import filepath
import gleam/list
import gleam/result
import gleam/string
import sad/types
import simplifile

/// Path seguro dentro del workspace.
pub opaque type WorkspacePath {
  WorkspacePath(String)
}

/// Errores de validación de paths.
pub type PathError {
  PathTraversalDetected(raw: String)
  PathOutsideWorkspace(raw: String, root: String)
  EmptyPath
  InvalidCharacter(raw: String, char: String)
  AbsolutePathNotAllowed(raw: String)
}

/// Valida y construye un WorkspacePath seguro.
pub fn workspace_path_validate(
  raw_path: String,
) -> Result(WorkspacePath, PathError) {
  case raw_path {
    "" -> Error(EmptyPath)
    _ -> validate_non_empty(raw_path)
  }
}

fn validate_non_empty(raw: String) -> Result(WorkspacePath, PathError) {
  case string.starts_with(raw, "/") {
    True -> Error(AbsolutePathNotAllowed(raw))
    False -> validate_relative(raw)
  }
}

fn validate_relative(raw: String) -> Result(WorkspacePath, PathError) {
  case string.contains(raw, "\u{0}") {
    True -> Error(InvalidCharacter(raw, "\\0"))
    False -> validate_no_null(raw)
  }
}

fn validate_no_null(raw: String) -> Result(WorkspacePath, PathError) {
  use normalized <- result.try(normalize_path(raw))
  case normalized {
    "" -> Error(EmptyPath)
    _ -> Ok(WorkspacePath(normalized))
  }
}

/// Normaliza un path por segmentos:
/// - colapsa múltiples `/`
/// - elimina `.` y segmentos vacíos
/// - rechaza `..` como segmento
fn normalize_path(raw: String) -> Result(String, PathError) {
  raw
  |> string.split("/")
  |> list.fold(Ok([]), fn(acc, segment) {
    use segments <- result.try(acc)
    case segment {
      "" -> Ok(segments)
      "." -> Ok(segments)
      ".." -> Error(PathTraversalDetected(raw))
      other -> Ok([other, ..segments])
    }
  })
  |> result.map(fn(segments) { segments |> list.reverse |> string.join("/") })
}

pub fn workspace_path_to_string(path: WorkspacePath) -> String {
  let WorkspacePath(value) = path
  value
}

pub fn workspace_path_to_absolute(root: String, path: WorkspacePath) -> String {
  filepath.join(root, workspace_path_to_string(path))
}

pub fn workspace_path_join(
  root: String,
  raw: String,
) -> Result(String, PathError) {
  use path <- result.try(workspace_path_validate(raw))
  Ok(workspace_path_to_absolute(root, path))
}

pub fn read_artifact_symlink_safe(
  root: String,
  path: WorkspacePath,
) -> Result(String, PathError) {
  use _ <- result.try(assert_no_symlink(root, path))
  let full_path = workspace_path_to_absolute(root, path)

  case simplifile.read(full_path) {
    Ok(contents) -> Ok(contents)
    Error(_) ->
      Error(PathOutsideWorkspace(workspace_path_to_string(path), root))
  }
}

fn assert_no_symlink(
  root: String,
  path: WorkspacePath,
) -> Result(Nil, PathError) {
  let raw = workspace_path_to_string(path)

  raw
  |> string.split("/")
  |> list.fold(Ok(root), fn(acc, segment) {
    use current <- result.try(acc)
    let next = filepath.join(current, segment)

    case simplifile.link_info(next) {
      Ok(info) ->
        case simplifile.file_info_type(info) {
          simplifile.Symlink -> Error(PathOutsideWorkspace(raw, root))
          _ -> Ok(next)
        }
      Error(_) -> Ok(next)
    }
  })
  |> result.map(fn(_) { Nil })
}

pub fn workspace_dir_name(instance_id: types.InstanceId) -> String {
  "workspace-" <> types.instance_id_to_string(instance_id)
}

pub fn workspace_for_instance(
  base_dir: String,
  instance_id: types.InstanceId,
) -> String {
  filepath.join(base_dir, workspace_dir_name(instance_id))
}

pub fn path_error_to_string(err: PathError) -> String {
  case err {
    PathTraversalDetected(raw) -> "Path traversal detected: '" <> raw <> "'"
    PathOutsideWorkspace(raw, root) ->
      "Path '" <> raw <> "' resolves outside workspace '" <> root <> "'"
    EmptyPath -> "Path cannot be empty"
    InvalidCharacter(raw, char) ->
      "Path '" <> raw <> "' contains invalid character: " <> char
    AbsolutePathNotAllowed(raw) -> "Absolute path not allowed: '" <> raw <> "'"
  }
}
