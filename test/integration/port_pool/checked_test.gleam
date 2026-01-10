import gleam/erlang/process
import gleam/string
import gleeunit
import gleeunit/should
import sad/net/port_check
import sad/net/tcp_listener
import sad/port_pool
import sad/port_pool/checked as port_pool_checked
import sad/types/core as types_core
import test_assertions

const host = "127.0.0.1"

fn is_eperm_reason(reason: String) -> Bool {
  reason
  |> string.lowercase
  |> string.contains("eperm")
}

pub fn main() {
  gleeunit.main()
}

fn instance_id(value: String) -> types_core.InstanceId {
  let assert Ok(id) = types_core.instance_id(value)
  id
}

pub fn port_pool_checked_in_use_returns_error_test() {
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
      let pool =
        port_pool.init(port, port)
        |> test_assertions.assert_ok

      let result =
        port_pool_checked.allocate_checked_on_host(
          pool,
          instance_id("inst-1"),
          host,
        )

      tcp_listener.close(listener)

      case result {
        Error(port_pool.BindCheckFailed(reason)) ->
          case is_eperm_reason(reason) {
            True -> Nil
            False -> result |> should.equal(Error(port_pool.PortInUse))
          }
        _ -> result |> should.equal(Error(port_pool.PortInUse))
      }
    }
  }
}

pub fn port_pool_checked_race_fails_fast_test() {
  case tcp_listener.listen(host, 0) {
    Error(tcp_listener.ListenFailed(reason)) ->
      case is_eperm_reason(reason) {
        True -> Nil
        False ->
          panic as { "Expected Ok, got Error: " <> string.inspect(reason) }
      }
    Error(tcp_listener.ListenInUse) ->
      panic as "Expected Ok, got Error: ListenInUse"
    Ok(#(seed_listener, seed_port)) -> {
      tcp_listener.close(seed_listener)

      let pool0 =
        port_pool.init(seed_port, seed_port)
        |> test_assertions.assert_ok

      let ready = process.new_subject()

      let check_with_race = fn(port) {
        process.spawn(fn() {
          let #(listener, _) =
            tcp_listener.listen(host, port)
            |> test_assertions.assert_ok
          process.send(ready, Nil)
          process.sleep(200)
          tcp_listener.close(listener)
        })

        process.receive(ready, within: 1000)
        |> test_assertions.assert_ok

        Ok(Nil)
      }

      let use_port = fn(port) { port_check.check_available(host, port) }

      let result =
        port_pool_checked.allocate_checked_with(
          pool0,
          instance_id("inst-1"),
          check_with_race,
          use_port,
        )

      case result {
        Error(port_pool.BindCheckFailed(reason)) ->
          case is_eperm_reason(reason) {
            True -> Nil
            False -> {
              result |> should.equal(Error(port_pool.PortInUse))

              let assert Ok(result2) =
                port_pool.allocate(pool0, instance_id("inst-2"))
              let #(_, port) = result2
              port |> should.equal(seed_port)
            }
          }
        _ -> {
          result |> should.equal(Error(port_pool.PortInUse))

          let assert Ok(result2) =
            port_pool.allocate(pool0, instance_id("inst-2"))
          let #(_, port) = result2
          port |> should.equal(seed_port)
        }
      }
    }
  }
}
