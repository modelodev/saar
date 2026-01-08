import gleam/dict.{type Dict}
import gleam/json.{type Json}
import gleam/option.{type Option}
import sad/types/core
import sad/types/enums

pub type ResponseData {
  ResponseData(content: Option(String), metadata: Dict(String, Json))
}

pub type PublicArtifact {
  PublicArtifact(
    id: core.ArtifactId,
    name: String,
    url: Option(String),
    mime: String,
  )
}

pub type InteractionResult {
  InteractionResult(
    data: ResponseData,
    artifacts: List(PublicArtifact),
    trace_id: core.TraceId,
  )
}

pub type InteractionError {
  InteractionError(
    kind: enums.ErrorKind,
    message: String,
    trace_id: core.TraceId,
  )
}
