// Extracted reference snippet (v0)
// Source: arquitectura/tipos.md:13.7
// Purpose: documentation-only; may not compile as-is.

import gleam/erlang/process.{type Subject}
import saar/port_pool.{type PortPoolError}
import saar/types.{type InstanceId}

/// Protocolo de mensajes del PortPoolActor (SSOT de reservas).
pub type PortPoolMsg {
  /// Reserva un puerto para la instancia (único por InstanceId).
  Allocate(
    instance_id: InstanceId,
    reply_to: Subject(Result(Int, PortPoolError)),
  )
  /// Libera el puerto reservado por la instancia (idempotente).
  Release(instance_id: InstanceId, reply_to: Subject(Nil))
}
