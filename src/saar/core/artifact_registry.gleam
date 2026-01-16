////
//// Mission: keep a whitelist of artifacts that can be served to clients.
////
//// Responsibilities:
//// - Generate and store opaque `ArtifactId` values.
//// - Map `ArtifactId` to `ArtifactEntry` metadata.
//// - Purge artifacts deterministically when an instance is deleted.
////
//// Non-responsibilities:
//// - Reading or serving artifact contents.
//// - TTL/GC policies (v0 keeps artifacts until explicit purge).
////
//// Relationships:
//// - Message protocol lives in `saar/core/artifact_registry_protocol.ArtifactRegistryMsg`.
//// - Boundary callers should use `saar/otp/safe_call` with `saar/core/artifact_registry_protocol.ArtifactRegistryMsg`.

import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import saar/core/artifact_registry_protocol
import saar/types/core as types_core
import youid/uuid

/// Starts an unnamed ArtifactRegistry actor.
///
/// This is intended for tests and other local compositions that do not require a
/// globally registered name.
pub fn start_unnamed() -> actor.StartResult(
  process.Subject(artifact_registry_protocol.ArtifactRegistryMsg),
) {
  actor.new(dict.new())
  |> actor.on_message(handle_message)
  |> actor.start
}

pub fn start(
  name: process.Name(artifact_registry_protocol.ArtifactRegistryMsg),
) -> actor.StartResult(
  process.Subject(artifact_registry_protocol.ArtifactRegistryMsg),
) {
  actor.new(dict.new())
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

type State =
  dict.Dict(types_core.ArtifactId, artifact_registry_protocol.ArtifactEntry)

fn handle_message(
  state: State,
  msg: artifact_registry_protocol.ArtifactRegistryMsg,
) -> actor.Next(State, artifact_registry_protocol.ArtifactRegistryMsg) {
  case msg {
    artifact_registry_protocol.RegisterArtifact(
      path,
      mime,
      instance_id,
      reply_to,
    ) -> {
      let id = types_core.artifact_id(uuid.v7_string())
      process.send(reply_to, id)

      actor.continue(dict.insert(
        state,
        id,
        artifact_registry_protocol.ArtifactEntry(
          path: path,
          mime: mime,
          instance_id: instance_id,
        ),
      ))
    }

    artifact_registry_protocol.LookupArtifact(artifact_id, reply_to) -> {
      process.send(reply_to, dict.get(state, artifact_id) |> option.from_result)
      actor.continue(state)
    }

    artifact_registry_protocol.PurgeByInstance(instance_id, reply_to) -> {
      let #(next, removed) = purge(state, instance_id)
      process.send(reply_to, removed)
      actor.continue(next)
    }
  }
}

fn purge(state: State, instance_id: types_core.InstanceId) -> #(State, Int) {
  state
  |> dict.to_list
  |> list.fold(#(dict.new(), 0), fn(acc, item) {
    let #(next, removed) = acc
    let #(artifact_id, entry) = item
    let artifact_registry_protocol.ArtifactEntry(
      instance_id: entry_instance_id,
      ..,
    ) = entry

    case entry_instance_id == instance_id {
      True -> #(next, removed + 1)
      False -> #(dict.insert(next, artifact_id, entry), removed)
    }
  })
}
