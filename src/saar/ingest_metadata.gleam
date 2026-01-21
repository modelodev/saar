//// Ingest metadata helpers for file capabilities.
////
//// Mission: build stable ingest metadata payloads for responses.
////
//// Responsibilities:
//// - Derive ingest metadata from `FilesSemantics` and response metadata.
//// - Attach ingest metadata fields to response metadata dictionaries.
//// - Encode and decode ingest payloads stored in request context metadata.
////
//// Non-responsibilities:
//// - Validating file cardinality or profile definitions.
//// - Serializing full HTTP or A2A responses.
////
//// Relationships:
//// - Consumed by gateway handlers and A2A adapters.
//// - Uses `saar/types/profile` for ingest semantics.

import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import saar/json_pointer
import saar/types/output as types_output
import saar/types/profile as types_profile

/// Adds ingest metadata fields to response metadata.
///
/// The resulting metadata includes `ingest_effect`, `max_files`, and `track_id`
/// when the capability accepts files.
pub fn add_ingest_metadata(
  files_semantics: Option(types_profile.FilesSemantics),
  metadata: dict.Dict(String, json.Json),
) -> dict.Dict(String, json.Json) {
  case files_semantics {
    None -> metadata
    Some(types_profile.FilesSemantics(accepts: False, ..)) -> metadata
    Some(types_profile.FilesSemantics(
      max_files: max_files,
      ingest_effect: ingest_effect,
      ..,
    )) -> {
      let track_id = track_id_value(metadata)
      let ingest = ingest_payload(files_semantics, metadata)

      let metadata = case ingest {
        Some(payload) -> dict.insert(metadata, "ingest", payload)
        None -> metadata
      }

      let metadata =
        dict.insert(
          metadata,
          "ingest_effect",
          ingest_effect_json(ingest_effect),
        )
      let metadata = dict.insert(metadata, "max_files", json.int(max_files))

      case dict.has_key(metadata, "track_id") {
        True -> metadata
        False -> dict.insert(metadata, "track_id", track_id)
      }
    }
  }
}

/// Builds an ingest payload for A2A data parts.
pub fn ingest_payload(
  files_semantics: Option(types_profile.FilesSemantics),
  metadata: dict.Dict(String, json.Json),
) -> Option(json.Json) {
  case files_semantics {
    None -> None
    Some(types_profile.FilesSemantics(accepts: False, ..)) -> None
    Some(types_profile.FilesSemantics(
      max_files: max_files,
      ingest_effect: ingest_effect,
      ..,
    )) ->
      Some(
        json.object([
          #("effect", ingest_effect_json(ingest_effect)),
          #("trackId", track_id_value(metadata)),
          #("maxFiles", json.int(max_files)),
        ]),
      )
  }
}

/// Builds context metadata for A2A ingest propagation.
///
/// The returned dict always includes `context_id` and optionally a serialized
/// `ingest_payload` when provided.
pub fn ingest_context_extra(
  context_id: String,
  ingest_payload: Option(json.Json),
) -> dict.Dict(String, String) {
  let base = dict.from_list([#("context_id", context_id)])

  case ingest_payload {
    Some(payload) ->
      dict.insert(base, "ingest_payload", json.to_string(payload))
    None -> base
  }
}

/// Reads an ingest payload from request context metadata.
pub fn ingest_payload_from_context(
  extra: dict.Dict(String, String),
) -> Option(json.Json) {
  case dict.get(extra, "ingest_payload") {
    Ok(payload) ->
      case json.parse(payload, decode.dynamic) {
        Ok(value) -> Some(json_pointer.dynamic_to_json(value))
        Error(_) -> None
      }

    Error(_) -> None
  }
}

/// Attaches ingest metadata to an interaction result.
pub fn attach_ingest_metadata(
  files_semantics: Option(types_profile.FilesSemantics),
  result: types_output.InteractionResult,
) -> types_output.InteractionResult {
  let types_output.InteractionResult(
    data: data,
    artifacts: artifacts,
    trace_id: trace_id,
  ) = result

  let types_output.ResponseData(content: content, metadata: metadata) = data

  let metadata = add_ingest_metadata(files_semantics, metadata)

  types_output.InteractionResult(
    data: types_output.ResponseData(content: content, metadata: metadata),
    artifacts: artifacts,
    trace_id: trace_id,
  )
}

fn ingest_effect_json(effect: Option(types_profile.IngestEffect)) -> json.Json {
  case effect {
    None -> json.null()
    Some(value) -> json.string(types_profile.ingest_effect_to_string(value))
  }
}

fn track_id_value(metadata: dict.Dict(String, json.Json)) -> json.Json {
  case dict.get(metadata, "track_id") {
    Ok(value) -> value
    Error(_) -> json.null()
  }
}
