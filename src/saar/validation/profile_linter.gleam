//// Profile linter for semantic profile validation.
////
//// Mission: emit stable diagnostics for semantic profile issues after decode.
////
//// Responsibilities:
//// - Validate schema_version compatibility.
//// - Validate runner availability against the provided context.
//// - Validate capability ids for duplicates.
////
//// Non-responsibilities:
//// - JSON schema validation.
//// - Decoding JSON into typed profiles.
//// - Performing any IO or filesystem access.
////
//// Relationships:
//// - Consumed by loaders/tests after `saar/decoders`.
//// - Uses `saar/types/profile` for typed profile inspection.

import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import saar/types/profile as types_profile
import saar/types/runner as types_runner

/// Diagnostic severity levels for profile linting.
pub type Severity {
  SeverityError
  SeverityWarning
}

/// Stable diagnostic for profile linting.
pub type Diagnostic {
  Diagnostic(
    code: String,
    severity: Severity,
    message: String,
    hint: Option(String),
    json_path: Option(String),
    file: Option(String),
  )
}

/// Context required for profile linting.
pub type LintContext {
  LintContext(
    expected_schema_version: String,
    available_runners: List(String),
    file: Option(String),
    capability_ids: Option(List(String)),
  )
}

/// Lints a decoded profile with a schema version and context.
pub fn lint_profile(
  profile: types_profile.Profile,
  schema_version: Option(String),
  ctx: LintContext,
) -> List(Diagnostic) {
  let LintContext(
    expected_schema_version: expected,
    available_runners: runners,
    file: file,
    capability_ids: override_ids,
  ) = ctx

  []
  |> list.append(lint_schema_version(schema_version, expected, file))
  |> list.append(lint_runner_missing(profile, runners, file))
  |> list.append(lint_duplicate_capability_ids(profile, override_ids, file))
}

fn lint_schema_version(
  schema_version: Option(String),
  expected: String,
  file: Option(String),
) -> List(Diagnostic) {
  case schema_version {
    Some(value) if value == expected -> []
    Some(value) -> [
      diagnostic_error(
        "schema_version_mismatch",
        "schema_version mismatch: expected " <> expected <> ", got " <> value,
        Some("Use schema_version " <> expected),
        Some("$.schema_version"),
        file,
      ),
    ]
    None -> [
      diagnostic_error(
        "schema_version_mismatch",
        "schema_version missing",
        Some("Add schema_version " <> expected),
        Some("$.schema_version"),
        file,
      ),
    ]
  }
}

fn lint_runner_missing(
  profile: types_profile.Profile,
  available_runners: List(String),
  file: Option(String),
) -> List(Diagnostic) {
  let types_profile.Profile(runner: runner, ..) = profile
  let types_runner.Runner(type_: runner_type, ..) = runner

  case list.contains(available_runners, runner_type) {
    True -> []
    False -> [
      diagnostic_error(
        "runner_missing",
        "runner type not found: " <> runner_type,
        Some("Ensure the runner exists in the profile source"),
        Some("$.runner.type"),
        file,
      ),
    ]
  }
}

fn lint_duplicate_capability_ids(
  profile: types_profile.Profile,
  override_ids: Option(List(String)),
  file: Option(String),
) -> List(Diagnostic) {
  let ids = case override_ids {
    Some(custom) -> custom
    None -> capability_ids_from_profile(profile)
  }

  find_duplicates(ids)
  |> list.map(fn(id) {
    diagnostic_error(
      "duplicate_capability_id",
      "duplicate capability id: " <> id,
      Some("Capability ids must be unique"),
      Some("$.interface.capabilities"),
      file,
    )
  })
}

fn capability_ids_from_profile(profile: types_profile.Profile) -> List(String) {
  let types_profile.Profile(interface: interface, ..) = profile

  case interface {
    types_profile.RunnerInterface(capabilities) -> dict.keys(capabilities)
    types_profile.HttpInterface(capabilities: capabilities, ..) ->
      dict.keys(capabilities)
  }
}

fn find_duplicates(values: List(String)) -> List(String) {
  let counts =
    values
    |> list.fold(dict.new(), fn(acc, value) {
      let next = case dict.get(acc, value) {
        Ok(count) -> count + 1
        Error(_) -> 1
      }
      dict.insert(acc, value, next)
    })

  counts
  |> dict.to_list
  |> list.filter_map(fn(entry) {
    let #(value, count) = entry
    case count > 1 {
      True -> Ok(value)
      False -> Error(Nil)
    }
  })
}

fn diagnostic_error(
  code: String,
  message: String,
  hint: Option(String),
  json_path: Option(String),
  file: Option(String),
) -> Diagnostic {
  Diagnostic(
    code: code,
    severity: SeverityError,
    message: message,
    hint: hint,
    json_path: json_path,
    file: file,
  )
}
