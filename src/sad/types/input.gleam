//// Interaction input types.
////
//// Mission: define the typed inputs accepted by SAD when invoking a profile,
//// including chat messages, file references, resolved parameters, and request
//// context.
////
//// Responsibilities:
//// - Provide a stable schema for SAD requests.
//// - Provide small helpers derived from inputs (`derive_helpers`).
////
//// Non-responsibilities:
//// - JSON decoding/validation of incoming requests.
//// - Parameter resolution (see `sad/params`).
////
//// Relationships:
//// - Uses core primitives from `sad/types/core`.
//// - References resolved params via `sad/types/resolved_params`.
//// - References runner definitions via `sad/types/runner`.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import sad/types/core
import sad/types/enums
import sad/types/resolved_params
import sad/types/runner

/// A single chat message.
///
/// `role` is typically `system`, `user`, or `assistant`.
pub type ChatMessage {
  ChatMessage(role: String, content: String)
}

/// Reference to an input file available to the runner.
///
/// `context` is optional, human-readable context to help the agent.
pub type FileRef {
  FileRef(url: String, mime: String, name: String, context: Option(String))
}

/// Values allowed in `InputPayload.extra_params`.
///
/// This is currently an alias of `core.Value`.
pub type InputValue =
  core.Value

/// The supported input payload shapes.
///
/// - `PayloadChat`: chat-only.
/// - `PayloadFiles`: files-only.
/// - `PayloadMixed`: chat and files.
pub type InputPayload {
  PayloadChat(
    messages: List(ChatMessage),
    extra_params: Dict(String, InputValue),
  )
  PayloadFiles(files: List(FileRef))
  PayloadMixed(
    messages: List(ChatMessage),
    files: List(FileRef),
    extra_params: Dict(String, InputValue),
  )
}

/// Convenience values derived from an `InputPayload`.
///
/// This is optional metadata used by higher-level logic.
pub type SadHelpers {
  SadHelpers(last_user_content: Option(String), last_user_files: List(FileRef))
}

/// Derives `SadHelpers` from an `InputPayload`.
///
/// This currently extracts the last user message and any attached files.
pub fn derive_helpers(payload: InputPayload) -> SadHelpers {
  case payload {
    PayloadChat(messages, _) ->
      SadHelpers(
        last_user_content: last_user_content(messages),
        last_user_files: [],
      )

    PayloadFiles(files) ->
      SadHelpers(last_user_content: None, last_user_files: files)

    PayloadMixed(messages, files, _) ->
      SadHelpers(
        last_user_content: last_user_content(messages),
        last_user_files: files,
      )
  }
}

fn last_user_content(messages: List(ChatMessage)) -> Option(String) {
  messages
  |> list.reverse
  |> list.find(fn(message) { message.role == "user" })
  |> fn(found) {
    case found {
      Ok(message) -> Some(message.content)
      Error(_) -> None
    }
  }
}

/// Per-request context propagated through the system.
///
/// `extra` can carry arbitrary key/value metadata.
pub type RequestContext {
  RequestContext(trace_id: core.TraceId, extra: Dict(String, String))
}

/// Metadata describing the request and profile selection.
pub type SadInputMeta {
  SadInputMeta(
    spec_version: String,
    profile_id: core.ProfileId,
    instance_id: Option(core.InstanceId),
    mode: enums.Lifecycle,
  )
}

/// Alias for resolved parameter values.
///
/// See `sad/types/resolved_params`.
pub type ResolvedParams =
  resolved_params.ResolvedParams

/// Full, typed input consumed by the SAD interaction engine.
///
/// This combines metadata, resolved params, the payload, and the selected runner.
pub type SadInput {
  SadInput(
    meta: SadInputMeta,
    params: ResolvedParams,
    input: InputPayload,
    context: RequestContext,
    helpers: Option(SadHelpers),
    runner_def: runner.Runner,
  )
}
