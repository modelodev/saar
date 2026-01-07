import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn smoke_test_passes() {
  True
  |> should.equal(True)
}

pub fn smoke_test_passes_test() {
  smoke_test_passes()
}
