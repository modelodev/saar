import gleam/list
import gleam/string
import gleeunit/should

pub fn assert_ok(result: Result(a, e)) -> a {
  case result {
    Ok(v) -> v
    Error(e) -> panic as { "Expected Ok, got Error: " <> string.inspect(e) }
  }
}

pub fn assert_error(result: Result(a, e)) -> e {
  case result {
    Ok(v) -> panic as { "Expected Error, got Ok: " <> string.inspect(v) }
    Error(e) -> e
  }
}

pub fn assert_length(list_to_check: List(a), expected: Int) {
  list.length(list_to_check)
  |> should.equal(expected)
}
