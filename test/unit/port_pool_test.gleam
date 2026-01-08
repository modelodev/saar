import gleam/dict
import gleam/list
import gleeunit
import gleeunit/should
import sad/port_pool
import sad/types/core as types_core

pub fn main() {
  gleeunit.main()
}

pub fn port_pool_allocate_returns_port_test() {
  let pool = new_pool(9000, 9002)
  let instance = types_core.instance_id("inst-1")

  let assert Ok(#(pool, port)) = port_pool.allocate(pool, instance)
  port |> should.equal(9000)

  let assert Ok(#(_, same_port)) = port_pool.allocate(pool, instance)
  same_port |> should.equal(9000)
}

pub fn port_pool_allocate_unique_test() {
  let pool = new_pool(9000, 9001)

  let assert Ok(#(pool, first)) =
    port_pool.allocate(pool, types_core.instance_id("inst-1"))
  let assert Ok(#(_, second)) =
    port_pool.allocate(pool, types_core.instance_id("inst-2"))

  (first == second)
  |> should.equal(False)
}

pub fn port_pool_release_frees_port_test() {
  let pool = new_pool(9000, 9001)
  let instance = types_core.instance_id("inst-1")

  let assert Ok(#(pool, first)) = port_pool.allocate(pool, instance)
  let pool = port_pool.release(pool, instance)
  let assert Ok(#(_, reused)) =
    port_pool.allocate(pool, types_core.instance_id("inst-2"))

  reused |> should.equal(first)
}

pub fn port_pool_reuse_after_release_test() {
  let pool = new_pool(9100, 9101)
  let instance = types_core.instance_id("inst-1")

  let assert Ok(#(pool, first)) = port_pool.allocate(pool, instance)
  let pool = port_pool.release(pool, instance)
  let assert Ok(#(_, reused)) =
    port_pool.allocate(pool, types_core.instance_id("inst-2"))

  reused |> should.equal(first)
}

pub fn port_pool_respects_range_test() {
  let min_port = 9200
  let max_port = 9202
  let pool = new_pool(min_port, max_port)

  let assert Ok(#(pool, first)) =
    port_pool.allocate(pool, types_core.instance_id("inst-1"))
  let assert Ok(#(pool, second)) =
    port_pool.allocate(pool, types_core.instance_id("inst-2"))
  let assert Ok(#(_, third)) =
    port_pool.allocate(pool, types_core.instance_id("inst-3"))

  let ports = [first, second, third]

  ports
  |> list.all(fn(port) { port >= min_port && port <= max_port })
  |> should.equal(True)
}

pub fn port_pool_requires_explicit_range_test() {
  port_pool.init(0, 10)
  |> should.equal(Error(port_pool.InvalidRange))

  port_pool.init(10, 9)
  |> should.equal(Error(port_pool.InvalidRange))
}

pub fn port_pool_exhausted_error_test() {
  let pool = new_pool(9300, 9300)

  let assert Ok(#(pool, _)) =
    port_pool.allocate(pool, types_core.instance_id("inst-1"))

  port_pool.allocate(pool, types_core.instance_id("inst-2"))
  |> should.equal(Error(port_pool.PoolExhausted))
}

pub fn port_pool_concurrent_allocate_test() {
  let pool = new_pool(9400, 9405)
  let instances = ["a", "b", "c", "d", "e", "f"]

  let #(_, ports) =
    list.fold(instances, #(pool, []), fn(acc, instance) {
      let #(pool, ports) = acc
      let assert Ok(#(pool, port)) =
        port_pool.allocate(pool, types_core.instance_id(instance))
      #(pool, [port, ..ports])
    })

  let unique =
    ports
    |> list.fold(dict.new(), fn(acc, port) { dict.insert(acc, port, True) })
    |> dict.size

  unique |> should.equal(list.length(ports))
}

fn new_pool(min_port: Int, max_port: Int) -> port_pool.PortPool {
  let assert Ok(pool) = port_pool.init(min_port, max_port)
  pool
}
