//// SAD runtime configuration.
////
//// Mission: define typed configuration records used to boot and tune the SAD
//// service (server, runners, streaming, and sandboxing).
////
//// Responsibilities:
//// - Provide a single, typed configuration surface for the SAD runtime.
//// - Offer sensible defaults via `default_sad_config`.
////
//// Non-responsibilities:
//// - Parsing/reading config sources (env, files, flags).
//// - Performing runtime health checks or IO validation.
////
//// Relationships:
//// - Uses primitives from `sad/types/core` and enums from `sad/types/enums`.
//// - Consumed by SAD bootstrap/server code.

import gleam/option.{type Option}
import sad/types/core
import sad/types/enums

/// Where profiles are loaded from.
///
/// `ProfileSourceDir` loads profiles from a local directory.
/// `ProfileSourceGit` loads profiles from a git repository at a given ref.
pub type ProfileSource {
  ProfileSourceDir(path: String)
  ProfileSourceGit(url: String, ref: Option(String))
}

/// Configuration for server log streaming.
///
/// `batch_byte_size` controls how much data is buffered before flushing.
/// `flush_interval_ms` is the maximum time to wait before emitting a batch.
pub type LogStreamConfig {
  LogStreamConfig(batch_byte_size: Int, flush_interval_ms: Int)
}

/// Configuration for streaming interaction events to clients.
///
/// `push_timeout_ms` bounds how long the server waits when pushing to slow
/// clients.
pub type InteractionStreamConfig {
  InteractionStreamConfig(
    batch_byte_size: Int,
    flush_interval_ms: Int,
    push_timeout_ms: Int,
  )
}

/// IO tuning for runner process communication.
///
/// This is typically used by the wrapper/bridge code that reads runner output.
pub type RunnerIoConfig {
  RunnerIoConfig(read_timeout_ms: Int, max_read_attempts: Int)
}

/// Configuration for the runner wrapper process.
///
/// This controls buffering and polling of the wrapped runner process.
pub type WrapperConfig {
  WrapperConfig(
    read_buffer_bytes: Int,
    control_line_bytes: Int,
    poll_interval_ms: Int,
    post_kill_wait_ms: Int,
  )
}

/// Artifact storage configuration.
///
/// `base_path` is the directory used to store and serve produced artifacts.
pub type ArtifactStoreConfig {
  ArtifactStoreConfig(base_path: String)
}

/// Timeout settings used across SAD.
///
/// All values are in milliseconds.
pub type SadTimeouts {
  SadTimeouts(
    call_timeout_ms: Int,
    status_timeout_ms: Int,
    registry_timeout_ms: Int,
    health_check_timeout_ms: Int,
    shutdown_timeout_ms: Int,
  )
}

/// Size and quota limits used across SAD.
pub type SadLimits {
  SadLimits(
    log_buffer_bytes: Int,
    max_stdout_bytes: Int,
    max_runner_event_bytes: Int,
    max_request_body_bytes: Int,
    max_http_response_bytes: Int,
    max_file_fetch_bytes: Int,
  )
}

/// Profile source configuration.
pub type ProfilesConfig {
  ProfilesConfig(sources: List(ProfileSource), git_cache_dir: String)
}

/// Runner execution and sandbox integration settings.
pub type RunnerSystemConfig {
  RunnerSystemConfig(
    python_bin: String,
    io: RunnerIoConfig,
    wrapper: WrapperConfig,
    port_range_min: Int,
    port_range_max: Int,
    managed_port_host: String,
  )
}

/// Streaming configuration for server responses.
pub type StreamConfig {
  StreamConfig(
    sse_keep_alive_interval_ms: Int,
    log_stream: LogStreamConfig,
    interaction_stream: InteractionStreamConfig,
  )
}

/// Storage-related configuration.
pub type StorageConfig {
  StorageConfig(workspaces_directory: String, artifacts: ArtifactStoreConfig)
}

/// Top-level SAD configuration.
///
/// This record groups related settings (timeouts, limits, runner settings, etc.)
/// into smaller records.
pub type SadConfig {
  SadConfig(
    server_host: String,
    server_port: Int,
    api_key: core.SecretValue,
    timeouts: SadTimeouts,
    profiles: ProfilesConfig,
    runner: RunnerSystemConfig,
    storage: StorageConfig,
    limits: SadLimits,
    stream: StreamConfig,
    landlock_mode: enums.LandlockMode,
  )
}

/// A flattened subset of settings required to execute and read from a runner.
pub type RunnerExecSettings {
  RunnerExecSettings(
    max_runner_event_bytes: Int,
    max_stdout_bytes: Int,
    read_timeout_ms: Int,
    max_read_attempts: Int,
    shutdown_timeout_ms: Int,
    wrapper: WrapperConfig,
  )
}

/// Extracts the runner execution settings from a `SadConfig`.
pub fn runner_exec_settings(cfg: SadConfig) -> RunnerExecSettings {
  let SadConfig(timeouts: timeouts, runner: runner, limits: limits, ..) = cfg

  let SadTimeouts(shutdown_timeout_ms: shutdown_timeout_ms, ..) = timeouts

  let RunnerSystemConfig(io: io, wrapper: wrapper, ..) = runner
  let RunnerIoConfig(
    read_timeout_ms: read_timeout_ms,
    max_read_attempts: max_read_attempts,
  ) = io

  let SadLimits(
    max_stdout_bytes: max_stdout_bytes,
    max_runner_event_bytes: max_runner_event_bytes,
    ..,
  ) = limits

  RunnerExecSettings(
    max_runner_event_bytes: max_runner_event_bytes,
    max_stdout_bytes: max_stdout_bytes,
    read_timeout_ms: read_timeout_ms,
    max_read_attempts: max_read_attempts,
    shutdown_timeout_ms: shutdown_timeout_ms,
    wrapper: wrapper,
  )
}

/// Returns the host/port pair used to bind the server.
pub fn server_address(cfg: SadConfig) -> #(String, Int) {
  let SadConfig(server_host: host, server_port: port, ..) = cfg
  #(host, port)
}

/// Returns the default configuration used by the SAD server.
///
/// Example:
/// ```gleam
/// import sad/types/config
///
/// let cfg = config.default_sad_config()
/// ```
pub fn default_sad_config() -> SadConfig {
  SadConfig(
    server_host: "0.0.0.0",
    server_port: 8080,
    api_key: core.secret_value(""),
    timeouts: SadTimeouts(
      call_timeout_ms: 30_000,
      status_timeout_ms: 5000,
      registry_timeout_ms: 5000,
      health_check_timeout_ms: 10_000,
      shutdown_timeout_ms: 10_000,
    ),
    profiles: ProfilesConfig(
      sources: [ProfileSourceDir(path: ".")],
      git_cache_dir: "./.sad/cache/git",
    ),
    runner: RunnerSystemConfig(
      python_bin: "python3",
      io: RunnerIoConfig(read_timeout_ms: 200, max_read_attempts: 200),
      wrapper: WrapperConfig(
        read_buffer_bytes: 4096,
        control_line_bytes: 262_144,
        poll_interval_ms: 50,
        post_kill_wait_ms: 200,
      ),
      port_range_min: 9000,
      port_range_max: 9999,
      managed_port_host: "127.0.0.1",
    ),
    storage: StorageConfig(
      workspaces_directory: "./workspaces",
      artifacts: ArtifactStoreConfig(base_path: "/artifacts/"),
    ),
    limits: SadLimits(
      log_buffer_bytes: 1_048_576,
      max_stdout_bytes: 10_485_760,
      max_runner_event_bytes: 262_144,
      max_request_body_bytes: 1_048_576,
      max_http_response_bytes: 10_485_760,
      max_file_fetch_bytes: 52_428_800,
    ),
    stream: StreamConfig(
      sse_keep_alive_interval_ms: 15_000,
      log_stream: LogStreamConfig(batch_byte_size: 4096, flush_interval_ms: 50),
      interaction_stream: InteractionStreamConfig(
        batch_byte_size: 4096,
        flush_interval_ms: 25,
        push_timeout_ms: 250,
      ),
    ),
    landlock_mode: enums.LandlockBestEffort,
  )
}
