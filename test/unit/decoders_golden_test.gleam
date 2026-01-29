import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import saar/decoders
import saar/types/profile as types_profile
import saar/types/runner as types_runner
import saar/validation/profile_linter
import saar/validation/profile_schema
import simplifile

pub fn main() {
  gleeunit.main()
}

pub fn golden_valid_profiles_pass_all_test() {
  let assert Ok(entries) =
    simplifile.read_directory(at: "test/fixtures/source_local/profiles")

  entries
  |> list.filter(fn(name) { string.ends_with(name, ".json") })
  |> list.each(fn(name) {
    let path = "test/fixtures/source_local/profiles/" <> name
    let assert Ok(contents) = simplifile.read(from: path)
    let assert Ok(value) = json.parse(contents, decode.dynamic)

    profile_schema.validate_profile(value) |> should.be_ok

    let schema_version = schema_version_from_dynamic(value)
    let assert Ok(profile) = decoders.decode_profile(value)
    let ctx = lint_context_for_profile(profile, Some(path), None)

    let diags = profile_linter.lint_profile(profile, schema_version, ctx)
    list.length(diags) |> should.equal(0)
  })
}

pub fn golden_invalid_profiles_fail_expected_test() {
  let assert Ok(entries) =
    simplifile.read_directory(at: "test/fixtures/source_local/profiles_invalid")

  let expected =
    dict.from_list([
      #("missing_required.json", ExpectedSchema(["required"])),
      #("invalid_enum.json", ExpectedSchema(["enum", "pattern"])),
      #(
        "schema_version_mismatch.json",
        ExpectedLint("schema_version_mismatch", "$.schema_version"),
      ),
      #("runner_missing.json", ExpectedLint("runner_missing", "$.runner.type")),
    ])

  entries
  |> list.filter(fn(name) { string.ends_with(name, ".json") })
  |> list.each(fn(name) {
    let path = "test/fixtures/source_local/profiles_invalid/" <> name
    let assert Ok(contents) = simplifile.read(from: path)
    let assert Ok(value) = json.parse(contents, decode.dynamic)
    let assert Ok(expected_out) = dict.get(expected, name)

    case profile_schema.validate_profile(value) {
      Error(errors) -> assert_expected_schema(errors, expected_out)

      Ok(_) -> {
        let schema_version = schema_version_from_dynamic(value)
        let assert Ok(profile) = decoders.decode_profile(value)
        let ctx =
          lint_context_for_profile(
            profile,
            Some(path),
            expected_available_runners_override(expected_out),
          )

        let diags = profile_linter.lint_profile(profile, schema_version, ctx)
        assert_expected_lint(diags, expected_out)
      }
    }
  })
}

type ExpectedFailure {
  ExpectedSchema(codes: List(String))
  ExpectedLint(code: String, json_path: String)
}

fn assert_expected_schema(
  errors: List(profile_schema.SchemaError),
  expected: ExpectedFailure,
) -> Nil {
  case expected {
    ExpectedSchema(codes) ->
      codes
      |> list.each(fn(code) {
        errors
        |> list.map(profile_schema.error_code)
        |> list.any(fn(value) { value == code })
        |> should.equal(True)
      })

    ExpectedLint(_, _) -> should.equal(True, False)
  }
}

fn assert_expected_lint(
  diags: List(profile_linter.Diagnostic),
  expected: ExpectedFailure,
) -> Nil {
  case expected {
    ExpectedSchema(_) -> should.equal(True, False)

    ExpectedLint(code, json_path) ->
      case list.find(diags, fn(diag) { diag.code == code }) {
        Ok(diag) -> should.equal(diag.json_path, Some(json_path))

        Error(_) -> should.equal(True, False)
      }
  }
}

fn expected_available_runners_override(
  expected: ExpectedFailure,
) -> Option(List(String)) {
  case expected {
    ExpectedLint("runner_missing", _) -> Some([])
    _ -> None
  }
}

fn lint_context_for_profile(
  profile: types_profile.Profile,
  file: Option(String),
  override: Option(List(String)),
) -> profile_linter.LintContext {
  let types_profile.Profile(runner: runner, ..) = profile
  let types_runner.Runner(type_: runner_type, ..) = runner

  let available = case override {
    Some(custom) -> custom
    None -> [runner_type]
  }

  profile_linter.LintContext(
    expected_schema_version: "saar.profile/1.0",
    available_runners: available,
    file: file,
    capability_ids: None,
  )
}

fn schema_version_from_dynamic(value: Dynamic) -> Option(String) {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Error(_) -> None
    Ok(fields) ->
      case dict.get(fields, "schema_version") {
        Error(_) -> None
        Ok(raw) ->
          case decode.run(raw, decode.string) {
            Ok(version) -> Some(version)
            Error(_) -> None
          }
      }
  }
}
