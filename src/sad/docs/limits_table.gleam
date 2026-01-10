import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type LimitEntry {
  LimitEntry(
    key: String,
    kind: String,
    default: String,
    sprint: String,
    usage: String,
  )
}

type PartialEntry {
  PartialEntry(
    key: Option(String),
    kind: Option(String),
    default: Option(String),
    sprint: Option(String),
    usage: Option(String),
  )
}

pub fn parse_toml(content: String) -> Result(List(LimitEntry), String) {
  let lines = string.split(content, "\n")
  parse_lines(lines, None, [])
}

pub fn render_markdown(entries: List(LimitEntry)) -> String {
  let header = [
    "# Limits y defaults canonicos",
    "",
    "Plan version: v2.1",
    "",
    "Generated from docs/plan/limits.toml. Do not edit by hand.",
    "Regenerate: `make docs-limits`.",
    "",
    "## Precedencia",
    "1) Flags CLI (si aplica)",
    "2) Env vars del proceso (solo ruta config y api key)",
    "3) config.toml (interpolacion solo env vars)",
    "4) Defaults en SadConfig.default_*",
    "",
    "## Tabla de keys (minimo v0)",
    "| Key | Tipo | Default | Sprint | Uso |",
    "| --- | --- | --- | --- | --- |",
  ]

  let rows =
    entries
    |> list.map(fn(entry) { render_row(entry) })

  list.append(header, rows)
  |> string.join("\n")
  <> "\n"
}

pub fn defaults_by_key(entries: List(LimitEntry)) -> List(#(String, String)) {
  entries
  |> list.map(fn(entry) {
    let LimitEntry(key, _kind, default, _sprint, _usage) = entry
    #(key, default)
  })
}

fn render_row(entry: LimitEntry) -> String {
  let LimitEntry(key, kind, default, sprint, usage) = entry
  "| "
  <> key
  <> " | "
  <> kind
  <> " | "
  <> default
  <> " | "
  <> sprint
  <> " | "
  <> usage
  <> " |"
}

fn parse_lines(
  lines: List(String),
  current: Option(PartialEntry),
  acc: List(LimitEntry),
) -> Result(List(LimitEntry), String) {
  case lines {
    [] ->
      case current {
        None -> Ok(list.reverse(acc))
        Some(partial) -> {
          use entry <- result.try(finalize_partial(partial))
          Ok(list.reverse([entry, ..acc]))
        }
      }

    [line, ..rest] ->
      case parse_line(line, current) {
        Ok(#(next_current, maybe_entry)) ->
          case maybe_entry {
            Some(entry) -> parse_lines(rest, next_current, [entry, ..acc])
            None -> parse_lines(rest, next_current, acc)
          }
        Error(err) -> Error(err)
      }
  }
}

fn parse_line(
  line: String,
  current: Option(PartialEntry),
) -> Result(#(Option(PartialEntry), Option(LimitEntry)), String) {
  let trimmed = string.trim(line)

  case trimmed == "" || string.starts_with(trimmed, "#") {
    True -> Ok(#(current, None))
    False ->
      case trimmed == "[[limits]]" {
        True -> start_new_entry(current)
        False ->
          case current {
            None -> Error("limits_toml_missing_header")
            Some(partial) -> {
              use updated <- result.try(apply_kv(partial, trimmed))
              Ok(#(Some(updated), None))
            }
          }
      }
  }
}

fn start_new_entry(
  current: Option(PartialEntry),
) -> Result(#(Option(PartialEntry), Option(LimitEntry)), String) {
  case current {
    None -> Ok(#(Some(empty_partial()), None))
    Some(partial) -> {
      use entry <- result.try(finalize_partial(partial))
      Ok(#(Some(empty_partial()), Some(entry)))
    }
  }
}

fn apply_kv(partial: PartialEntry, line: String) -> Result(PartialEntry, String) {
  use parts <- result.try(split_key_value(line))

  let #(raw_key, raw_value) = parts
  let key = string.trim(raw_key)
  use value <- result.try(parse_value(raw_value))

  let PartialEntry(prev_key, prev_kind, prev_default, prev_sprint, prev_usage) =
    partial

  case key {
    "key" ->
      Ok(PartialEntry(
        Some(value),
        prev_kind,
        prev_default,
        prev_sprint,
        prev_usage,
      ))
    "type" ->
      Ok(PartialEntry(
        prev_key,
        Some(value),
        prev_default,
        prev_sprint,
        prev_usage,
      ))
    "default" ->
      Ok(PartialEntry(prev_key, prev_kind, Some(value), prev_sprint, prev_usage))
    "sprint" ->
      Ok(PartialEntry(
        prev_key,
        prev_kind,
        prev_default,
        Some(value),
        prev_usage,
      ))
    "use" ->
      Ok(PartialEntry(
        prev_key,
        prev_kind,
        prev_default,
        prev_sprint,
        Some(value),
      ))
    _ -> Error("limits_toml_unknown_field " <> key)
  }
}

fn split_key_value(line: String) -> Result(#(String, String), String) {
  let parts = string.split(line, "=")

  case parts {
    [left, right] -> Ok(#(left, right))
    [left, right, ..rest] -> Ok(#(left, [right, ..rest] |> string.join("=")))
    _ -> Error("limits_toml_invalid_line")
  }
}

fn parse_value(raw: String) -> Result(String, String) {
  let value = string.trim(raw)

  case value == "" {
    True -> Ok("")
    False ->
      case string.starts_with(value, "\"") && string.ends_with(value, "\"") {
        True -> Ok(strip_wrapping(value))
        False ->
          case string.starts_with(value, "'") && string.ends_with(value, "'") {
            True -> Ok(strip_wrapping(value))
            False -> Ok(value)
          }
      }
  }
}

fn strip_wrapping(value: String) -> String {
  let len = string.length(value)
  case len < 2 {
    True -> value
    False -> string.slice(from: value, at_index: 1, length: len - 2)
  }
}

fn empty_partial() -> PartialEntry {
  PartialEntry(None, None, None, None, None)
}

fn finalize_partial(partial: PartialEntry) -> Result(LimitEntry, String) {
  let PartialEntry(key, kind, default, sprint, usage) = partial

  case key, kind, default, sprint, usage {
    Some(k), Some(t), Some(d), Some(s), Some(u) -> Ok(LimitEntry(k, t, d, s, u))
    _, _, _, _, _ -> Error("limits_toml_incomplete_entry")
  }
}
