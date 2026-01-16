import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/enums as types_enums
import simplifile

pub fn doc_lint_forbidden_patterns_test() {
  let roots = ["docs/arquitectura/examples/snippets"]

  let forbidden = [
    "process.try_call",
    "process.select_after",
    "process.select(selector)",
  ]

  roots
  |> list.each(fn(root) {
    list_files_recursive(root)
    |> list.filter(fn(path) { string.ends_with(path, ".gleam") })
    |> list.each(fn(path) {
      let contents = read_text_or_panic(path)
      forbidden
      |> list.each(fn(pattern) {
        case string.contains(contents, pattern) {
          True -> doc_lint_fail(path, pattern)
          False -> Nil
        }
      })
    })
  })
}

pub fn doc_lint_actor_stop_usage_test() {
  let roots = ["docs/arquitectura/examples/snippets"]
  let pattern = "actor.stop(process.Normal)"

  roots
  |> list.each(fn(root) {
    list_files_recursive(root)
    |> list.filter(fn(path) { string.ends_with(path, ".gleam") })
    |> list.each(fn(path) {
      let contents = read_text_or_panic(path)
      case string.contains(contents, pattern) {
        True -> doc_lint_fail(path, pattern)
        False -> Nil
      }
    })
  })
}

pub fn doc_lint_limits_defaults_match_config_test() {
  let cfg = types_config.default_saar_config()
  let types_config.SaarConfig(api_key: api_key, ..) = cfg
  types_core.secret_is_empty(api_key) |> should.equal(True)

  let entries = parse_limits_toml("docs/plan/limits.toml")

  entries
  |> list.each(fn(entry) {
    case entry.key {
      "server.host" -> entry.default |> should.equal(cfg.server_host)
      "server.port" -> entry.default_int |> should.equal(Some(cfg.server_port))

      "auth.api_key" -> entry.default |> should.equal("\"\"")

      "profiles.sources" -> {
        entry.default |> should.equal("[{type=\"dir\", path=\".\"}]")
        let types_config.SaarConfig(profiles: profiles, ..) = cfg
        profiles.sources
        |> should.equal([types_config.ProfileSourceDir(path: ".")])
      }

      "profiles.git_cache_dir" -> {
        let types_config.SaarConfig(profiles: profiles, ..) = cfg
        entry.default |> should.equal(profiles.git_cache_dir)
      }

      "runners.python_bin" -> {
        let types_config.SaarConfig(runner: runner, ..) = cfg
        entry.default |> should.equal(runner.python_bin)
      }

      "workspaces.directory" -> {
        let types_config.SaarConfig(storage: storage, ..) = cfg
        entry.default |> should.equal(storage.workspaces_directory)
      }

      "limits.call_timeout_ms" -> {
        let types_config.SaarConfig(timeouts: timeouts, ..) = cfg
        entry.default_int |> should.equal(Some(timeouts.call_timeout_ms))
      }

      "limits.status_timeout_ms" -> {
        let types_config.SaarConfig(timeouts: timeouts, ..) = cfg
        entry.default_int |> should.equal(Some(timeouts.status_timeout_ms))
      }

      "limits.registry_timeout_ms" -> {
        let types_config.SaarConfig(timeouts: timeouts, ..) = cfg
        entry.default_int |> should.equal(Some(timeouts.registry_timeout_ms))
      }

      "limits.health_check_timeout_ms" -> {
        let types_config.SaarConfig(timeouts: timeouts, ..) = cfg
        entry.default_int
        |> should.equal(Some(timeouts.health_check_timeout_ms))
      }

      "limits.shutdown_timeout_ms" -> {
        let types_config.SaarConfig(timeouts: timeouts, ..) = cfg
        entry.default_int |> should.equal(Some(timeouts.shutdown_timeout_ms))
      }

      "limits.log_buffer_bytes" -> {
        let types_config.SaarConfig(limits: limits, ..) = cfg
        entry.default_int |> should.equal(Some(limits.log_buffer_bytes))
      }

      "limits.max_stdout_bytes" -> {
        let types_config.SaarConfig(limits: limits, ..) = cfg
        entry.default_int |> should.equal(Some(limits.max_stdout_bytes))
      }

      "limits.max_runner_event_bytes" -> {
        let types_config.SaarConfig(limits: limits, ..) = cfg
        entry.default_int |> should.equal(Some(limits.max_runner_event_bytes))
      }

      "limits.max_request_body_bytes" -> {
        let types_config.SaarConfig(limits: limits, ..) = cfg
        entry.default_int |> should.equal(Some(limits.max_request_body_bytes))
      }

      "limits.max_http_response_bytes" -> {
        let types_config.SaarConfig(limits: limits, ..) = cfg
        entry.default_int |> should.equal(Some(limits.max_http_response_bytes))
      }

      "limits.max_file_fetch_bytes" -> {
        let types_config.SaarConfig(limits: limits, ..) = cfg
        entry.default_int |> should.equal(Some(limits.max_file_fetch_bytes))
      }

      "limits.sse_keep_alive_interval_ms" -> {
        let types_config.SaarConfig(stream: stream, ..) = cfg
        entry.default_int
        |> should.equal(Some(stream.sse_keep_alive_interval_ms))
      }

      "limits.port_range_min" -> {
        let types_config.SaarConfig(runner: runner, ..) = cfg
        entry.default_int |> should.equal(Some(runner.port_range_min))
      }

      "limits.port_range_max" -> {
        let types_config.SaarConfig(runner: runner, ..) = cfg
        entry.default_int |> should.equal(Some(runner.port_range_max))
      }

      "network.managed_port_host" -> {
        let types_config.SaarConfig(runner: runner, ..) = cfg
        entry.default |> should.equal(runner.managed_port_host)
      }

      "log_stream.batch_byte_size" -> {
        let types_config.SaarConfig(stream: stream, ..) = cfg
        entry.default_int
        |> should.equal(Some(stream.log_stream.batch_byte_size))
      }

      "log_stream.flush_interval_ms" -> {
        let types_config.SaarConfig(stream: stream, ..) = cfg
        entry.default_int
        |> should.equal(Some(stream.log_stream.flush_interval_ms))
      }

      "interaction_stream.batch_byte_size" -> {
        let types_config.SaarConfig(stream: stream, ..) = cfg
        entry.default_int
        |> should.equal(Some(stream.interaction_stream.batch_byte_size))
      }

      "interaction_stream.flush_interval_ms" -> {
        let types_config.SaarConfig(stream: stream, ..) = cfg
        entry.default_int
        |> should.equal(Some(stream.interaction_stream.flush_interval_ms))
      }

      "interaction_stream.push_timeout_ms" -> {
        let types_config.SaarConfig(stream: stream, ..) = cfg
        entry.default_int
        |> should.equal(Some(stream.interaction_stream.push_timeout_ms))
      }

      "security.landlock_mode" -> {
        let types_config.SaarConfig(landlock_mode: mode, ..) = cfg
        entry.default |> should.equal(types_enums.landlock_mode_to_string(mode))
      }

      _ -> {
        let msg = "Unhandled limits.toml key: " <> entry.key
        panic as msg
      }
    }
  })
}

pub fn doc_lint_limits_md_matches_toml_test() {
  let entries = parse_limits_toml("docs/plan/limits.toml")
  let rows = parse_limits_md_table("docs/plan/limits.md")
  let rows_map = rows_by_key(rows)

  list.length(rows) |> should.equal(list.length(entries))

  entries
  |> list.each(fn(entry) {
    let assert Ok(row) = dict.get(rows_map, entry.key)
    row.default |> should.equal(entry.default_for_md)
    row.kind |> should.equal(entry.kind)
    row.sprint |> should.equal(entry.sprint)
    row.usage |> should.equal(entry.usage)
  })
}

pub fn doc_lint_config_defaults_match_config_test() {
  let cfg = types_config.default_saar_config()
  let contents = read_text_or_panic("docs/arquitectura/config.md")

  assert_config_md_row_defaults(contents, "server.host", [
    cfg.server_host,
    int.to_string(cfg.server_port),
  ])

  let types_config.SaarConfig(
    storage: storage,
    runner: runner,
    limits: limits,
    ..,
  ) = cfg

  assert_config_md_row_defaults(contents, "workspaces.directory", [
    storage.workspaces_directory,
  ])

  assert_config_md_row_defaults(contents, "limits.port_range_min", [
    int.to_string(runner.port_range_min),
    int.to_string(runner.port_range_max),
  ])

  assert_config_md_row_defaults(contents, "limits.log_buffer_bytes", [
    int.to_string(limits.log_buffer_bytes),
  ])

  assert_config_md_row_defaults(contents, "limits.max_stdout_bytes", [
    int.to_string(limits.max_stdout_bytes),
  ])

  assert_config_md_row_defaults(contents, "limits.max_runner_event_bytes", [
    int.to_string(limits.max_runner_event_bytes),
  ])

  assert_config_md_row_defaults(contents, "limits.max_request_body_bytes", [
    int.to_string(limits.max_request_body_bytes),
  ])

  assert_config_md_row_defaults(contents, "limits.max_http_response_bytes", [
    int.to_string(limits.max_http_response_bytes),
  ])

  assert_config_md_row_defaults(contents, "limits.max_file_fetch_bytes", [
    int.to_string(limits.max_file_fetch_bytes),
  ])
}

type LimitsEntry {
  LimitsEntry(
    key: String,
    kind: String,
    default: String,
    default_int: Option(Int),
    default_for_md: String,
    sprint: String,
    usage: String,
  )
}

type LimitsMdRow {
  LimitsMdRow(kind: String, default: String, sprint: String, usage: String)
}

fn doc_lint_fail(path: String, pattern: String) -> Nil {
  let msg = "DOC_LINT_FAIL file=" <> path <> " pattern=" <> pattern
  panic as msg
}

fn read_text_or_panic(path: String) -> String {
  case simplifile.read(from: path) {
    Ok(s) -> s
    Error(err) -> {
      let msg =
        "Failed to read file: "
        <> path
        <> " err="
        <> simplifile.describe_error(err)
      panic as msg
    }
  }
}

fn list_files_recursive(root: String) -> List(String) {
  case simplifile.read_directory(at: root) {
    Error(err) -> {
      let msg =
        "Failed to read directory: "
        <> root
        <> " err="
        <> simplifile.describe_error(err)
      panic as msg
    }

    Ok(entries) ->
      entries
      |> list.fold([], fn(acc, name) {
        let path = root <> "/" <> name

        case simplifile.is_directory(path) {
          Ok(True) -> list.append(acc, list_files_recursive(path))
          Ok(False) -> list.append(acc, [path])
          Error(_) -> acc
        }
      })
  }
}

type PartialLimits {
  PartialLimits(
    key: String,
    kind: String,
    default: String,
    default_int: Option(Int),
    sprint: String,
    usage: String,
  )
}

fn parse_limits_toml(path: String) -> List(LimitsEntry) {
  let raw = read_text_or_panic(path)

  raw
  |> string.split(on: "\n")
  |> list.map(string.trim)
  |> parse_limits_lines(partial_empty(), [])
  |> list.reverse
}

fn parse_limits_lines(
  lines: List(String),
  current: PartialLimits,
  acc: List(LimitsEntry),
) -> List(LimitsEntry) {
  case lines {
    [] -> finalize_partial(current, acc)

    [line, ..rest] ->
      case line {
        "[[limits]]" -> {
          let acc = finalize_partial(current, acc)
          parse_limits_lines(rest, partial_empty(), acc)
        }

        _ -> {
          let next = apply_limit_line(current, line)
          parse_limits_lines(rest, next, acc)
        }
      }
  }
}

fn finalize_partial(
  current: PartialLimits,
  acc: List(LimitsEntry),
) -> List(LimitsEntry) {
  let PartialLimits(key: key, ..) = current

  case string.is_empty(key) {
    True -> acc
    False -> [partial_to_entry(current), ..acc]
  }
}

fn partial_empty() -> PartialLimits {
  PartialLimits(
    key: "",
    kind: "",
    default: "",
    default_int: None,
    sprint: "",
    usage: "",
  )
}

fn partial_to_entry(current: PartialLimits) -> LimitsEntry {
  let PartialLimits(
    key: key,
    kind: kind,
    default: default,
    default_int: default_int,
    sprint: sprint,
    usage: usage,
  ) = current

  let default_for_md = case default_int {
    Some(i) -> int.to_string(i)
    None -> default
  }

  LimitsEntry(
    key: key,
    kind: kind,
    default: default,
    default_int: default_int,
    default_for_md: default_for_md,
    sprint: sprint,
    usage: usage,
  )
}

fn apply_limit_line(current: PartialLimits, line: String) -> PartialLimits {
  case parse_kv(line) {
    None -> current

    Some(#(k, raw_v)) ->
      case k {
        "key" -> {
          let v = strip_wrapping_quotes(raw_v)
          PartialLimits(..current, key: v)
        }

        "type" -> {
          let v = strip_wrapping_quotes(raw_v)
          PartialLimits(..current, kind: v)
        }

        "default" -> {
          let v = strip_wrapping_quotes(raw_v)

          case int.parse(v) {
            Ok(i) ->
              PartialLimits(
                ..current,
                default: int.to_string(i),
                default_int: Some(i),
              )
            Error(_) -> PartialLimits(..current, default: v, default_int: None)
          }
        }

        "sprint" -> {
          let v = strip_wrapping_quotes(raw_v)
          PartialLimits(..current, sprint: v)
        }

        "use" -> {
          let v = strip_wrapping_quotes(raw_v)
          PartialLimits(..current, usage: v)
        }

        _ -> current
      }
  }
}

fn parse_kv(line: String) -> Option(#(String, String)) {
  let line = string.trim(line)

  case string.is_empty(line) || string.starts_with(line, "#") {
    True -> None
    False ->
      case string.split_once(line, on: "=") {
        Error(_) -> None
        Ok(#(k, v)) -> Some(#(string.trim(k), string.trim(v)))
      }
  }
}

fn strip_wrapping_quotes(raw: String) -> String {
  let s = string.trim(raw)
  let len = string.length(s)

  case len >= 2 {
    False -> s

    True -> {
      let first = string.slice(s, 0, 1)
      let last = string.slice(s, len - 1, 1)

      case
        { first == "\"" && last == "\"" } || { first == "'" && last == "'" }
      {
        True -> string.slice(s, 1, len - 2)
        False -> s
      }
    }
  }
}

fn parse_limits_md_table(path: String) -> List(#(String, LimitsMdRow)) {
  let raw = read_text_or_panic(path)

  raw
  |> string.split(on: "\n")
  |> list.map(string.trim)
  |> list.filter(fn(line) { string.starts_with(line, "|") })
  |> list.filter(fn(line) { string.starts_with(line, "| ---") == False })
  |> list.filter(fn(line) { string.starts_with(line, "| Key |") == False })
  |> list.filter(fn(line) { string.contains(line, ".") })
  |> list.filter_map(parse_limits_md_row)
}

fn parse_limits_md_row(line: String) -> Result(#(String, LimitsMdRow), Nil) {
  let parts =
    string.split(line, on: "|")
    |> list.map(string.trim)
    |> list.filter(fn(s) { s != "" })

  // The "Uso" column can contain unescaped `|`, so we join the tail back.
  case parts {
    [key, kind, default, sprint, usage, ..rest] -> {
      let usage = string.join([usage, ..rest], with: "|")
      Ok(#(
        key,
        LimitsMdRow(kind: kind, default: default, sprint: sprint, usage: usage),
      ))
    }

    _ -> Error(Nil)
  }
}

fn rows_by_key(
  rows: List(#(String, LimitsMdRow)),
) -> dict.Dict(String, LimitsMdRow) {
  dict.from_list(rows)
}

fn assert_config_md_row_defaults(
  contents: String,
  key: String,
  expected: List(String),
) -> Nil {
  let line = find_config_md_row(contents, key)
  let values = extract_backticked_values(line)

  expected
  |> list.each(fn(want) {
    case list.contains(values, want) {
      True -> Nil
      False -> {
        let msg =
          "DOC_LINT_FAIL file=docs/arquitectura/config.md pattern=default_mismatch key="
          <> key
          <> " expected="
          <> want
        panic as msg
      }
    }
  })
}

fn find_config_md_row(contents: String, key: String) -> String {
  let out =
    contents
    |> string.split(on: "\n")
    |> list.find(fn(line) {
      string.starts_with(string.trim(line), "|") && string.contains(line, key)
    })

  case out {
    Ok(line) -> line
    Error(_) -> {
      let msg = "Missing config.md row key=" <> key
      panic as msg
    }
  }
}

fn extract_backticked_values(line: String) -> List(String) {
  collect_backticked_segments(string.split(line, on: "`"), False, [])
  |> list.map(normalize_backtick_value)
}

fn collect_backticked_segments(
  parts: List(String),
  inside: Bool,
  acc: List(String),
) -> List(String) {
  case parts {
    [] -> list.reverse(acc)

    [part, ..rest] ->
      case inside {
        True -> collect_backticked_segments(rest, False, [part, ..acc])
        False -> collect_backticked_segments(rest, True, acc)
      }
  }
}

fn normalize_backtick_value(value: String) -> String {
  value
  |> string.trim
  |> string.replace("_", "")
}
