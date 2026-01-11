//// Interaction output types.
////
//// Mission: define the typed results and errors returned by SAD interactions,
//// including response data, artifact references, and trace correlation.
////
//// Responsibilities:
//// - Provide stable response structures for the API layer.
//// - Keep error classification (`ErrorKind`) explicit and small.
////
//// Non-responsibilities:
//// - HTTP status mapping or JSON encoding details.
//// - Artifact storage implementation.
////
//// Relationships:
//// - Uses ids and secrets from `sad/types/core`.
//// - Uses error enums from `sad/types/enums`.

import gleam/dict.{type Dict}
import gleam/json.{type Json}
import gleam/option.{type Option}
import sad/types/core
import sad/types/enums

/// Primary response payload.
///
/// `content` is optional text output, and `metadata` can carry arbitrary JSON.
pub type ResponseData {
  ResponseData(content: Option(String), metadata: Dict(String, Json))
}

/// Public reference to an artifact produced by an interaction.
///
/// `url` may be absent when the artifact cannot be served publicly.
pub type PublicArtifact {
  PublicArtifact(
    id: core.ArtifactId,
    name: String,
    url: Option(String),
    mime: String,
  )
}

/// Successful interaction result.
///
/// Includes `trace_id` for correlation.
pub type InteractionResult {
  InteractionResult(
    data: ResponseData,
    artifacts: List(PublicArtifact),
    trace_id: core.TraceId,
  )
}

/// Error returned by an interaction.
///
/// `kind` is intended to be stable for clients.
pub type InteractionError {
  InteractionError(
    kind: enums.ErrorKind,
    message: String,
    trace_id: core.TraceId,
  )
}

/// Canonical error type used across SAD.
///
/// This is currently an alias of `InteractionError`.
pub type SadError =
  InteractionError

/// Builds a canonical SAD error.
///
/// Prefer using this function instead of constructing `InteractionError`
/// directly so error creation stays consistent.
pub fn sad_error(
  trace_id: core.TraceId,
  kind: enums.ErrorKind,
  message: String,
) -> SadError {
  InteractionError(kind: kind, message: message, trace_id: trace_id)
}
