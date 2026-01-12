import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import gleeunit
import gleeunit/should
import sad/core/artifact_registry
import sad/core/artifact_registry_api
import sad/core/messages
import sad/types/core as types_core
import sad/workspace
import youid/uuid

pub fn main() {
  gleeunit.main()
}

pub fn register_artifact_returns_uuid() {
  let registry = start_registry()
  let assert Ok(instance_id) = types_core.instance_id("inst-1")
  let assert Ok(path) = workspace.workspace_path_validate("out.txt")

  let assert Ok(artifact_id) =
    artifact_registry_api.register_artifact(
      registry,
      path,
      "text/plain",
      instance_id,
      1000,
    )

  let id_s = types_core.artifact_id_to_string(artifact_id)
  id_s |> should.not_equal("")

  let assert Ok(parsed) = uuid.from_string(id_s)
  uuid.version(parsed) |> should.equal(uuid.V7)
}

pub fn register_artifact_stores_workspace_path() {
  let registry = start_registry()
  let assert Ok(instance_id) = types_core.instance_id("inst-1")
  let assert Ok(path) = workspace.workspace_path_validate("out.txt")

  let assert Ok(artifact_id) =
    artifact_registry_api.register_artifact(
      registry,
      path,
      "text/plain",
      instance_id,
      1000,
    )

  let assert Ok(option.Some(entry)) =
    artifact_registry_api.lookup_artifact(registry, artifact_id, 1000)

  let messages.ArtifactEntry(
    path: stored_path,
    mime: stored_mime,
    instance_id: stored_instance_id,
  ) = entry

  workspace.workspace_path_to_string(stored_path)
  |> should.equal(workspace.workspace_path_to_string(path))

  stored_mime |> should.equal("text/plain")
  stored_instance_id |> should.equal(instance_id)
}

pub fn lookup_existing_artifact() {
  register_artifact_stores_workspace_path()
}

pub fn lookup_nonexistent_artifact() {
  let registry = start_registry()
  let artifact_id = types_core.artifact_id(uuid.v7_string())

  artifact_registry_api.lookup_artifact(registry, artifact_id, 1000)
  |> should.equal(Ok(option.None))
}

pub fn purge_by_instance_removes_all() {
  let registry = start_registry()
  let assert Ok(instance_id) = types_core.instance_id("inst-1")
  let assert Ok(path) = workspace.workspace_path_validate("out.txt")

  let assert Ok(a1) =
    artifact_registry_api.register_artifact(
      registry,
      path,
      "text/plain",
      instance_id,
      1000,
    )

  let assert Ok(a2) =
    artifact_registry_api.register_artifact(
      registry,
      path,
      "text/plain",
      instance_id,
      1000,
    )

  artifact_registry_api.purge_by_instance(registry, instance_id, 1000)
  |> should.equal(Ok(2))

  artifact_registry_api.lookup_artifact(registry, a1, 1000)
  |> should.equal(Ok(option.None))

  artifact_registry_api.lookup_artifact(registry, a2, 1000)
  |> should.equal(Ok(option.None))
}

pub fn purge_by_instance_preserves_others() {
  let registry = start_registry()
  let assert Ok(i1) = types_core.instance_id("inst-1")
  let assert Ok(i2) = types_core.instance_id("inst-2")
  let assert Ok(path) = workspace.workspace_path_validate("out.txt")

  let assert Ok(_a1) =
    artifact_registry_api.register_artifact(
      registry,
      path,
      "text/plain",
      i1,
      1000,
    )

  let assert Ok(a2) =
    artifact_registry_api.register_artifact(
      registry,
      path,
      "text/plain",
      i2,
      1000,
    )

  artifact_registry_api.purge_by_instance(registry, i1, 1000)
  |> should.equal(Ok(1))

  let assert Ok(option.Some(_)) =
    artifact_registry_api.lookup_artifact(registry, a2, 1000)

  Nil
}

pub fn concurrent_register_unique_uuids() {
  let registry = start_registry()
  let assert Ok(instance_id) = types_core.instance_id("inst-1")
  let assert Ok(path) = workspace.workspace_path_validate("out.txt")

  let results = process.new_subject()

  let _ =
    list.range(0, 9)
    |> list.each(fn(_) {
      let _ =
        process.spawn(fn() {
          let assert Ok(id) =
            artifact_registry_api.register_artifact(
              registry,
              path,
              "text/plain",
              instance_id,
              1000,
            )
          process.send(results, types_core.artifact_id_to_string(id))
        })
      Nil
    })

  let ids = collect_strings(results, 10, [])

  ids
  |> list.unique
  |> list.length
  |> should.equal(10)
}

fn collect_strings(
  subject: process.Subject(String),
  remaining: Int,
  acc: List(String),
) -> List(String) {
  case remaining {
    0 -> acc
    _ -> {
      let assert Ok(value) = process.receive(subject, 1000)
      collect_strings(subject, remaining - 1, [value, ..acc])
    }
  }
}

fn start_registry() -> process.Subject(messages.ArtifactRegistryMsg) {
  let name = process.new_name("test_artifact_registry")
  let assert Ok(actor.Started(data: subject, ..)) =
    artifact_registry.start(name)
  subject
}
