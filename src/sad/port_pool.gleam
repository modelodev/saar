import gleam/dict
import gleam/list
import gleam/option
import sad/types/core as types_core

pub type PortPoolError {
  InvalidRange
  PoolExhausted
}

pub type PortPool {
  PortPool(
    min_port: Int,
    max_port: Int,
    reservations: dict.Dict(types_core.InstanceId, Int),
  )
}

pub fn init(min_port: Int, max_port: Int) -> Result(PortPool, PortPoolError) {
  case min_port > 0 && max_port >= min_port {
    True -> Ok(PortPool(min_port, max_port, dict.new()))
    False -> Error(InvalidRange)
  }
}

pub fn allocate(
  pool: PortPool,
  instance_id: types_core.InstanceId,
) -> Result(#(PortPool, Int), PortPoolError) {
  let PortPool(min_port, max_port, reservations) = pool

  case dict.get(reservations, instance_id) {
    Ok(port) -> Ok(#(pool, port))
    Error(_) ->
      case find_free_port(min_port, max_port, reservations) {
        option.Some(port) -> {
          let updated = dict.insert(reservations, instance_id, port)
          Ok(#(PortPool(min_port, max_port, updated), port))
        }
        option.None -> Error(PoolExhausted)
      }
  }
}

pub fn release(pool: PortPool, instance_id: types_core.InstanceId) -> PortPool {
  let PortPool(min_port, max_port, reservations) = pool
  let updated = dict.delete(reservations, instance_id)
  PortPool(min_port, max_port, updated)
}

fn find_free_port(
  min_port: Int,
  max_port: Int,
  reservations: dict.Dict(types_core.InstanceId, Int),
) -> option.Option(Int) {
  find_free_port_from(min_port, max_port, reservations)
}

fn find_free_port_from(
  current: Int,
  max_port: Int,
  reservations: dict.Dict(types_core.InstanceId, Int),
) -> option.Option(Int) {
  case current > max_port {
    True -> option.None
    False ->
      case is_port_reserved(reservations, current) {
        True -> find_free_port_from(current + 1, max_port, reservations)
        False -> option.Some(current)
      }
  }
}

fn is_port_reserved(
  reservations: dict.Dict(types_core.InstanceId, Int),
  port: Int,
) -> Bool {
  reservations
  |> dict.to_list
  |> list.any(fn(reservation) {
    let #(_, reserved_port) = reservation
    reserved_port == port
  })
}
