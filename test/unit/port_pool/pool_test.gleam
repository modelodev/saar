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

fn instance_id(value: String) -> types_core.InstanceId {
  let assert Ok(id) = types_core.instance_id(value)
  id
}

pub fn main() {
  gleeunit.main()
}

pub fn port_pool_allocate_returns_port_test() {
  let pool0 = new_pool(9000, 9002)
  let instance = instance_id("inst-1")

  let assert Ok(result1) = port_pool.allocate(pool0, instance)
  let #(pool1, port) = result1
  port |> should.equal(9000)

  let assert Ok(result2) = port_pool.allocate(pool1, instance)
  let #(_, same_port) = result2
  same_port |> should.equal(9000)
}

pub fn port_pool_allocate_checked_returns_port_test() {
  let pool0 = new_pool(9050, 9052)
  let instance = instance_id("inst-1")
  let check_ok = fn(_port) { Ok(Nil) }

  let assert Ok(result1) = port_pool.allocate_checked(pool0, instance, check_ok)
  let #(_, port) = result1
  port |> should.equal(9050)
}

pub fn port_pool_allocate_checked_skips_in_use_test() {
  let pool0 = new_pool(9060, 9061)
  let instance = instance_id("inst-1")

  let check = fn(port) {
    case port == 9060 {
      True -> Error(port_pool.CheckPortInUse)
      False -> Ok(Nil)
    }
  }

  let assert Ok(result1) = port_pool.allocate_checked(pool0, instance, check)
  let #(_, port) = result1
  port |> should.equal(9061)
}

pub fn port_pool_allocate_checked_port_in_use_error_test() {
  let pool0 = new_pool(9070, 9070)
  let instance = instance_id("inst-1")
  let check_in_use = fn(_port) { Error(port_pool.CheckPortInUse) }

  port_pool.allocate_checked(pool0, instance, check_in_use)
  |> should.equal(Error(port_pool.PortInUse))
}

pub fn port_pool_allocate_checked_no_available_after_retries_test() {
  let pool0 = new_pool(9080, 9081)
  let instance = instance_id("inst-1")
  let check_in_use = fn(_port) { Error(port_pool.CheckPortInUse) }

  port_pool.allocate_checked(pool0, instance, check_in_use)
  |> should.equal(Error(port_pool.NoAvailablePortAfterRetries(2)))
}

pub fn port_pool_allocate_checked_bind_check_failed_test() {
  let pool0 = new_pool(9090, 9091)
  let instance = instance_id("inst-1")
  let check_failed = fn(_port) { Error(port_pool.CheckBindFailed("bind failed")) }

  port_pool.allocate_checked(pool0, instance, check_failed)
  |> should.equal(Error(port_pool.BindCheckFailed("bind failed")))
}

pub fn port_pool_allocate_checked_pool_exhausted_test() {
  let pool0 = new_pool(9100, 9100)

  let assert Ok(result1) =
    port_pool.allocate(pool0, instance_id("inst-1"))
  let #(pool1, _) = result1

  let check_ok = fn(_port) { Ok(Nil) }

  port_pool.allocate_checked(pool1, instance_id("inst-2"), check_ok)
  |> should.equal(Error(port_pool.PoolExhausted))
}

pub fn port_pool_allocate_unique_test() {
  let pool0 = new_pool(9000, 9001)

  let assert Ok(result1) =
    port_pool.allocate(pool0, instance_id("inst-1"))
  let #(pool1, first) = result1

  let assert Ok(result2) =
    port_pool.allocate(pool1, instance_id("inst-2"))

  case result2 {
    #(_pool2, second) -> {
      let equal = first == second
      equal |> should.equal(False)
    }
  }
}

pub fn port_pool_release_frees_port_test() {
  let pool0 = new_pool(9000, 9001)
  let instance = instance_id("inst-1")

  let assert Ok(result1) = port_pool.allocate(pool0, instance)
  let #(pool1, first) = result1

  let pool2 = port_pool.release(pool1, instance)
  let assert Ok(result2) =
    port_pool.allocate(pool2, instance_id("inst-2"))
  let #(_, reused) = result2

  reused |> should.equal(first)
}

pub fn port_pool_reuse_after_release_test() {
  let pool0 = new_pool(9100, 9101)
  let instance = instance_id("inst-1")

  let assert Ok(result1) = port_pool.allocate(pool0, instance)
  let #(pool1, first) = result1

  let pool2 = port_pool.release(pool1, instance)
  let assert Ok(result2) =
    port_pool.allocate(pool2, instance_id("inst-2"))
  let #(_, reused) = result2

  reused |> should.equal(first)
}

pub fn port_pool_respects_range_test() {
  let min_port = 9200
  let max_port = 9202
  let pool0 = new_pool(min_port, max_port)

  let assert Ok(result1) =
    port_pool.allocate(pool0, instance_id("inst-1"))
  let #(pool1, first) = result1

  let assert Ok(result2) =
    port_pool.allocate(pool1, instance_id("inst-2"))
  let #(pool2, second) = result2

  let assert Ok(result3) =
    port_pool.allocate(pool2, instance_id("inst-3"))
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
    port_pool.allocate(pool0, instance_id("inst-1"))
  let #(pool1, _) = result1

  port_pool.allocate(pool1, instance_id("inst-2"))
  |> should.equal(Error(port_pool.PoolExhausted))
}

pub fn port_pool_concurrent_allocate_test() {
  let pool0 = new_pool(9400, 9405)
  let instances = ["a", "b", "c", "d", "e", "f"]

  let #(_, ports) =
    list.fold(instances, #(pool0, []), fn(acc, instance) {
      let #(pool, ports) = acc
      let assert Ok(result) =
        port_pool.allocate(pool, instance_id(instance))
      let #(next_pool, port) = result
      #(next_pool, [port, ..ports])
    })

  let unique =
    ports
    |> list.fold(dict.new(), fn(acc, port) { dict.insert(acc, port, True) })
    |> dict.size

  unique |> should.equal(list.length(ports))
}
