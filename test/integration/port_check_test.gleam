import gleam/string
import gleeunit
import gleeunit/should
import sad/net/port_check
import sad/net/tcp_listener
import sad/port_pool

const host = "127.0.0.1"

pub fn main() {
  gleeunit.main()
}

pub fn port_check_reports_in_use_test() {
  case tcp_listener.listen(host, 0) {
    Error(tcp_listener.ListenPermissionDenied) -> Nil
    Error(tcp_listener.ListenFailed(reason)) ->
      panic as { "Expected Ok, got Error: " <> string.inspect(reason) }
    Error(tcp_listener.ListenInUse) ->
      panic as "Expected Ok, got Error: ListenInUse"
    Error(tcp_listener.ListenInvalidHost(host: _)) ->
      panic as "Expected Ok, got Error: ListenInvalidHost"
    Ok(#(listener, port)) -> {
      let result = port_check.check_available(host, port)

      tcp_listener.close(listener)

      case result {
        Error(port_pool.CheckPermissionDenied) -> Nil
        other -> other |> should.equal(Error(port_pool.CheckPortInUse))
      }
    }
  }
}

pub fn port_check_reports_available_test() {
  let result = port_check.check_available(host, 0)

  case result {
    Error(port_pool.CheckPermissionDenied) -> Nil
    other -> other |> should.equal(Ok(Nil))
  }
}

pub fn port_check_invalid_host_returns_bind_failed_test() {
  case port_check.check_available("invalid_host", 12_345) {
    Error(port_pool.CheckInvalidHost(host: _)) -> Nil
    other -> panic as { "Expected invalid host, got " <> string.inspect(other) }
  }
}
