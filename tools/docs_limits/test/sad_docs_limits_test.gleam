import filepath
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleeunit
import sad/docs/limits_table
import simplifile

type Violation {
  Violation(file: String, pattern: String)
}

pub fn main() {
  gleeunit.main()
}

pub fn limits_md_matches_toml_test() {
  let toml_path = "../../docs/plan/limits.toml"
  let md_path = "../../docs/plan/limits.md"

  let toml_content = read_doc(toml_path)

  let generated_md = case limits_table.render_markdown_from_toml(toml_content) {
    Ok(found) -> found
    Error(err) ->
      panic as { "DOC_LINT_FAIL file=" <> toml_path <> " pattern=" <> err }
  }

  let committed_md = read_doc(md_path)

  case committed_md == generated_md {
    True -> Nil
    False ->
      panic as {
        "DOC_LINT_FAIL file=" <> md_path <> " pattern=generated_mismatch"
      }
  }
}

pub fn docs_forbidden_patterns_test() {
  assert_no_patterns([
    "process.try_call",
    "process.select_after",
    "process.select(selector)",
  ])
}

pub fn docs_actor_stop_usage_test() {
  assert_no_patterns(["actor.stop(process.Normal)"])
}

pub fn docs_config_defaults_match_limits_toml_test() {
  let config_md = "../../docs/arquitectura/config.md"
  let limits_toml = "../../docs/plan/limits.toml"

  let config_defaults = read_config_table_defaults(config_md, "| Clave |")
  let toml_defaults = read_limits_toml_defaults(limits_toml)

  assert_defaults_match(config_md, config_defaults, toml_defaults)
}

fn assert_no_patterns(patterns: List(String)) {
  let files = doc_files()

  let violations = case collect_violations(files, patterns) {
    Ok(found) -> found
    Error(err) ->
      panic as {
        "DOC_LINT_FAIL file=<read_error> pattern="
        <> simplifile.describe_error(err)
      }
  }

  case violations {
    [] -> Nil
    [Violation(file, pattern), ..] ->
      panic as { "DOC_LINT_FAIL file=" <> file <> " pattern=" <> pattern }
  }
}

fn doc_files() -> List(String) {
  let arch_docs = case collect_files("../../docs/arquitectura") {
    Ok(paths) ->
      paths |> list.filter(fn(path) { string.ends_with(path, ".md") })
    Error(err) ->
      panic as {
        "DOC_LINT_FAIL file=docs/arquitectura pattern="
        <> simplifile.describe_error(err)
      }
  }

  let snippet_files = case
    collect_files("../../docs/arquitectura/examples/snippets")
  {
    Ok(paths) -> paths
    Error(err) ->
      panic as {
        "DOC_LINT_FAIL file=docs/arquitectura/examples/snippets pattern="
        <> simplifile.describe_error(err)
      }
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
    use content0 <- result.try(simplifile.read(file))

    let content = case file {
      "../../docs/arquitectura/tests.md" -> strip_doc_lint_self_refs(content0)
      _ -> content0
    }

    let matches =
      patterns
      |> list.filter(fn(pattern) { string.contains(content, pattern) })
      |> list.map(fn(pattern) { Violation(file, pattern) })

    Ok(list.append(found, matches))
  })
}

fn read_config_table_defaults(
  path: String,
  header_prefix: String,
) -> dict.Dict(String, String) {
  let content = read_doc(path)
  let rows = extract_table_rows(path, content, header_prefix)

  rows
  |> list.fold(dict.new(), fn(acc, line) {
    let cells = table_cells(line)
    case cells {
      [key_cell, _desc, default_cell, ..] ->
        insert_config_defaults(acc, path, key_cell, default_cell)
      _ ->
        panic as {
          "DOC_LINT_FAIL file=" <> path <> " pattern=invalid_table_row"
        }
    }
  })
}

fn insert_config_defaults(
  acc: dict.Dict(String, String),
  path: String,
  key_cell: String,
  default_cell: String,
) -> dict.Dict(String, String) {
  // Allow wildcard rows like `log_stream.*` to be described in docs.
  case string.contains(key_cell, ".*") {
    True -> acc
    False -> {
      let keys = split_slash_parts(key_cell)
      let defaults = split_slash_parts(default_cell)

      case list.length(keys) == list.length(defaults) {
        True -> insert_pairs(acc, keys, defaults)
        False ->
          panic as {
            "DOC_LINT_FAIL file=" <> path <> " pattern=invalid_default_parts"
          }
      }
    }
  }
}

fn split_slash_parts(cell: String) -> List(String) {
  cell
  |> string.replace("`", "")
  |> string.split(" / ")
  |> list.map(fn(part) { string.trim(part) })
  |> list.filter(fn(part) { part != "" })
}

fn insert_pairs(
  acc: dict.Dict(String, String),
  keys: List(String),
  defaults: List(String),
) -> dict.Dict(String, String) {
  case keys, defaults {
    [], [] -> acc
    [key, ..rest_keys], [value, ..rest_values] ->
      insert_pairs(
        dict.insert(acc, key, normalize_doc_default(value)),
        rest_keys,
        rest_values,
      )
    _, _ -> acc
  }
}

fn read_limits_toml_defaults(path: String) -> dict.Dict(String, String) {
  let content = read_doc(path)

  content
  |> string.split("\n")
  |> list.fold(#(option.None, dict.new()), fn(acc, line) {
    let #(current_key, defaults) = acc
    let trimmed = string.trim(line)

    case trimmed == "" || string.starts_with(trimmed, "#") {
      True -> #(current_key, defaults)
      False ->
        case string.starts_with(trimmed, "key") {
          True -> #(option.Some(parse_toml_value(trimmed)), defaults)
          False ->
            case string.starts_with(trimmed, "default") {
              True ->
                case current_key {
                  option.Some(key) -> #(
                    option.None,
                    dict.insert(
                      defaults,
                      key,
                      normalize_doc_default(parse_toml_value(trimmed)),
                    ),
                  )
                  option.None -> #(current_key, defaults)
                }
              False -> #(current_key, defaults)
            }
        }
    }
  })
  |> fn(pair) { pair.1 }
}

fn parse_toml_value(line: String) -> String {
  let parts = case string.split_once(line, on: "=") {
    Ok(found) -> found
    Error(_) -> #(line, "")
  }

  let raw = string.trim(parts.1)

  case strip_wrapping_quote(raw, "\"") {
    option.Some(value) -> value
    option.None ->
      case strip_wrapping_quote(raw, "'") {
        option.Some(value) -> value
        option.None -> raw
      }
  }
}

fn strip_wrapping_quote(raw: String, quote: String) -> option.Option(String) {
  let chars = string.to_graphemes(raw)

  case chars {
    [] -> option.None
    [_] -> option.None
    [first, ..] ->
      case first == quote {
        False -> option.None
        True ->
          case list.reverse(chars) {
            [last, ..] ->
              case last == quote {
                False -> option.None
                True ->
                  option.Some(
                    chars
                    |> strip_first_and_last
                    |> string.join(""),
                  )
              }
            _ -> option.None
          }
      }
  }
}

fn strip_first_and_last(chars: List(String)) -> List(String) {
  case chars {
    [] -> []
    [_] -> []
    [_, ..rest] ->
      case list.reverse(rest) {
        [] -> []
        [_, ..middle_rev] -> list.reverse(middle_rev)
      }
  }
}

fn strip_doc_lint_self_refs(content: String) -> String {
  content
  |> string.split("\n")
  |> list.filter(fn(line) { !is_doc_lint_self_ref(line) })
  |> string.join("\n")
}

fn is_doc_lint_self_ref(line: String) -> Bool {
  string.contains(line, "docs_do_not_reference_nonexistent_apis")
  || string.contains(line, "docs_actor_stop_usage_is_valid")
}

fn normalize_doc_default(value: String) -> String {
  let trimmed = string.trim(value)

  let trimmed = case trimmed {
    "\"\"" -> ""
    other -> other
  }

  case
    string.contains(trimmed, "requerido")
    || string.contains(trimmed, "required")
  {
    True -> ""
    False -> {
      let cleaned =
        trimmed
        |> string.replace("_", "")
        |> string.replace("(", "")
        |> string.replace(")", "")
        |> string.replace("MB", "")
        |> string.replace("mb", "")
        |> string.trim

      case string.split(cleaned, " ") {
        [first, ..] -> first
        [] -> ""
      }
    }
  }
}

fn assert_defaults_match(
  path: String,
  actual: dict.Dict(String, String),
  expected: dict.Dict(String, String),
) {
  actual
  |> dict.to_list
  |> list.each(fn(pair) {
    let #(key, found) = pair

    case dict.get(expected, key) {
      Ok(expected_value) ->
        case found == expected_value {
          True -> Nil
          False ->
            panic as {
              "DOC_LINT_FAIL file="
              <> path
              <> " pattern=mismatch key="
              <> key
              <> " expected="
              <> expected_value
              <> " got="
              <> found
            }
        }

      Error(_) ->
        panic as {
          "DOC_LINT_FAIL file=" <> path <> " pattern=unknown_key key=" <> key
        }
    }
  })
}

fn extract_table_rows(
  _path: String,
  content: String,
  header_prefix: String,
) -> List(String) {
  let lines = string.split(content, "\n")

  let start =
    find_line_index(lines, fn(line) {
      string.starts_with(string.trim(line), header_prefix)
    })

  let assert option.Some(index) = start

  let after = list.drop(lines, index + 2)

  after
  |> list.take_while(fn(line) { string.starts_with(string.trim(line), "|") })
  |> list.filter(fn(line) {
    case string.trim(line) {
      "|---" <> _ -> False
      _ -> True
    }
  })
  |> list.map(fn(line) { string.trim(line) })
}

fn find_line_index(
  lines: List(String),
  predicate: fn(String) -> Bool,
) -> option.Option(Int) {
  find_line_index_loop(lines, predicate, 0)
}

fn find_line_index_loop(
  lines: List(String),
  predicate: fn(String) -> Bool,
  index: Int,
) -> option.Option(Int) {
  case lines {
    [] -> option.None
    [line, ..rest] ->
      case predicate(line) {
        True -> option.Some(index)
        False -> find_line_index_loop(rest, predicate, index + 1)
      }
  }
}

fn table_cells(line: String) -> List(String) {
  line
  |> string.trim
  |> string.drop_start(up_to: 1)
  |> string.drop_end(up_to: 1)
  |> string.split("|")
  |> list.map(fn(cell) { string.trim(cell) })
}

fn read_doc(path: String) -> String {
  case simplifile.read(path) {
    Ok(content) -> content
    Error(err) ->
      panic as {
        "DOC_LINT_FAIL file="
        <> path
        <> " pattern="
        <> simplifile.describe_error(err)
      }
  }
}
