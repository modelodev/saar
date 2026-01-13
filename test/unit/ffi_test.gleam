import gleam/erlang/port.{type Port}
import gleam/erlang/process
import gleam/string
import gleeunit
import gleeunit/should
import sad/ffi
import test_assertions

pub fn main() {
  gleeunit.main()
}

pub fn ffi_now_ms_monotonic_test() {
  let first = ffi.now_ms()
  process.sleep(1)
  let second = ffi.now_ms()

  case second >= first {
    True -> Nil
    False -> panic as "now_ms moved backwards"
  }
}

pub fn ffi_open_port_binary_mode_test() {
  let port =
    ffi.open_port("/bin/echo", ["hello"], [], ".")
    |> test_assertions.assert_ok

  let result = read_until_message(port, 5)

  case result {
    Ok(ffi.PortDataChunk(line)) -> {
      string.contains(line, "hello") |> should.equal(True)
    }
    Ok(ffi.PortExit(_)) -> panic as "Port exited before emitting line"
    Error(_) -> panic as "Timed out waiting for port data"
  }

  ffi.port_close(port)
}

fn read_until_message(port: Port, attempts: Int) -> Result(ffi.PortMessage, Nil) {
  case attempts {
    0 -> Error(Nil)
    _ ->
      case ffi.port_receive(port, 200) {
        Ok(message) -> Ok(message)
        Error(_) -> read_until_message(port, attempts - 1)
      }
  }
}
