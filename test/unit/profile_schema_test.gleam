import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import saar/validation/profile_schema
import simplifile

pub fn main() {
  gleeunit.main()
}

pub fn schema_accepts_valid_profiles_test() {
  let assert Ok(entries) =
    simplifile.read_directory(at: "test/fixtures/source_local/profiles")

  entries
  |> list.filter(fn(name) { string.ends_with(name, ".json") })
  |> list.each(fn(name) {
    let path = "test/fixtures/source_local/profiles/" <> name
    let assert Ok(contents) = simplifile.read(from: path)
    let assert Ok(value) = json.parse(contents, decode.dynamic)
    profile_schema.validate_profile(value) |> should.be_ok
  })
}

pub fn schema_rejects_missing_required_test() {
  let assert Ok(contents) =
    simplifile.read(
      from: "test/fixtures/source_local/profiles_invalid/missing_required.json",
    )

  let assert Ok(value) = json.parse(contents, decode.dynamic)

  let assert Error(errors) = profile_schema.validate_profile(value)
  errors
  |> list.map(profile_schema.error_code)
  |> list.any(fn(code) { code == "required" })
  |> should.equal(True)
}

pub fn schema_rejects_invalid_enum_test() {
  let assert Ok(contents) =
    simplifile.read(
      from: "test/fixtures/source_local/profiles_invalid/invalid_enum.json",
    )

  let assert Ok(value) = json.parse(contents, decode.dynamic)

  let assert Error(errors) = profile_schema.validate_profile(value)
  let codes = errors |> list.map(profile_schema.error_code)
  codes
  |> list.any(fn(code) { code == "enum" })
  |> should.equal(True)
  codes
  |> list.any(fn(code) { code == "pattern" })
  |> should.equal(True)
}
