import gleeunit
import gleeunit/should
import gleam/string
import sad/net/port_check
import sad/net/tcp_listener
import sad/port_pool

const host = "127.0.0.1"

fn is_eperm_reason(reason: String) -> Bool {
  reason
  |> string.lowercase
  |> string.contains("eperm")
}

pub fn main() {
  gleeunit.main()
}

pub fn port_check_reports_in_use_test() {
  case tcp_listener.listen(host, 0) {
    Error(tcp_listener.ListenFailed(reason)) ->
      case is_eperm_reason(reason) {
        True -> Nil
        False ->
          panic as { "Expected Ok, got Error: " <> string.inspect(reason) }
      }
    Error(tcp_listener.ListenInUse) ->
      panic as "Expected Ok, got Error: ListenInUse"
    Ok(#(listener, port)) -> {
      let result = port_check.check_available(host, port)

      tcp_listener.close(listener)

      case result {
        Error(port_pool.CheckBindFailed(reason)) ->
          case is_eperm_reason(reason) {
            True -> Nil
            False -> result |> should.equal(Error(port_pool.CheckPortInUse))
          }
        _ -> result |> should.equal(Error(port_pool.CheckPortInUse))
      }
    }
  }
}

pub fn port_check_reports_available_test() {
  let result = port_check.check_available(host, 0)

  case result {
    Error(port_pool.CheckBindFailed(reason)) ->
      case is_eperm_reason(reason) {
        True -> Nil
        False -> result |> should.equal(Ok(Nil))
      }
    _ -> result |> should.equal(Ok(Nil))
  }
}

pub fn port_check_invalid_host_returns_bind_failed_test() {
  case port_check.check_available("invalid_host", 12345) {
    Error(port_pool.CheckBindFailed(_)) -> Nil
    other -> panic as { "Expected bind failed, got " <> string.inspect(other) }
  }
}
