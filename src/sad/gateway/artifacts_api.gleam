//// Artifact download endpoint.
////
//// Mission: serve registered artifacts by opaque id via `GET /artifacts/:artifact_id`.
////
//// Responsibilities:
//// - Resolve `artifact_id` through the `ArtifactRegistry`.
//// - Enforce symlink-safe workspace reads (defence in depth).
//// - Serve files using `simplifile.read_bits` + `mist.Bytes`.
////
//// Non-responsibilities:
//// - Performing artifact registration.
//// - Allowing client-controlled filesystem paths.
////
//// Relationships:
//// - Routed by `sad/gateway/http_server` after authentication.
//// - Uses `sad/otp/safe_call` to talk to the ArtifactRegistry actor.
//// - Delegates path safety to `sad/workspace`.

import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option
import mist

import sad/core/artifact_registry_protocol
import sad/gateway/problem
import sad/otp/safe_call
import sad/types/config as types_config
import sad/types/core as types_core
import sad/workspace
import simplifile

pub type Deps {
  Deps(
    artifact_registry: process.Subject(
      artifact_registry_protocol.ArtifactRegistryMsg,
    ),
  )
}

/// Routes a request under `/artifacts`.
pub fn handle(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
) -> response.Response(mist.ResponseData) {
  let segments = request.path_segments(req)

  case segments {
    ["artifacts", artifact_id] ->
      handle_get(req, cfg, deps, trace_id, artifact_id)
    _ -> problem.not_found(trace_id, req.path)
  }
}

fn handle_get(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  artifact_id_raw: String,
) -> response.Response(mist.ResponseData) {
  case req.method {
    http.Get -> get_artifact(req, cfg, deps, trace_id, artifact_id_raw)
    _ -> empty_response(405)
  }
}

fn get_artifact(
  req: request.Request(mist.Connection),
  cfg: types_config.SadConfig,
  deps: Deps,
  trace_id: types_core.TraceId,
  artifact_id_raw: String,
) -> response.Response(mist.ResponseData) {
  let Deps(artifact_registry: artifact_registry) = deps

  let timeout_ms = call_timeout_ms(cfg)
  let artifact_id = types_core.artifact_id(artifact_id_raw)

  let lookup =
    safe_call.call(artifact_registry, timeout_ms, fn(reply_to) {
      artifact_registry_protocol.LookupArtifact(artifact_id, reply_to)
    })

  case lookup {
    Error(call_err) -> problem.from_call_error(call_err, trace_id, req.path)

    Ok(option.None) -> problem.not_found(trace_id, req.path)

    Ok(option.Some(artifact_registry_protocol.ArtifactEntry(
      path: path,
      mime: mime,
      instance_id: instance_id,
    ))) -> {
      let types_config.SadConfig(storage: storage, ..) = cfg
      let types_config.StorageConfig(workspaces_directory: base_dir, ..) =
        storage

      let root = workspace.workspace_for_instance(base_dir, instance_id)

      case workspace.workspace_path_to_symlink_safe_absolute(root, path) {
        Error(err) -> {
          let _ = err
          problem.not_found(trace_id, req.path)
        }

        Ok(abs_path) ->
          case simplifile.read_bits(abs_path) {
            Error(_) -> problem.not_found(trace_id, req.path)

            Ok(bits) ->
              response.new(200)
              |> response.set_header("content-type", mime)
              |> response.set_header("content-disposition", "attachment")
              |> response.set_header("x-content-type-options", "nosniff")
              |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(bits)))
          }
      }
    }
  }
}

fn call_timeout_ms(cfg: types_config.SadConfig) -> Int {
  let types_config.SadConfig(timeouts: timeouts, ..) = cfg
  let types_config.SadTimeouts(call_timeout_ms: ms, ..) = timeouts
  ms
}

fn empty_response(status: Int) -> response.Response(mist.ResponseData) {
  response.new(status)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}
