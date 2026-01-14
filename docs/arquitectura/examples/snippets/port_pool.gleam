// Extracted reference snippet (v0)
// Source: arquitectura/tipos.md
// Purpose: documentation-only; may not compile as-is.

import gleam/dict.{type Dict}
import gleam/result.{type Result}
import sad/types.{type InstanceId}

pub type PortPoolError {
  InvalidRange
  PoolExhausted
  PortInUse
  BindCheckFailed(reason: String)
  NoAvailablePortAfterRetries(attempts: Int)
}

pub type PortCheckError {
  CheckPortInUse
  CheckBindFailed(reason: String)
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
/// - El orden de asignación no está garantizado.
/// - Si no hay puertos libres, devuelve `PoolExhausted`.
pub fn allocate(
  pool: PortPool,
  instance_id: InstanceId,
) -> Result(#(PortPool, Int), PortPoolError) {
  todo
}

/// Reserva un puerto solo si `check` confirma que se puede bindear.
/// - El orden de asignación no está garantizado.
/// - Si el pool está lleno, devuelve `PoolExhausted`.
/// - Si todos los candidatos están en uso, devuelve `PortInUse` (1) o `NoAvailablePortAfterRetries`.
/// - Si el check falla de forma no recuperable, devuelve `BindCheckFailed`.
pub fn allocate_checked(
  pool: PortPool,
  instance_id: InstanceId,
  check: fn(Int) -> Result(Nil, PortCheckError),
) -> Result(#(PortPool, Int), PortPoolError) {
  todo
}

/// Libera el puerto de una instancia.
/// - Idempotente: si no existía reserva, no cambia el pool.
pub fn release(pool: PortPool, instance_id: InstanceId) -> PortPool {
  todo
}
