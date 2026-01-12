import gleam/erlang/process
import gleam/otp/actor
import gleeunit
import gleeunit/should
import sad/core/messages
import sad/core/port_pool_actor
import sad/core/port_pool_api
import sad/net/tcp_listener
import sad/port_pool
import sad/types/core as types_core

pub fn main() {
  gleeunit.main()
}

pub fn port_pool_actor_allocate_returns_port() {
  let port = free_port()
  let pool = start_pool(port, port)
  let instance_id = instance_id("inst-1")

  port_pool_api.allocate(pool, instance_id, 1000)
  |> should.equal(Ok(Ok(port)))
}

pub fn port_pool_actor_allocate_checked_returns_port() {
  let port = free_port()
  let pool = start_pool(port, port)
  let instance_id = instance_id("inst-1")

  port_pool_api.allocate_checked(pool, "127.0.0.1", instance_id, 1000)
  |> should.equal(Ok(Ok(port)))
}

pub fn port_pool_actor_allocate_checked_in_use_error() {
  let #(listener, port) = occupied_port()

  let pool = start_pool(port, port)
  let instance_id = instance_id("inst-1")

  let result =
    port_pool_api.allocate_checked(pool, "127.0.0.1", instance_id, 1000)

  tcp_listener.close(listener)

  result |> should.equal(Ok(Error(port_pool.PortInUse)))
}

pub fn port_pool_actor_release_idempotent() {
  let port = free_port()
  let pool = start_pool(port, port)

  let instance_id = instance_id("inst-1")

  let assert Ok(Ok(_)) = port_pool_api.allocate(pool, instance_id, 1000)

  let assert Ok(Nil) = port_pool_api.release(pool, instance_id, 1000)
  let assert Ok(Nil) = port_pool_api.release(pool, instance_id, 1000)

  Nil
}

pub fn port_pool_actor_exhausted_error() {
  let port = free_port()
  let pool = start_pool(port, port)

  let instance1 = instance_id("inst-1")
  let instance2 = instance_id("inst-2")

  let assert Ok(Ok(_)) = port_pool_api.allocate(pool, instance1, 1000)

  port_pool_api.allocate(pool, instance2, 1000)
  |> should.equal(Ok(Error(port_pool.PoolExhausted)))
}

fn start_pool(
  min_port: Int,
  max_port: Int,
) -> process.Subject(messages.PortPoolMsg) {
  let name = process.new_name("test_port_pool")
  let assert Ok(actor.Started(data: subject, ..)) =
    port_pool_actor.start(name, min_port, max_port)
  subject
}

fn instance_id(raw: String) -> types_core.InstanceId {
  let assert Ok(id) = types_core.instance_id(raw)
  id
}

fn free_port() -> Int {
  let assert Ok(#(listener, port)) = tcp_listener.listen("127.0.0.1", 0)
  tcp_listener.close(listener)
  port
}

fn occupied_port() -> #(tcp_listener.Listener, Int) {
  let assert Ok(#(listener, port)) = tcp_listener.listen("127.0.0.1", 0)
  #(listener, port)
}
