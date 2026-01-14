//// Register collected artifacts into the artifact registry.
////
//// Mission: take validated, workspace-relative artifacts and register them in the
//// ArtifactRegistry actor so they can be served later.
////
//// Responsibilities:
//// - Call the ArtifactRegistry boundary to assign artifact ids.
//// - Produce `types_output.PublicArtifact` with an URL derived from config.
////
//// Non-responsibilities:
//// - Validating paths or applying glob filtering (handled by `sad/artifacts`).
//// - Serving artifact contents over HTTP (handled by `sad/gateway/artifacts_api`).
////
//// Relationships:
//// - Called by `sad/bridge/interaction` and `sad/bridge/runner`.
//// - Uses `sad/core/boundary_call` and `sad/core/artifact_registry_protocol`.

import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/result
import sad/artifacts
import sad/core/artifact_registry_protocol
import sad/core/boundary_call
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/output as types_output

/// Registers collected artifacts in the ArtifactRegistry.
///
/// Returns a list of public artifacts, each containing an id and a URL.
pub fn register_collected_artifacts(
  config: types_config.SadConfig,
  artifact_registry: process.Subject(
    artifact_registry_protocol.ArtifactRegistryMsg,
  ),
  instance_id: types_core.InstanceId,
  collected: List(artifacts.CollectedArtifact),
  trace_id: types_core.TraceId,
) -> Result(List(types_output.PublicArtifact), types_output.InteractionError) {
  let types_config.SadConfig(timeouts: timeouts, storage: storage, ..) = config
  let types_config.SadTimeouts(call_timeout_ms: call_timeout_ms, ..) = timeouts
  let types_config.StorageConfig(artifacts: artifacts_cfg, ..) = storage
  let types_config.ArtifactStoreConfig(base_path: base_path) = artifacts_cfg

  collected
  |> list.fold(Ok([]), fn(acc, item) {
    use items <- result.try(acc)

    let artifacts.CollectedArtifact(name: name, path: path, mime: mime) = item

    let id_out =
      boundary_call.call(artifact_registry, call_timeout_ms, fn(reply_to) {
        artifact_registry_protocol.RegisterArtifact(
          path,
          mime,
          instance_id,
          reply_to,
        )
      })
      |> result.map_error(fn(_err) {
        types_output.sad_error(
          trace_id,
          types_enums.InfraError,
          "artifact_registry_unavailable",
        )
      })

    use artifact_id <- result.try(id_out)

    let url = base_path <> types_core.artifact_id_to_string(artifact_id)

    Ok([
      types_output.PublicArtifact(
        id: artifact_id,
        name: name,
        url: option.Some(url),
        mime: mime,
      ),
      ..items
    ])
  })
  |> result.map(list.reverse)
}
