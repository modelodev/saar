//// Artifact registry protocol.
////
//// Mission: define the SSOT message protocol and entry shape used by the
//// ArtifactRegistryActor.
////
//// Responsibilities:
//// - Define `ArtifactEntry` (internal metadata stored per artifact id).
//// - Define `ArtifactRegistryMsg` request/reply messages.
////
//// Non-responsibilities:
//// - Implementing actor behavior or storage.
////
//// Relationships:
//// - Implemented by `sad/core/artifact_registry`.
//// - Called from boundary layers via `sad/otp/safe_call`.

import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import sad/types/core as types_core
import sad/workspace.{type WorkspacePath}

/// Internal artifact registry entry.
pub type ArtifactEntry {
  ArtifactEntry(
    path: WorkspacePath,
    mime: String,
    instance_id: types_core.InstanceId,
  )
}

/// Message protocol for the ArtifactRegistryActor.
pub type ArtifactRegistryMsg {
  RegisterArtifact(
    path: WorkspacePath,
    mime: String,
    instance_id: types_core.InstanceId,
    reply_to: Subject(types_core.ArtifactId),
  )
  LookupArtifact(types_core.ArtifactId, Subject(Option(ArtifactEntry)))
  PurgeByInstance(types_core.InstanceId, Subject(Int))
}
