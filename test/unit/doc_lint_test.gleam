import filepath
import gleam/dict
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleeunit
import sad/docs/limits_table
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
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

pub fn doc_lint_forbidden_patterns_test() {
  doc_lint_forbidden_patterns()
}

pub fn doc_lint_actor_stop_usage() {
  assert_no_patterns([
    "actor.stop(process.Normal)",
  ])
}

pub fn doc_lint_actor_stop_usage_test() {
  doc_lint_actor_stop_usage()
}

pub fn doc_lint_limits_defaults_match_config() {
  let expected = expected_defaults_from_config()
  let toml_defaults = read_limits_toml_defaults("docs/plan/limits.toml")
  assert_defaults_match("docs/plan/limits.toml", toml_defaults, expected)
}

pub fn doc_lint_limits_defaults_match_config_test() {
  doc_lint_limits_defaults_match_config()
}

pub fn doc_lint_limits_md_matches_toml() {
  let toml_path = "docs/plan/limits.toml"
  let md_path = "docs/plan/limits.md"

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

  let toml_defaults = read_limits_toml_defaults(toml_path)
  let md_defaults = read_limits_table_defaults(md_path, "| Key |")
  assert_defaults_match(md_path, md_defaults, toml_defaults)
}

pub fn doc_lint_limits_md_matches_toml_test() {
  doc_lint_limits_md_matches_toml()
}

pub fn doc_lint_config_defaults_match_config() {
  let expected = expected_defaults_from_config()
  let config_defaults =
    read_config_table_defaults("docs/arquitectura/config.md", "| Clave |")
  assert_config_defaults_match(
    "docs/arquitectura/config.md",
    config_defaults,
    expected,
  )
}

pub fn doc_lint_config_defaults_match_config_test() {
  doc_lint_config_defaults_match_config()
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
  let arch_docs = case collect_files("docs/arquitectura") {
    Ok(paths) ->
      paths
      |> list.filter(fn(path) { string.ends_with(path, ".md") })
    Error(err) ->
      panic as {
        "DOC_LINT_FAIL file=docs/arquitectura pattern="
        <> simplifile.describe_error(err)
      }
  }

  let snippet_files = case
    collect_files("docs/arquitectura/examples/snippets")
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
    use content <- result.try(simplifile.read(file))

    let content = case file {
      "docs/arquitectura/tests.md" -> strip_doc_lint_self_refs(content)
      _ -> content
    }

    let matches =
      patterns
      |> list.filter(fn(pattern) { string.contains(content, pattern) })
      |> list.map(fn(pattern) { Violation(file, pattern) })

    Ok(list.append(found, matches))
  })
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

fn expected_defaults_from_config() -> dict.Dict(String, String) {
  let config = types_config.default_sad_config()
  let types_config.SadConfig(
    server_host: server_host,
    server_port: server_port,
    api_key: api_key,
    timeouts: timeouts,
    profiles: profiles,
    runner: runner_cfg,
    storage: storage,
    limits: limits,
    stream: stream_cfg,
    landlock_mode: landlock_mode,
  ) = config

  let types_config.SadTimeouts(
    call_timeout_ms: call_timeout_ms,
    status_timeout_ms: status_timeout_ms,
    registry_timeout_ms: registry_timeout_ms,
    health_check_timeout_ms: health_check_timeout_ms,
    shutdown_timeout_ms: shutdown_timeout_ms,
  ) = timeouts

  let types_config.ProfilesConfig(
    sources: profiles_sources,
    git_cache_dir: profiles_git_cache_dir,
  ) = profiles

  let types_config.RunnerSystemConfig(
    python_bin: runners_python_bin,
    port_range_min: port_range_min,
    port_range_max: port_range_max,
    managed_port_host: managed_port_host,
    ..,
  ) = runner_cfg

  let types_config.StorageConfig(workspaces_directory: workspaces_directory, ..) =
    storage

  let types_config.SadLimits(
    log_buffer_bytes: log_buffer_bytes,
    max_stdout_bytes: max_stdout_bytes,
    max_runner_event_bytes: max_runner_event_bytes,
    max_request_body_bytes: max_request_body_bytes,
    max_http_response_bytes: max_http_response_bytes,
    max_file_fetch_bytes: max_file_fetch_bytes,
  ) = limits

  let types_config.StreamConfig(
    sse_keep_alive_interval_ms: sse_keep_alive_interval_ms,
    log_stream: log_stream,
    interaction_stream: interaction_stream,
  ) = stream_cfg

  let types_config.LogStreamConfig(log_batch_byte_size, log_flush_interval_ms) =
    log_stream
  let types_config.InteractionStreamConfig(
    interaction_batch_byte_size,
    interaction_flush_interval_ms,
    interaction_push_timeout_ms,
  ) = interaction_stream

  let api_key_default = case types_core.secret_to_env_value(api_key) {
    "" -> "\"\""
    other -> other
  }

  dict.new()
  |> dict.insert("server.host", server_host)
  |> dict.insert("server.port", int.to_string(server_port))
  |> dict.insert("auth.api_key", api_key_default)
  |> dict.insert("profiles.sources", profile_sources_default(profiles_sources))
  |> dict.insert("profiles.git_cache_dir", profiles_git_cache_dir)
  |> dict.insert("runners.python_bin", runners_python_bin)
  |> dict.insert("workspaces.directory", workspaces_directory)
  |> dict.insert("limits.call_timeout_ms", int.to_string(call_timeout_ms))
  |> dict.insert("limits.status_timeout_ms", int.to_string(status_timeout_ms))
  |> dict.insert(
    "limits.registry_timeout_ms",
    int.to_string(registry_timeout_ms),
  )
  |> dict.insert(
    "limits.health_check_timeout_ms",
    int.to_string(health_check_timeout_ms),
  )
  |> dict.insert(
    "limits.shutdown_timeout_ms",
    int.to_string(shutdown_timeout_ms),
  )
  |> dict.insert("limits.log_buffer_bytes", int.to_string(log_buffer_bytes))
  |> dict.insert("limits.max_stdout_bytes", int.to_string(max_stdout_bytes))
  |> dict.insert(
    "limits.max_runner_event_bytes",
    int.to_string(max_runner_event_bytes),
  )
  |> dict.insert(
    "limits.max_request_body_bytes",
    int.to_string(max_request_body_bytes),
  )
  |> dict.insert(
    "limits.max_http_response_bytes",
    int.to_string(max_http_response_bytes),
  )
  |> dict.insert(
    "limits.max_file_fetch_bytes",
    int.to_string(max_file_fetch_bytes),
  )
  |> dict.insert(
    "limits.sse_keep_alive_interval_ms",
    int.to_string(sse_keep_alive_interval_ms),
  )
  |> dict.insert("limits.port_range_min", int.to_string(port_range_min))
  |> dict.insert("limits.port_range_max", int.to_string(port_range_max))
  |> dict.insert("network.managed_port_host", managed_port_host)
  |> dict.insert(
    "log_stream.batch_byte_size",
    int.to_string(log_batch_byte_size),
  )
  |> dict.insert(
    "log_stream.flush_interval_ms",
    int.to_string(log_flush_interval_ms),
  )
  |> dict.insert(
    "interaction_stream.batch_byte_size",
    int.to_string(interaction_batch_byte_size),
  )
  |> dict.insert(
    "interaction_stream.flush_interval_ms",
    int.to_string(interaction_flush_interval_ms),
  )
  |> dict.insert(
    "interaction_stream.push_timeout_ms",
    int.to_string(interaction_push_timeout_ms),
  )
  |> dict.insert(
    "security.landlock_mode",
    types_enums.landlock_mode_to_string(landlock_mode),
  )
}

fn profile_sources_default(sources: List(types_config.ProfileSource)) -> String {
  let rendered =
    sources
    |> list.map(fn(source) { "{" <> profile_source_default(source) <> "}" })
    |> string.join(", ")

  "[" <> rendered <> "]"
}

fn profile_source_default(source: types_config.ProfileSource) -> String {
  case source {
    types_config.ProfileSourceDir(path) ->
      "type=\"dir\", path=\"" <> path <> "\""
    types_config.ProfileSourceGit(url, ref) ->
      case ref {
        option.Some(value) ->
          "type=\"git\", url=\"" <> url <> "\", ref=\"" <> value <> "\""
        option.None -> "type=\"git\", url=\"" <> url <> "\""
      }
  }
}

fn read_limits_table_defaults(
  path: String,
  header_prefix: String,
) -> dict.Dict(String, String) {
  let content = read_doc(path)
  let rows = extract_table_rows(path, content, header_prefix)

  rows
  |> list.fold(dict.new(), fn(acc, line) {
    let cells = table_cells(line)
    case cells {
      [key, _kind, default_value, ..] ->
        dict.insert(acc, key, normalize_doc_default(default_value))
      _ ->
        panic as {
          "DOC_LINT_FAIL file=" <> path <> " pattern=invalid_table_row"
        }
    }
  })
}

fn read_limits_toml_defaults(path: String) -> dict.Dict(String, String) {
  let content = read_doc(path)
  let entries = case limits_table.parse_toml(content) {
    Ok(found) -> found
    Error(err) ->
      panic as { "DOC_LINT_FAIL file=" <> path <> " pattern=" <> err }
  }

  entries
  |> limits_table.defaults_by_key
  |> list.fold(dict.new(), fn(acc, entry) {
    let #(key, value) = entry
    dict.insert(acc, key, value)
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
  let keys = split_slash_parts(key_cell)

  case normalize_config_defaults(default_cell) {
    option.None -> acc
    option.Some(defaults) ->
      case list.length(keys) == list.length(defaults) {
        True -> insert_pairs(acc, keys, defaults)
        False ->
          panic as {
            "DOC_LINT_FAIL file=" <> path <> " pattern=invalid_default_parts"
          }
      }
  }
}

fn insert_pairs(
  acc: dict.Dict(String, String),
  keys: List(String),
  defaults: List(String),
) -> dict.Dict(String, String) {
  case keys, defaults {
    [], [] -> acc
    [key, ..rest_keys], [value, ..rest_values] ->
      insert_pairs(dict.insert(acc, key, value), rest_keys, rest_values)
    _, _ -> acc
  }
}

fn normalize_config_defaults(raw: String) -> option.Option(List(String)) {
  let cleaned = normalize_doc_default(raw)

  case
    string.contains(cleaned, "ver defaults")
    || string.contains(cleaned, "requerido")
  {
    True -> option.None
    False -> {
      let parts =
        cleaned
        |> string.split(" / ")
        |> list.map(normalize_config_scalar)
      option.Some(parts)
    }
  }
}

fn normalize_config_scalar(value: String) -> String {
  let cleaned =
    value
    |> normalize_doc_default
    |> strip_after_paren

  let without_underscores = string.replace(cleaned, "_", "")

  case int.parse(without_underscores) {
    Ok(_) -> without_underscores
    Error(_) -> cleaned
  }
}

fn strip_after_paren(value: String) -> String {
  case string.split(value, " (") {
    [head, ..] -> head
    _ -> value
  }
}

fn split_slash_parts(value: String) -> List(String) {
  value
  |> normalize_doc_default
  |> string.split(" / ")
}

fn normalize_doc_default(value: String) -> String {
  value
  |> string.replace("`", "")
  |> string.trim
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

fn extract_table_rows(
  path: String,
  content: String,
  header_prefix: String,
) -> List(String) {
  let lines = string.split(content, "\n")
  let lines = drop_until_header(lines, header_prefix)

  case lines {
    [] ->
      panic as {
        "DOC_LINT_FAIL file=" <> path <> " pattern=missing_table_header"
      }
    [_header, _separator, ..rest] ->
      take_while(rest, fn(line) {
        line
        |> string.trim
        |> string.starts_with("|")
      })
    _ ->
      panic as {
        "DOC_LINT_FAIL file=" <> path <> " pattern=invalid_table_header"
      }
  }
}

fn drop_until_header(lines: List(String), header_prefix: String) -> List(String) {
  case lines {
    [] -> []
    [line, ..rest] ->
      case string.starts_with(string.trim(line), header_prefix) {
        True -> [line, ..rest]
        False -> drop_until_header(rest, header_prefix)
      }
  }
}

fn take_while(
  lines: List(String),
  predicate: fn(String) -> Bool,
) -> List(String) {
  case lines {
    [] -> []
    [line, ..rest] ->
      case predicate(line) {
        True -> [line, ..take_while(rest, predicate)]
        False -> []
      }
  }
}

fn table_cells(line: String) -> List(String) {
  line
  |> string.trim
  |> string.split("|")
  |> list.map(string.trim)
  |> list.filter(fn(cell) { !string.is_empty(cell) })
}

fn assert_defaults_match(
  path: String,
  doc_defaults: dict.Dict(String, String),
  expected_defaults: dict.Dict(String, String),
) {
  expected_defaults
  |> dict.to_list
  |> list.each(fn(entry) {
    let #(key, expected) = entry
    case dict.get(doc_defaults, key) {
      Ok(found) ->
        case normalize_doc_default(found) == normalize_doc_default(expected) {
          True -> Nil
          False ->
            panic as {
              "DOC_LINT_FAIL file="
              <> path
              <> " pattern=default_mismatch key="
              <> key
            }
        }
      Error(_) ->
        panic as {
          "DOC_LINT_FAIL file=" <> path <> " pattern=missing_key key=" <> key
        }
    }
  })

  doc_defaults
  |> dict.to_list
  |> list.each(fn(entry) {
    let #(key, _) = entry
    case dict.get(expected_defaults, key) {
      Ok(_) -> Nil
      Error(_) ->
        panic as {
          "DOC_LINT_FAIL file=" <> path <> " pattern=unknown_key key=" <> key
        }
    }
  })
}

fn assert_config_defaults_match(
  path: String,
  config_defaults: dict.Dict(String, String),
  expected_defaults: dict.Dict(String, String),
) {
  config_defaults
  |> dict.to_list
  |> list.each(fn(entry) {
    let #(key, found) = entry
    case dict.get(expected_defaults, key) {
      Ok(expected) ->
        case
          normalize_config_scalar(found) == normalize_config_scalar(expected)
        {
          True -> Nil
          False ->
            panic as {
              "DOC_LINT_FAIL file="
              <> path
              <> " pattern=default_mismatch key="
              <> key
            }
        }
      Error(_) -> Nil
    }
  })
}
