////
//// Mission: map core streaming output into native A2UI v0.8 messages.
////
//// Responsibilities:
//// - Build A2UI message objects with exactly one top-level key.
//// - Frame each message as an SSE `data:` event.
////
//// Non-responsibilities:
//// - Interpreting A2UI components or applying any rendering logic.
//// - Emitting terminal events (native A2UI uses connection close as terminal).
////
//// Relationships:
//// - Used by `sad/bridge/interaction` when `X-SAD-UI-Protocol: a2ui/v0.8`.
//// - Uses `sad/sse` for exact SSE framing.

import gleam/json
import sad/sse
import sad/types/core as types_core
import sad/types/stream

/// Builds an A2UI `beginRendering` message.
pub fn begin_rendering(trace_id: types_core.TraceId) -> stream.StreamEvent {
  json.object([
    #(
      "beginRendering",
      json.object([
        #("surfaceId", json.string(types_core.trace_id_to_string(trace_id))),
      ]),
    ),
  ])
  |> json.to_string
  |> sse.line
  |> stream.event
}

/// Builds an A2UI `dataModelUpdate` message.
pub fn data_model_update(
  trace_id: types_core.TraceId,
  delta: String,
) -> stream.StreamEvent {
  json.object([
    #(
      "dataModelUpdate",
      json.object([
        #("surfaceId", json.string(types_core.trace_id_to_string(trace_id))),
        #("delta", json.string(delta)),
      ]),
    ),
  ])
  |> json.to_string
  |> sse.line
  |> stream.event
}
