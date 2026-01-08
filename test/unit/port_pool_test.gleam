import gleam/dict
import gleam/list
import gleeunit
import gleeunit/should
import sad/port_pool
import sad/types/core as types_core

fn new_pool(min_port: Int, max_port: Int) -> port_pool.PortPool {
  let assert Ok(pool) = port_pool.init(min_port, max_port)
  pool
}

pub fn main() {
  gleeunit.main()
}

pub fn port_pool_allocate_returns_port_test() {
  let pool0 = new_pool(9000, 9002)
  let instance = types_core.instance_id("inst-1")

  let assert Ok(result1) = port_pool.allocate(pool0, instance)
  let #(pool1, port) = result1
  port |> should.equal(9000)

  let assert Ok(result2) = port_pool.allocate(pool1, instance)
  let #(_, same_port) = result2
  same_port |> should.equal(9000)
}

pub fn port_pool_allocate_unique_test() {
  let pool0 = new_pool(9000, 9001)

  let assert Ok(result1) =
    port_pool.allocate(pool0, types_core.instance_id("inst-1"))
  let #(pool1, first) = result1

  let assert Ok(result2) =
    port_pool.allocate(pool1, types_core.instance_id("inst-2"))

  case result2 {
    #(_pool2, second) -> {
      let equal = first == second
      equal |> should.equal(False)
    }
  }
}

pub fn port_pool_release_frees_port_test() {
  let pool0 = new_pool(9000, 9001)
  let instance = types_core.instance_id("inst-1")

  let assert Ok(result1) = port_pool.allocate(pool0, instance)
  let #(pool1, first) = result1

  let pool2 = port_pool.release(pool1, instance)
  let assert Ok(result2) =
    port_pool.allocate(pool2, types_core.instance_id("inst-2"))
  let #(_, reused) = result2

  reused |> should.equal(first)
}

pub fn port_pool_reuse_after_release_test() {
  let pool0 = new_pool(9100, 9101)
  let instance = types_core.instance_id("inst-1")

  let assert Ok(result1) = port_pool.allocate(pool0, instance)
  let #(pool1, first) = result1

  let pool2 = port_pool.release(pool1, instance)
  let assert Ok(result2) =
    port_pool.allocate(pool2, types_core.instance_id("inst-2"))
  let #(_, reused) = result2

  reused |> should.equal(first)
}

pub fn port_pool_respects_range_test() {
  let min_port = 9200
  let max_port = 9202
  let pool0 = new_pool(min_port, max_port)

  let assert Ok(result1) =
    port_pool.allocate(pool0, types_core.instance_id("inst-1"))
  let #(pool1, first) = result1

  let assert Ok(result2) =
    port_pool.allocate(pool1, types_core.instance_id("inst-2"))
  let #(pool2, second) = result2

  let assert Ok(result3) =
    port_pool.allocate(pool2, types_core.instance_id("inst-3"))
  let #(_, third) = result3

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
  let pool0 = new_pool(9300, 9300)

  let assert Ok(result1) =
    port_pool.allocate(pool0, types_core.instance_id("inst-1"))
  let #(pool1, _) = result1

  port_pool.allocate(pool1, types_core.instance_id("inst-2"))
  |> should.equal(Error(port_pool.PoolExhausted))
}

pub fn port_pool_concurrent_allocate_test() {
  let pool0 = new_pool(9400, 9405)
  let instances = ["a", "b", "c", "d", "e", "f"]

  let #(_, ports) =
    list.fold(instances, #(pool0, []), fn(acc, instance) {
      let #(pool, ports) = acc
      let assert Ok(result) =
        port_pool.allocate(pool, types_core.instance_id(instance))
      let #(next_pool, port) = result
      #(next_pool, [port, ..ports])
    })

  let unique =
    ports
    |> list.fold(dict.new(), fn(acc, port) { dict.insert(acc, port, True) })
    |> dict.size

  unique |> should.equal(list.length(ports))
}
