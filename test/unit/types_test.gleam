import gleeunit
import gleeunit/should
import sad/types

pub fn main() {
  gleeunit.main()
}

pub fn error_kind_roundtrip_test() {
  types.error_kind_to_string(types.AgentError)
  |> types.error_kind_from_string
  |> should.equal(Ok(types.AgentError))

  types.error_kind_to_string(types.InfraError)
  |> types.error_kind_from_string
  |> should.equal(Ok(types.InfraError))

  types.error_kind_to_string(types.BadRequest)
  |> types.error_kind_from_string
  |> should.equal(Ok(types.BadRequest))
}

pub fn lifecycle_roundtrip_test() {
  types.lifecycle_to_string(types.Transient)
  |> types.lifecycle_from_string
  |> should.equal(Ok(types.Transient))

  types.lifecycle_to_string(types.Continuous)
  |> types.lifecycle_from_string
  |> should.equal(Ok(types.Continuous))
}

pub fn secret_redaction_test() {
  types.secret_value("super-secret")
  |> types.secret_inspect
  |> should.equal("***REDACTED***")
}

pub fn id_roundtrip_test() {
  let profile = types.profile_id("profile-1")
  types.profile_id_to_string(profile)
  |> should.equal("profile-1")

  let instance = types.instance_id("instance-1")
  types.instance_id_to_string(instance)
  |> should.equal("instance-1")

  let trace = types.trace_id("trace-1")
  types.trace_id_to_string(trace)
  |> should.equal("trace-1")
}

pub fn default_config_invariants_test() {
  let types.SadConfig(
    server_host: server_host,
    server_port: server_port,
    api_key: api_key,
    call_timeout_ms: call_timeout_ms,
    status_timeout_ms: status_timeout_ms,
    registry_timeout_ms: registry_timeout_ms,
    health_check_timeout_ms: health_check_timeout_ms,
    shutdown_timeout_ms: shutdown_timeout_ms,
    profiles_sources: profiles_sources,
    profiles_git_cache_dir: profiles_git_cache_dir,
    runners_python_bin: runners_python_bin,
    workspaces_directory: workspaces_directory,
    log_buffer_bytes: log_buffer_bytes,
    max_stdout_bytes: max_stdout_bytes,
    max_runner_event_bytes: max_runner_event_bytes,
    max_request_body_bytes: max_request_body_bytes,
    max_http_response_bytes: max_http_response_bytes,
    max_file_fetch_bytes: max_file_fetch_bytes,
    port_range_min: port_range_min,
    port_range_max: port_range_max,
    sse_keep_alive_interval_ms: sse_keep_alive_interval_ms,
    log_stream: log_stream,
    interaction_stream: interaction_stream,
    managed_port_host: managed_port_host,
  ) = types.default_sad_config()

  server_host |> should.equal("0.0.0.0")
  server_port |> should.equal(8080)
  api_key |> should.equal("")
  call_timeout_ms |> should.equal(30_000)
  status_timeout_ms |> should.equal(5000)
  registry_timeout_ms |> should.equal(5000)
  health_check_timeout_ms |> should.equal(10_000)
  shutdown_timeout_ms |> should.equal(10_000)
  profiles_git_cache_dir |> should.equal("./.sad/cache/git")
  runners_python_bin |> should.equal("python3")
  workspaces_directory |> should.equal("./workspaces")
  log_buffer_bytes |> should.equal(1_048_576)
  max_stdout_bytes |> should.equal(10_485_760)
  max_runner_event_bytes |> should.equal(262_144)
  max_request_body_bytes |> should.equal(1_048_576)
  max_http_response_bytes |> should.equal(10_485_760)
  max_file_fetch_bytes |> should.equal(52_428_800)
  port_range_min |> should.equal(9000)
  port_range_max |> should.equal(9999)
  sse_keep_alive_interval_ms |> should.equal(15_000)
  managed_port_host |> should.equal("127.0.0.1")

  profiles_sources
  |> should.equal([types.ProfileSourceDir(path: ".")])

  let types.LogStreamConfig(
    batch_byte_size: log_batch_byte_size,
    flush_interval_ms: log_flush_interval_ms,
  ) = log_stream

  log_batch_byte_size |> should.equal(4096)
  log_flush_interval_ms |> should.equal(50)

  let types.InteractionStreamConfig(
    batch_byte_size: interaction_batch_byte_size,
    flush_interval_ms: interaction_flush_interval_ms,
    push_timeout_ms: interaction_push_timeout_ms,
  ) = interaction_stream

  interaction_batch_byte_size |> should.equal(4096)
  interaction_flush_interval_ms |> should.equal(25)
  interaction_push_timeout_ms |> should.equal(250)
}
