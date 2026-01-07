import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/option.{type Option, None}
import gleam/string

pub opaque type ProfileId {
  ProfileId(String)
}

pub opaque type InstanceId {
  InstanceId(String)
}

pub opaque type TraceId {
  TraceId(String)
}

pub fn profile_id(s: String) -> ProfileId {
  ProfileId(s)
}

pub fn profile_id_to_string(id: ProfileId) -> String {
  let ProfileId(s) = id
  s
}

pub fn instance_id(s: String) -> InstanceId {
  InstanceId(s)
}

pub fn instance_id_to_string(id: InstanceId) -> String {
  let InstanceId(s) = id
  s
}

pub fn trace_id(s: String) -> TraceId {
  TraceId(s)
}

pub fn trace_id_to_string(id: TraceId) -> String {
  let TraceId(s) = id
  s
}

pub type Value {
  StringVal(String)
  IntVal(Int)
  FloatVal(Float)
  BoolVal(Bool)
  ListVal(List(String))
}

pub type ValueType {
  TypeString
  TypeInt
  TypeFloat
  TypeBool
  TypeList
}

pub fn value_to_string(value: Value) -> String {
  case value {
    StringVal(s) -> s
    IntVal(i) -> int.to_string(i)
    FloatVal(f) -> float.to_string(f)
    BoolVal(True) -> "true"
    BoolVal(False) -> "false"
    ListVal(items) -> string.join(items, ",")
  }
}

pub fn value_type(value: Value) -> ValueType {
  case value {
    StringVal(_) -> TypeString
    IntVal(_) -> TypeInt
    FloatVal(_) -> TypeFloat
    BoolVal(_) -> TypeBool
    ListVal(_) -> TypeList
  }
}

pub opaque type SecretValue {
  SecretValue(inner: String)
}

pub fn secret_value(s: String) -> SecretValue {
  SecretValue(s)
}

pub fn secret_to_env_value(secret: SecretValue) -> String {
  let SecretValue(inner) = secret
  inner
}

pub fn secret_inspect(_secret: SecretValue) -> String {
  "***REDACTED***"
}

pub fn secret_is_empty(secret: SecretValue) -> Bool {
  let SecretValue(inner) = secret
  string.is_empty(inner)
}

pub type LandlockMode {
  LandlockBestEffort
  LandlockEnforced
  LandlockOff
}

pub fn landlock_mode_from_string(s: String) -> Result(LandlockMode, String) {
  case s {
    "best_effort" -> Ok(LandlockBestEffort)
    "enforced" -> Ok(LandlockEnforced)
    "off" -> Ok(LandlockOff)
    other ->
      Error(
        "Unknown landlock mode: '"
        <> other
        <> "'. Valid: best_effort, enforced, off",
      )
  }
}

pub fn landlock_mode_to_string(mode: LandlockMode) -> String {
  case mode {
    LandlockBestEffort -> "best_effort"
    LandlockEnforced -> "enforced"
    LandlockOff -> "off"
  }
}

pub type Lifecycle {
  Transient
  Continuous
}

pub fn lifecycle_to_string(lc: Lifecycle) -> String {
  case lc {
    Transient -> "transient"
    Continuous -> "continuous"
  }
}

pub fn lifecycle_from_string(s: String) -> Result(Lifecycle, String) {
  case s {
    "transient" -> Ok(Transient)
    "continuous" -> Ok(Continuous)
    other ->
      Error(
        "Unknown lifecycle: '" <> other <> "'. Valid: transient, continuous",
      )
  }
}

pub type ErrorKind {
  AgentError
  InfraError
  BadRequest
}

pub fn error_kind_from_string(s: String) -> Result(ErrorKind, String) {
  case s {
    "agent_error" -> Ok(AgentError)
    "infra_error" -> Ok(InfraError)
    "bad_request" -> Ok(BadRequest)
    other ->
      Error(
        "Unknown error kind: '"
        <> other
        <> "'. Valid: agent_error, infra_error, bad_request",
      )
  }
}

pub fn error_kind_to_string(kind: ErrorKind) -> String {
  case kind {
    AgentError -> "agent_error"
    InfraError -> "infra_error"
    BadRequest -> "bad_request"
  }
}

pub type RunnerStatus {
  StatusSuccess
  StatusError
}

pub type RunnerError {
  RunnerError(kind: ErrorKind, message: String)
}

pub type ArtifactRef {
  ArtifactRef(name: String, path: String, mime: String)
}

pub type RunnerResponse {
  RunnerResponse(
    status: RunnerStatus,
    data: Option(Json),
    artifacts: List(ArtifactRef),
    error: Option(RunnerError),
  )
}

pub type RunnerProvisionResult {
  RunnerProvisionResult(status: RunnerStatus, log_files: List(String))
}

pub type RunnerEvent {
  RunnerEventLog(message: String, level: String)
  RunnerEventChunk(delta: String)
  RunnerEventResult(response: RunnerResponse)
  RunnerEventProvisionResult(result: RunnerProvisionResult)
}

pub type ChatMessage {
  ChatMessage(role: String, content: String)
}

pub type FileRef {
  FileRef(url: String, mime: String, name: String, context: Option(String))
}

pub type InputValue =
  Value

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
  RequestContext(trace_id: TraceId, extra: Dict(String, String))
}

pub type SadInputMeta {
  SadInputMeta(
    spec_version: String,
    profile_id: ProfileId,
    instance_id: Option(InstanceId),
    mode: Lifecycle,
  )
}

pub type ResolvedParams =
  Dict(String, String)

pub type ToolConfig {
  ToolConfig(package: String, command: String, with_packages: List(String))
}

pub type NetworkMode {
  ManagedPort
  NoNetwork
}

pub fn network_mode_to_string(mode: NetworkMode) -> String {
  case mode {
    ManagedPort -> "managed_port"
    NoNetwork -> "no_network"
  }
}

pub type RuntimeConfig {
  RuntimeConfig(
    mode: NetworkMode,
    port_env_var: Option(String),
    host_env_var: Option(String),
  )
}

pub fn default_runtime_config() -> RuntimeConfig {
  RuntimeConfig(NoNetwork, None, None)
}

pub type ArtifactConfig {
  ArtifactConfig(include: List(String), exclude: List(String))
}

pub type Runner {
  Runner(
    type_: String,
    tool_config: ToolConfig,
    runtime: RuntimeConfig,
    env_map: Dict(String, String),
    args: List(String),
    artifact_config: ArtifactConfig,
  )
}

pub type SadInput {
  SadInput(
    meta: SadInputMeta,
    params: ResolvedParams,
    input: InputPayload,
    context: RequestContext,
    helpers: Option(SadHelpers),
    runner_def: Runner,
  )
}

pub type ResponseData {
  ResponseData(content: Option(String), metadata: Dict(String, Json))
}

pub type PublicArtifact {
  PublicArtifact(name: String, url: String, mime: String)
}

pub type InteractionResult {
  InteractionResult(
    data: ResponseData,
    artifacts: List(PublicArtifact),
    trace_id: TraceId,
  )
}

pub type InteractionError {
  InteractionError(kind: ErrorKind, message: String, trace_id: TraceId)
}

pub type ProfileSource {
  ProfileSourceDir(path: String)
  ProfileSourceGit(url: String, ref: Option(String))
}

pub type LogStreamConfig {
  LogStreamConfig(batch_byte_size: Int, flush_interval_ms: Int)
}

pub type InteractionStreamConfig {
  InteractionStreamConfig(
    batch_byte_size: Int,
    flush_interval_ms: Int,
    push_timeout_ms: Int,
  )
}

pub type SadConfig {
  SadConfig(
    server_host: String,
    server_port: Int,
    api_key: SecretValue,
    call_timeout_ms: Int,
    status_timeout_ms: Int,
    registry_timeout_ms: Int,
    health_check_timeout_ms: Int,
    shutdown_timeout_ms: Int,
    profiles_sources: List(ProfileSource),
    profiles_git_cache_dir: String,
    runners_python_bin: String,
    workspaces_directory: String,
    log_buffer_bytes: Int,
    max_stdout_bytes: Int,
    max_runner_event_bytes: Int,
    max_request_body_bytes: Int,
    max_http_response_bytes: Int,
    max_file_fetch_bytes: Int,
    port_range_min: Int,
    port_range_max: Int,
    sse_keep_alive_interval_ms: Int,
    log_stream: LogStreamConfig,
    interaction_stream: InteractionStreamConfig,
    managed_port_host: String,
    landlock_mode: LandlockMode,
  )
}

pub fn default_sad_config() -> SadConfig {
  SadConfig(
    server_host: "0.0.0.0",
    server_port: 8080,
    api_key: secret_value(""),
    call_timeout_ms: 30_000,
    status_timeout_ms: 5000,
    registry_timeout_ms: 5000,
    health_check_timeout_ms: 10_000,
    shutdown_timeout_ms: 10_000,
    profiles_sources: [ProfileSourceDir(path: ".")],
    profiles_git_cache_dir: "./.sad/cache/git",
    runners_python_bin: "python3",
    workspaces_directory: "./workspaces",
    log_buffer_bytes: 1_048_576,
    max_stdout_bytes: 10_485_760,
    max_runner_event_bytes: 262_144,
    max_request_body_bytes: 1_048_576,
    max_http_response_bytes: 10_485_760,
    max_file_fetch_bytes: 52_428_800,
    port_range_min: 9000,
    port_range_max: 9999,
    sse_keep_alive_interval_ms: 15_000,
    log_stream: LogStreamConfig(batch_byte_size: 4096, flush_interval_ms: 50),
    interaction_stream: InteractionStreamConfig(
      batch_byte_size: 4096,
      flush_interval_ms: 25,
      push_timeout_ms: 250,
    ),
    managed_port_host: "127.0.0.1",
    landlock_mode: LandlockBestEffort,
  )
}
