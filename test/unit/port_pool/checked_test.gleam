import gleeunit
import gleeunit/should
import sad/port_pool
import sad/port_pool/checked as port_pool_checked
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

pub fn allocate_checked_with_success_test() {
  let pool0 = new_pool(9000, 9001)
  let instance = instance_id("inst-1")

  let check_ok = fn(_port) { Ok(Nil) }
  let use_ok = fn(_port) { Ok("ready") }

  let assert Ok(result) =
    port_pool_checked.allocate_checked_with(pool0, instance, check_ok, use_ok)
  let #(pool1, value) = result
  value |> should.equal("ready")

  let assert Ok(result2) = port_pool.allocate(pool1, instance_id("inst-2"))
  let #(_, port) = result2
  port |> should.equal(9001)
}

pub fn allocate_checked_with_in_use_fails_fast_test() {
  let pool0 = new_pool(9050, 9050)
  let instance = instance_id("inst-1")

  let check_ok = fn(_port) { Ok(Nil) }
  let use_in_use = fn(_port) { Error(port_pool.CheckPortInUse) }

  port_pool_checked.allocate_checked_with(pool0, instance, check_ok, use_in_use)
  |> should.equal(Error(port_pool.PortInUse))
}

pub fn allocate_checked_with_in_use_retries_and_exhausts_test() {
  let pool0 = new_pool(9010, 9011)
  let instance = instance_id("inst-1")

  let check_ok = fn(_port) { Ok(Nil) }
  let use_in_use = fn(_port) { Error(port_pool.CheckPortInUse) }

  port_pool_checked.allocate_checked_with(pool0, instance, check_ok, use_in_use)
  |> should.equal(Error(port_pool.NoAvailablePortAfterRetries(2)))

  let assert Ok(result2) = port_pool.allocate(pool0, instance_id("inst-2"))
  let #(_, port) = result2
  port |> should.equal(9010)
}

pub fn allocate_checked_with_in_use_retries_until_success_test() {
  let pool0 = new_pool(9030, 9031)
  let instance = instance_id("inst-1")

  let check_ok = fn(_port) { Ok(Nil) }

  let use_port = fn(port) {
    case port == 9030 {
      True -> Error(port_pool.CheckPortInUse)
      False -> Ok(port)
    }
  }

  let assert Ok(result) =
    port_pool_checked.allocate_checked_with(pool0, instance, check_ok, use_port)

  let #(pool1, used_port) = result
  used_port |> should.equal(9031)

  let assert Ok(result2) = port_pool.allocate(pool1, instance_id("inst-2"))
  let #(_, next_port) = result2
  next_port |> should.equal(9030)
}

pub fn allocate_checked_with_existing_reservation_does_not_retry_test() {
  let pool0 = new_pool(9040, 9041)
  let instance = instance_id("inst-1")

  let assert Ok(result1) = port_pool.allocate(pool0, instance)
  let #(pool1, port) = result1
  port |> should.equal(9040)

  let check_ok = fn(_port) { Ok(Nil) }
  let use_in_use = fn(_port) { Error(port_pool.CheckPortInUse) }

  port_pool_checked.allocate_checked_with(pool1, instance, check_ok, use_in_use)
  |> should.equal(Error(port_pool.PortInUse))

  let assert Ok(result2) = port_pool.allocate(pool1, instance)
  let #(_, same_port) = result2
  same_port |> should.equal(9040)
}

pub fn allocate_checked_with_bind_failed_test() {
  let pool0 = new_pool(9020, 9020)
  let instance = instance_id("inst-1")

  let check_ok = fn(_port) { Ok(Nil) }
  let use_failed = fn(_port) { Error(port_pool.CheckBindFailed("boom")) }

  port_pool_checked.allocate_checked_with(pool0, instance, check_ok, use_failed)
  |> should.equal(Error(port_pool.BindCheckFailed("boom")))
}
