// Extracted reference snippet (v0)
// Source: arquitectura/actores.md:1017
// Purpose: documentation-only; may not compile as-is.

// sad/core/registry_api.gleam

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option}
import sad/core/agent.{type AgentRef}
import sad/core/messages.{
  type RegistryError, type RegistryMsg, ListAll, ListByProfile, Lookup, Register,
  Unregister, UnregisterByInstanceId, UpdateStatus,
}
import sad/otp/safe_call
import sad/otp/safe_call.{type ApiCallError, type CallError}
import sad/types.{
  type AgentStatusView, type InstanceId, type InstanceKey, type InstanceSummary,
  type ProfileId, InstanceKey,
}

/// Registra un agente en el registry con status inicial.
/// Falla si ya existe una entrada con la misma clave.
pub fn register(
  registry: Subject(RegistryMsg),
  status: AgentStatusView,
  agent: AgentRef,
  timeout_ms: Int,
) -> Result(Nil, ApiCallError(RegistryError)) {
  safe_call.call_result_within(registry, timeout_ms, fn(reply_to) {
    Register(status, agent, reply_to)
  })
}

/// Elimina un agente del registry.
/// Fire-and-forget: no espera confirmación.
pub fn unregister(registry: Subject(RegistryMsg), key: InstanceKey) -> Nil {
  actor.send(registry, Unregister(key))
}

/// Elimina un agente del registry por instance_id.
/// Fire-and-forget: no espera confirmación.
pub fn unregister_by_instance_id(
  registry: Subject(RegistryMsg),
  instance_id: InstanceId,
) -> Nil {
  actor.send(registry, UnregisterByInstanceId(instance_id))
}

/// Busca un agente por clave.
pub fn lookup(
  registry: Subject(RegistryMsg),
  key: InstanceKey,
  timeout_ms: Int,
) -> Result(Option(AgentRef), CallError) {
  safe_call.call_within(registry, timeout_ms, fn(reply_to) {
    Lookup(key, reply_to)
  })
}

/// Busca un agente por profile_id e instance_id.
/// Convenience wrapper sobre lookup.
pub fn lookup_by_ids(
  registry: Subject(RegistryMsg),
  profile_id: ProfileId,
  instance_id: InstanceId,
  timeout_ms: Int,
) -> Result(Option(AgentRef), CallError) {
  lookup(registry, InstanceKey(profile_id, instance_id), timeout_ms)
}

/// Lista todas las instancias de un perfil.
pub fn list_by_profile(
  registry: Subject(RegistryMsg),
  profile_id: ProfileId,
  timeout_ms: Int,
) -> Result(List(InstanceId), CallError) {
  safe_call.call_within(registry, timeout_ms, fn(reply_to) {
    ListByProfile(profile_id, reply_to)
  })
}

/// Lista todas las instancias registradas.
pub fn list_all(
  registry: Subject(RegistryMsg),
  timeout_ms: Int,
) -> Result(List(InstanceSummary), CallError) {
  safe_call.call_within(registry, timeout_ms, fn(reply_to) { ListAll(reply_to) })
}

/// Actualiza el status cacheado de una instancia.
/// Fire-and-forget: no espera confirmación.
pub fn update_status(
  registry: Subject(RegistryMsg),
  instance_id: InstanceId,
  status: AgentStatusView,
) -> Nil {
  actor.send(registry, UpdateStatus(instance_id, status))
}

/// Cuenta el número de instancias registradas.
pub fn count(
  registry: Subject(RegistryMsg),
  timeout_ms: Int,
) -> Result(Int, CallError) {
  case list_all(registry, timeout_ms) {
    Ok(keys) -> Ok(list.length(keys))
    Error(e) -> Error(e)
  }
}

/// Cuenta las instancias de un perfil específico.
pub fn count_by_profile(
  registry: Subject(RegistryMsg),
  profile_id: ProfileId,
  timeout_ms: Int,
) -> Result(Int, CallError) {
  case list_by_profile(registry, profile_id, timeout_ms) {
    Ok(ids) -> Ok(list.length(ids))
    Error(e) -> Error(e)
  }
}
