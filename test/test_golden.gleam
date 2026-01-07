import gleam/string
import gleeunit/should

pub fn normalize(input: String) -> String {
  string.replace(input, "\r\n", "\n")
}

pub fn assert_golden(actual: String, expected: String) {
  normalize(actual)
  |> should.equal(normalize(expected))
}
