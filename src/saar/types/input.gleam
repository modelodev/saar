//// Interaction input types.
////
//// Mission: define the typed inputs accepted by SAAR when invoking a profile,
//// including chat messages, file references, resolved parameters, and request
//// context.
////
//// Responsibilities:
//// - Provide a stable schema for SAAR requests.
//// - Provide small helpers derived from inputs (`derive_helpers`).
////
//// Non-responsibilities:
//// - JSON decoding/validation of incoming requests.
//// - Parameter resolution (see `saar/params`).
////
//// Relationships:
//// - Uses core primitives from `saar/types/core`.
//// - References resolved params via `saar/types/resolved_params`.
//// - References runner definitions via `saar/types/runner`.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import saar/types/core
import saar/types/resolved_params
import saar/types/runner

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
pub type SaarHelpers {
  SaarHelpers(last_user_content: Option(String), last_user_files: List(FileRef))
}

/// Derives `SaarHelpers` from an `InputPayload`.
///
/// This currently extracts the last user message and any attached files.
pub fn derive_helpers(payload: InputPayload) -> SaarHelpers {
  case payload {
    PayloadChat(messages, _) ->
      SaarHelpers(
        last_user_content: last_user_content(messages),
        last_user_files: [],
      )

    PayloadFiles(files) ->
      SaarHelpers(last_user_content: None, last_user_files: files)

    PayloadMixed(messages, files, _) ->
      SaarHelpers(
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
///
/// The lifecycle is encoded by the variant and the instance id is always
/// present.
pub type SaarInputMeta {
  TransientMeta(
    spec_version: String,
    profile_id: core.ProfileId,
    instance_id: core.InstanceId,
  )
  ContinuousMeta(
    spec_version: String,
    profile_id: core.ProfileId,
    instance_id: core.InstanceId,
  )
}

/// Alias for resolved parameter values.
///
/// See `saar/types/resolved_params`.
pub type ResolvedParams =
  resolved_params.ResolvedParams

/// Full, typed input consumed by the SAAR interaction engine.
///
/// This combines metadata, resolved params, the payload, and the selected runner.
pub type SaarInput {
  SaarInput(
    meta: SaarInputMeta,
    params: ResolvedParams,
    input: InputPayload,
    context: RequestContext,
    helpers: Option(SaarHelpers),
    runner_def: runner.Runner,
  )
}
