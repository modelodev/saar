//// Runner protocol types.
////
//// Mission: define the data exchanged with runner implementations, including
//// responses, artifacts, provisioning results, and event streaming.
////
//// Responsibilities:
//// - Provide stable, typed structures for runner events and results.
//// - Provide defaults and string conversions for small runner enums.
////
//// Non-responsibilities:
//// - Executing runners or performing IO.
//// - JSON encoding/decoding of these types.
////
//// Relationships:
//// - Used by wrapper/bridge code that communicates with runners.
//// - Shared with profile definitions (`sad/types/profile`).

import gleam/dict.{type Dict}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import sad/types/enums

/// Coarse runner result status.
pub type RunnerStatus {
  StatusSuccess
  StatusError
}

/// Error information produced by a runner.
pub type RunnerError {
  RunnerError(kind: enums.ErrorKind, message: String)
}

/// Reference to an artifact produced by a runner.
///
/// `path` is typically a runner-local path relative to the workspace.
pub type ArtifactRef {
  ArtifactRef(name: String, path: String, mime: String)
}

/// Final response emitted by a runner for an interaction.
///
/// This type encodes invariants:
/// - `RunnerSuccess` never carries an error.
/// - `RunnerFailure` always carries an error.
pub type RunnerResponse {
  RunnerSuccess(data: Option(Json), artifacts: List(ArtifactRef))
  RunnerFailure(
    error: RunnerError,
    data: Option(Json),
    artifacts: List(ArtifactRef),
  )
}

/// Builds a `RunnerResponse` from raw fields as emitted by a runner.
///
/// This centralizes the invariant mapping from `RunnerStatus` + optional error
/// payload to the `RunnerResponse` ADT.
pub fn runner_response_from_raw(
  status: RunnerStatus,
  data: Option(Json),
  artifacts: List(ArtifactRef),
  error: Option(RunnerError),
) -> RunnerResponse {
  case status, error {
    StatusSuccess, _ -> RunnerSuccess(data: data, artifacts: artifacts)
    StatusError, Some(err) ->
      RunnerFailure(error: err, data: data, artifacts: artifacts)
    StatusError, None ->
      RunnerFailure(
        error: RunnerError(
          kind: enums.InfraError,
          message: "Runner reported status=error without error payload",
        ),
        data: data,
        artifacts: artifacts,
      )
  }
}

/// Result of provisioning the runner environment.
pub type RunnerProvisionResult {
  RunnerProvisionResult(status: RunnerStatus, log_files: List(String))
}

/// Streamed event produced by a runner.
///
/// This is used for logs, streaming text chunks, and final results.
pub type RunnerEvent {
  RunnerEventLog(message: String, level: String)
  RunnerEventChunk(delta: String)
  RunnerEventResult(response: RunnerResponse)
  RunnerEventProvisionResult(result: RunnerProvisionResult)
}

/// How the runner tool is provisioned/executed.
pub type ToolConfig {
  ToolConfigPackage(
    package: String,
    command: String,
    with_packages: List(String),
  )
  ToolConfigScript(script: String)
}

/// Network access mode for a runner.
///
/// - `ManagedPort`: runner can bind a managed port.
/// - `NoNetwork`: no network access.
pub type NetworkMode {
  ManagedPortMode
  NoNetworkMode
}

/// Parses a `NetworkMode` from its string representation.
///
/// Valid values: `managed_port`, `no_network`.
pub fn network_mode_from_string(s: String) -> Result(NetworkMode, String) {
  case s {
    "managed_port" -> Ok(ManagedPortMode)
    "no_network" -> Ok(NoNetworkMode)
    other ->
      Error(
        "Unknown network mode: '"
        <> other
        <> "'. Valid: managed_port, no_network",
      )
  }
}

/// Converts a `NetworkMode` to its stable string representation.
pub fn network_mode_to_string(mode: NetworkMode) -> String {
  case mode {
    ManagedPortMode -> "managed_port"
    NoNetworkMode -> "no_network"
  }
}

/// Runtime configuration passed to the runner.
///
/// `port_env_var` and `host_env_var` name env vars exported when using
/// `ManagedPort`.
pub type RuntimeConfig {
  ManagedPort(host_env_var: Option(String), port_env_var: Option(String))
  NoNetwork
}

/// Returns a safe default runtime configuration.
///
/// Defaults to `NoNetwork`.
pub fn default_runtime_config() -> RuntimeConfig {
  NoNetwork
}

/// Artifact include/exclude patterns for runner output.
pub type ArtifactConfig {
  ArtifactConfig(include: List(String), exclude: List(String))
}

/// Returns the default artifact configuration.
///
/// By default all artifacts are included.
pub fn default_artifact_config() -> ArtifactConfig {
  ArtifactConfig(["**"], [])
}

/// Runner definition used to execute a profile.
///
/// `env_map` and `args` are applied by the wrapper process.
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
