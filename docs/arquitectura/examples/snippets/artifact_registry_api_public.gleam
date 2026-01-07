// Extracted reference snippet (v0)
// Purpose: documentation-only; may not compile as-is.
//
// sad/core/artifact_registry_api.gleam

import gleam/erlang/process.{type Subject}
import sad/otp/safe_call
import sad/otp/safe_call.{type CallError}
import sad/core/messages.{type ArtifactRegistryMsg, RegisterArtifact, LookupArtifact, PurgeByInstance}
import sad/types.{type ArtifactId, type InstanceId, type WorkspacePath}

pub type ArtifactEntry {
  ArtifactEntry(path: WorkspacePath, mime: String, instance_id: InstanceId)
}

/// Registra un artefacto y devuelve su `ArtifactId` opaco.
pub fn register_artifact(
  registry: Subject(ArtifactRegistryMsg),
  path: WorkspacePath,
  mime: String,
  instance_id: InstanceId,
  timeout_ms: Int,
) -> Result(ArtifactId, CallError) {
  safe_call.call_within(registry, timeout_ms, fn(reply_to) {
    RegisterArtifact(path, mime, instance_id, reply_to)
  })
}

/// Lookup para servir `/artifacts/:artifact_id` (borde HTTP).
pub fn lookup_artifact(
  registry: Subject(ArtifactRegistryMsg),
  artifact_id: ArtifactId,
  timeout_ms: Int,
) -> Result(Option(ArtifactEntry), CallError) {
  safe_call.call_within(registry, timeout_ms, fn(reply_to) {
    LookupArtifact(artifact_id, reply_to)
  })
}

/// Purga determinista: se llama en delete y en rollback de delete.
pub fn purge_by_instance(
  registry: Subject(ArtifactRegistryMsg),
  instance_id: InstanceId,
  timeout_ms: Int,
) -> Result(Int, CallError) {
  safe_call.call_within(registry, timeout_ms, fn(reply_to) {
    PurgeByInstance(instance_id, reply_to)
  })
}

