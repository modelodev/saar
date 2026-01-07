// Extracted reference snippet (v0)
// Source: arquitectura/tipos.md:13.7
// Purpose: documentation-only; may not compile as-is.

import gleam/erlang/process.{type Subject}
import sad/types.{type InstanceId}
import sad/port_pool.{type PortPoolError}

/// Protocolo de mensajes del PortPoolActor (SSOT de reservas).
pub type PortPoolMsg {
  /// Reserva un puerto para la instancia (único por InstanceId).
  Allocate(instance_id: InstanceId, reply_to: Subject(Result(Int, PortPoolError)))
  /// Libera el puerto reservado por la instancia (idempotente).
  Release(instance_id: InstanceId, reply_to: Subject(Nil))
}

