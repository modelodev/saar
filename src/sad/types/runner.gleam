import gleam/dict.{type Dict}
import gleam/json.{type Json}
import gleam/option.{type Option, None}
import sad/types/enums

pub type RunnerStatus {
  StatusSuccess
  StatusError
}

pub type RunnerError {
  RunnerError(kind: enums.ErrorKind, message: String)
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

pub type ToolConfig {
  ToolConfigPackage(package: String, command: String, with_packages: List(String))
  ToolConfigScript(script: String)
}

pub type NetworkMode {
  ManagedPort
  NoNetwork
}

pub fn network_mode_from_string(s: String) -> Result(NetworkMode, String) {
  case s {
    "managed_port" -> Ok(ManagedPort)
    "no_network" -> Ok(NoNetwork)
    other ->
      Error(
        "Unknown network mode: '"
        <> other
        <> "'. Valid: managed_port, no_network",
      )
  }
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

pub fn default_artifact_config() -> ArtifactConfig {
  ArtifactConfig([], [])
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
