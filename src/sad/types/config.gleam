import gleam/option.{type Option}
import sad/types/core
import sad/types/enums

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

pub type RunnerIoConfig {
  RunnerIoConfig(read_timeout_ms: Int, max_read_attempts: Int)
}

pub type WrapperConfig {
  WrapperConfig(
    read_buffer_bytes: Int,
    poll_interval_ms: Int,
    post_kill_wait_ms: Int,
  )
}

pub type ArtifactStoreConfig {
  ArtifactStoreConfig(base_path: String)
}

pub type SadConfig {
  SadConfig(
    server_host: String,
    server_port: Int,
    api_key: core.SecretValue,
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
    runner_io: RunnerIoConfig,
    wrapper: WrapperConfig,
    artifacts: ArtifactStoreConfig,
    managed_port_host: String,
    landlock_mode: enums.LandlockMode,
  )
}

pub fn default_sad_config() -> SadConfig {
  SadConfig(
    server_host: "0.0.0.0",
    server_port: 8080,
    api_key: core.secret_value(""),
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
    runner_io: RunnerIoConfig(read_timeout_ms: 200, max_read_attempts: 200),
    wrapper: WrapperConfig(
      read_buffer_bytes: 4096,
      poll_interval_ms: 50,
      post_kill_wait_ms: 200,
    ),
    artifacts: ArtifactStoreConfig(base_path: "/artifacts/"),
    managed_port_host: "127.0.0.1",
    landlock_mode: enums.LandlockBestEffort,
  )
}
