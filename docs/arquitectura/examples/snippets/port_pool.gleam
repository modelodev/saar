// Extracted reference snippet (v0)
// Source: arquitectura/tipos.md
// Purpose: documentation-only; may not compile as-is.

import gleam/dict.{type Dict}
import gleam/result.{type Result}
import sad/types.{type InstanceId}

pub type PortPoolError {
  InvalidRange
  PoolExhausted
}

pub type PortPool {
  PortPool(
    min_port: Int,
    max_port: Int,
    /// Reservas por instancia (instancia → puerto).
    reservations: Dict(InstanceId, Int),
  )
}

pub fn new(min_port: Int, max_port: Int) -> Result(PortPool, PortPoolError) {
  case min_port > 0 && max_port >= min_port {
    True -> Ok(PortPool(min_port, max_port, dict.new()))
    False -> Error(InvalidRange)
  }
}

/// Reserva un puerto para una instancia.
/// - Idempotente: si la instancia ya tiene puerto, devuelve el mismo puerto.
/// - Si no hay puertos libres, devuelve `PoolExhausted`.
pub fn allocate(pool: PortPool, instance_id: InstanceId) -> Result(#(PortPool, Int), PortPoolError) {
  ...
}

/// Libera el puerto de una instancia.
/// - Idempotente: si no existía reserva, no cambia el pool.
pub fn release(pool: PortPool, instance_id: InstanceId) -> PortPool {
  ...
}

