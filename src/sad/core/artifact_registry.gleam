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
//// - Message protocol lives in `sad/core/messages.ArtifactRegistryMsg`.
//// - Public calls live in `sad/core/artifact_registry_api`.

import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import sad/core/messages
import sad/types/core as types_core
import youid/uuid

pub fn start(
  name: process.Name(messages.ArtifactRegistryMsg),
) -> actor.StartResult(process.Subject(messages.ArtifactRegistryMsg)) {
  actor.new(dict.new())
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

type State =
  dict.Dict(types_core.ArtifactId, messages.ArtifactEntry)

fn handle_message(
  state: State,
  msg: messages.ArtifactRegistryMsg,
) -> actor.Next(State, messages.ArtifactRegistryMsg) {
  case msg {
    messages.RegisterArtifact(path, mime, instance_id, reply_to) -> {
      let id = types_core.artifact_id(uuid.v7_string())
      process.send(reply_to, id)

      actor.continue(dict.insert(
        state,
        id,
        messages.ArtifactEntry(path: path, mime: mime, instance_id: instance_id),
      ))
    }

    messages.LookupArtifact(artifact_id, reply_to) -> {
      process.send(reply_to, dict.get(state, artifact_id) |> option.from_result)
      actor.continue(state)
    }

    messages.PurgeByInstance(instance_id, reply_to) -> {
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
    let messages.ArtifactEntry(instance_id: entry_instance_id, ..) = entry

    case entry_instance_id == instance_id {
      True -> #(next, removed + 1)
      False -> #(dict.insert(next, artifact_id, entry), removed)
    }
  })
}
