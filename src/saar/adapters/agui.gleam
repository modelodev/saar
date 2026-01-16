////
//// Mission: map core streaming events into AG-UI v0 SSE payloads.
////
//// Responsibilities:
//// - Translate `StreamEvent` values into the supported AG-UI event set.
//// - Generate `messageId` values and track message phase.
//// - Produce fully formatted SSE frames (including trailing `\n\n`).
////
//// Non-responsibilities:
//// - Writing to sockets or applying backpressure (handled by `saar/streams/*`).
//// - Deciding when an interaction starts/ends (core/bridge responsibility).
////
//// Relationships:
//// - Consumed by `saar/bridge/interaction` for native streaming output.
//// - Uses `saar/sse` for framing.

import gleam/int
import gleam/json
import gleam/option.{None, Some}
import saar/sse
import saar/types/core as types_core
import saar/types/enums as types_enums
import saar/types/output as types_output
import saar/types/stream

/// Generic core stream events required by the AG-UI adapter.
pub type StreamEvent {
  StreamStarted(trace_id: types_core.TraceId)
  ContentChunk(delta: String)
  StreamFinished(
    trace_id: types_core.TraceId,
    artifacts: List(types_output.PublicArtifact),
  )
  StreamError(error: types_output.InteractionError)
}

/// Tracks whether a text message is currently open.
pub type StreamPhase {
  BeforeFirstChunk
  InMessage(message_id: String)
}

/// Adapter state for a single interaction.
pub type AgUiState {
  AgUiState(phase: StreamPhase, next_message_index: Int)
}

/// Returns the initial adapter state.
pub fn new() -> AgUiState {
  AgUiState(phase: BeforeFirstChunk, next_message_index: 1)
}

/// Converts a core `StreamEvent` into 0..N AG-UI SSE frames.
///
/// The returned list contains fully framed SSE payloads ready to be written.
pub fn convert(
  state: AgUiState,
  event: StreamEvent,
) -> #(AgUiState, List(stream.StreamEvent)) {
  let AgUiState(phase: phase, next_message_index: next_message_index) = state

  case event {
    StreamStarted(trace_id) -> {
      let out = [run_started(trace_id)]
      #(state, out)
    }

    ContentChunk(delta) ->
      case phase {
        BeforeFirstChunk -> {
          let message_id = message_id(next_message_index)
          let next_state =
            AgUiState(
              phase: InMessage(message_id),
              next_message_index: next_message_index + 1,
            )

          let out = [
            text_message_start(message_id),
            text_message_content(message_id, delta),
          ]
          #(next_state, out)
        }

        InMessage(message_id) -> {
          let out = [text_message_content(message_id, delta)]
          #(state, out)
        }
      }

    StreamFinished(trace_id, artifacts) ->
      case phase {
        BeforeFirstChunk -> #(
          AgUiState(
            phase: BeforeFirstChunk,
            next_message_index: next_message_index,
          ),
          [run_finished(trace_id, artifacts)],
        )

        InMessage(message_id) -> {
          let next_state =
            AgUiState(
              phase: BeforeFirstChunk,
              next_message_index: next_message_index,
            )

          let out = [
            text_message_end(message_id),
            run_finished(trace_id, artifacts),
          ]
          #(next_state, out)
        }
      }

    StreamError(err) -> {
      let out = [run_error(err.trace_id, err)]
      #(
        AgUiState(
          phase: BeforeFirstChunk,
          next_message_index: next_message_index,
        ),
        out,
      )
    }
  }
}

/// Returns an SSE `data:` frame formatted by `saar/sse.line`.
///
/// This helper exists to keep adapter tests local and explicit.
pub fn to_sse_line_format(payload: String) -> String {
  sse.line(payload)
}

pub fn run_started(trace_id: types_core.TraceId) -> stream.StreamEvent {
  json.object([
    #("type", json.string("RUN_STARTED")),
    #("threadId", json.string(types_core.trace_id_to_string(trace_id))),
    #("runId", json.string(types_core.trace_id_to_string(trace_id))),
  ])
  |> json.to_string
  |> sse.line
  |> stream.event
}

pub fn text_message_start(message_id: String) -> stream.StreamEvent {
  json.object([
    #("type", json.string("TEXT_MESSAGE_START")),
    #("messageId", json.string(message_id)),
    #("role", json.string("assistant")),
  ])
  |> json.to_string
  |> sse.line
  |> stream.event
}

pub fn text_message_content(
  message_id: String,
  delta: String,
) -> stream.StreamEvent {
  json.object([
    #("type", json.string("TEXT_MESSAGE_CONTENT")),
    #("messageId", json.string(message_id)),
    #("delta", json.string(delta)),
  ])
  |> json.to_string
  |> sse.line
  |> stream.event
}

pub fn text_message_end(message_id: String) -> stream.StreamEvent {
  json.object([
    #("type", json.string("TEXT_MESSAGE_END")),
    #("messageId", json.string(message_id)),
  ])
  |> json.to_string
  |> sse.line
  |> stream.event
}

pub fn run_finished(
  trace_id: types_core.TraceId,
  artifacts: List(types_output.PublicArtifact),
) -> stream.StreamEvent {
  json.object([
    #("type", json.string("RUN_FINISHED")),
    #("threadId", json.string(types_core.trace_id_to_string(trace_id))),
    #("runId", json.string(types_core.trace_id_to_string(trace_id))),
    #("artifacts", json.array(artifacts, encode_artifact)),
  ])
  |> json.to_string
  |> sse.line
  |> stream.event
}

pub fn run_error(
  trace_id: types_core.TraceId,
  err: types_output.InteractionError,
) -> stream.StreamEvent {
  json.object([
    #("type", json.string("RUN_ERROR")),
    #("threadId", json.string(types_core.trace_id_to_string(trace_id))),
    #("runId", json.string(types_core.trace_id_to_string(trace_id))),
    #(
      "error",
      json.object([
        #("kind", json.string(types_enums.error_kind_to_string(err.kind))),
        #("message", json.string(err.message)),
        #("trace_id", json.string(types_core.trace_id_to_string(err.trace_id))),
      ]),
    ),
  ])
  |> json.to_string
  |> sse.line
  |> stream.event
}

fn encode_artifact(artifact: types_output.PublicArtifact) -> json.Json {
  json.object([
    #("id", json.string(types_core.artifact_id_to_string(artifact.id))),
    #("name", json.string(artifact.name)),
    #("url", case artifact.url {
      Some(u) -> json.string(u)
      None -> json.null()
    }),
    #("mime", json.string(artifact.mime)),
  ])
}

fn message_id(index: Int) -> String {
  "msg-" <> int.to_string(index)
}
