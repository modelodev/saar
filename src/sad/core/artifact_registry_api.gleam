////
//// Mission: provide a typed API over the `ArtifactRegistryActor` protocol.
////
//// Responsibilities:
//// - Encapsulate message construction.
//// - Ensure timeouts are always explicit.
////
//// Non-responsibilities:
//// - Serving artifact contents.
//// - Applying default timeouts.
////
//// Relationships:
//// - Targets `sad/core/messages.ArtifactRegistryMsg`.
//// - Uses `sad/otp/safe_call.call_within`.

import gleam/erlang/process
import gleam/option.{type Option}
import sad/core/messages
import sad/otp/safe_call
import sad/types/core as types_core
import sad/workspace.{type WorkspacePath}

/// Registers an artifact and returns its opaque id.
pub fn register_artifact(
  registry: process.Subject(messages.ArtifactRegistryMsg),
  path: WorkspacePath,
  mime: String,
  instance_id: types_core.InstanceId,
  timeout_ms: Int,
) -> Result(types_core.ArtifactId, safe_call.CallError) {
  safe_call.call_within(registry, timeout_ms, fn(reply_to) {
    messages.RegisterArtifact(path, mime, instance_id, reply_to)
  })
}

/// Looks up artifact metadata.
pub fn lookup_artifact(
  registry: process.Subject(messages.ArtifactRegistryMsg),
  artifact_id: types_core.ArtifactId,
  timeout_ms: Int,
) -> Result(Option(messages.ArtifactEntry), safe_call.CallError) {
  safe_call.call_within(registry, timeout_ms, fn(reply_to) {
    messages.LookupArtifact(artifact_id, reply_to)
  })
}

/// Purges all artifacts belonging to an instance.
///
/// Returns the number of removed artifacts.
pub fn purge_by_instance(
  registry: process.Subject(messages.ArtifactRegistryMsg),
  instance_id: types_core.InstanceId,
  timeout_ms: Int,
) -> Result(Int, safe_call.CallError) {
  safe_call.call_within(registry, timeout_ms, fn(reply_to) {
    messages.PurgeByInstance(instance_id, reply_to)
  })
}
