import filepath
import gleeunit
import gleam/list
import gleam/result
import gleam/string
import simplifile

type Violation {
  Violation(file: String, pattern: String)
}

pub fn main() {
  gleeunit.main()
}

pub fn doc_lint_forbidden_patterns() {
  assert_no_patterns([
    "process.try_call",
    "process.select_after",
    "process.select(selector)",
  ])
}

pub fn doc_lint_actor_stop_usage() {
  assert_no_patterns([
    "actor.stop(process.Normal)",
  ])
}

fn assert_no_patterns(patterns: List(String)) {
  let files = doc_files()
  let violations =
    case collect_violations(files, patterns) {
      Ok(found) -> found
      Error(err) ->
        panic as ("DOC_LINT_FAIL file=<read_error> pattern=" <> simplifile.describe_error(err))
    }

  case violations {
    [] -> Nil
    [Violation(file, pattern), ..] ->
      panic as ("DOC_LINT_FAIL file=" <> file <> " pattern=" <> pattern)
  }
}

fn doc_files() -> List(String) {
  let arch_docs =
    case collect_files("docs/arquitectura") {
      Ok(paths) ->
        paths
        |> list.filter(fn(path) { string.ends_with(path, ".md") })
      Error(err) ->
        panic as (
          "DOC_LINT_FAIL file=docs/arquitectura pattern="
          <> simplifile.describe_error(err)
        )
    }

  let snippet_files =
    case collect_files("docs/arquitectura/examples/snippets") {
      Ok(paths) -> paths
      Error(err) ->
        panic as (
          "DOC_LINT_FAIL file=docs/arquitectura/examples/snippets pattern="
          <> simplifile.describe_error(err)
        )
    }

  list.append(arch_docs, snippet_files)
}

fn collect_files(root: String) -> Result(List(String), simplifile.FileError) {
  use entries <- result.try(simplifile.read_directory(root))

  entries
  |> list.map(fn(name) { filepath.join(root, name) })
  |> list.fold(Ok([]), fn(acc, path) {
    use files <- result.try(acc)
    use is_dir <- result.try(simplifile.is_directory(path))

    case is_dir {
      True -> {
        use nested <- result.try(collect_files(path))
        Ok(list.append(files, nested))
      }
      False -> Ok(list.append(files, [path]))
    }
  })
}

fn collect_violations(
  files: List(String),
  patterns: List(String),
) -> Result(List(Violation), simplifile.FileError) {
  files
  |> list.fold(Ok([]), fn(acc, file) {
    use found <- result.try(acc)
    use content <- result.try(simplifile.read(file))

    let matches =
      patterns
      |> list.filter(fn(pattern) { string.contains(content, pattern) })
      |> list.map(fn(pattern) { Violation(file, pattern) })

    Ok(list.append(found, matches))
  })
}
