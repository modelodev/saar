import gleam/dict.{type Dict}
import gleam/option.{type Option}
import sad/types/core
import sad/types/enums
import sad/types/runner
import sad/types as types

pub type ChatMessage {
  ChatMessage(role: String, content: String)
}

pub type FileRef {
  FileRef(url: String, mime: String, name: String, context: Option(String))
}

pub type InputValue =
  core.Value

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

pub type SadHelpers {
  SadHelpers(last_user_content: Option(String), last_user_files: List(FileRef))
}

pub type RequestContext {
  RequestContext(trace_id: core.TraceId, extra: Dict(String, String))
}

pub type SadInputMeta {
  SadInputMeta(
    spec_version: String,
    profile_id: core.ProfileId,
    instance_id: Option(core.InstanceId),
    mode: enums.Lifecycle,
  )
}

pub type ResolvedParams =
  types.ResolvedParams

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
