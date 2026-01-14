import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import sad/bridge/runner_contract
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/resolved_params
import sad/types/runner as types_runner

pub fn main() {
  gleeunit.main()
}

pub fn error_kind_roundtrip_test() {
  types_enums.error_kind_to_string(types_enums.AgentError)
  |> types_enums.error_kind_from_string
  |> should.equal(Ok(types_enums.AgentError))

  types_enums.error_kind_to_string(types_enums.InfraError)
  |> types_enums.error_kind_from_string
  |> should.equal(Ok(types_enums.InfraError))

  types_enums.error_kind_to_string(types_enums.BadRequest)
  |> types_enums.error_kind_from_string
  |> should.equal(Ok(types_enums.BadRequest))
}

pub fn lifecycle_roundtrip_test() {
  types_enums.lifecycle_to_string(types_enums.Transient)
  |> types_enums.lifecycle_from_string
  |> should.equal(Ok(types_enums.Transient))

  types_enums.lifecycle_to_string(types_enums.Continuous)
  |> types_enums.lifecycle_from_string
  |> should.equal(Ok(types_enums.Continuous))
}

pub fn secret_redaction_test() {
  types_core.secret_value("super-secret")
  |> types_core.secret_inspect
  |> should.equal("***REDACTED***")
}

pub fn resolved_value_redacts_secrets_test() {
  resolved_params.SecretVal(types_core.secret_value("super-secret"))
  |> resolved_params.resolved_value_inspect
  |> should.equal("***REDACTED***")
}

pub fn resolved_value_to_env_unwraps_test() {
  resolved_params.NormalValue(types_core.StringVal("hi"))
  |> resolved_params.resolved_value_to_env
  |> should.equal("hi")

  resolved_params.SecretVal(types_core.secret_value("top-secret"))
  |> resolved_params.resolved_value_to_env
  |> should.equal("top-secret")
}

pub fn id_roundtrip_test() {
  let profile = types_core.profile_id("profile-1")
  types_core.profile_id_to_string(profile)
  |> should.equal("profile-1")

  let assert Ok(instance) = types_core.instance_id("instance-1")
  types_core.instance_id_to_string(instance)
  |> should.equal("instance-1")

  let trace = types_core.trace_id("trace-1")
  types_core.trace_id_to_string(trace)
  |> should.equal("trace-1")
}

pub fn instance_id_validation_test() {
  types_core.instance_id("")
  |> should.equal(Error(types_core.EmptyInstanceId))

  types_core.instance_id("bad/1")
  |> should.equal(Error(types_core.InstanceIdInvalidChar("/")))

  let too_long = string.repeat("a", times: 65)
  types_core.instance_id(too_long)
  |> should.equal(Error(types_core.InstanceIdTooLong(max: 64)))
}

pub fn config_value_lookup_test() {
  let cfg = types_config.default_sad_config()

  types_config.config_value(cfg, "server.host")
  |> should.equal(Some(types_core.StringVal("0.0.0.0")))

  types_config.config_value(cfg, "runners.python_bin")
  |> should.equal(Some(types_core.StringVal("python3")))

  types_config.config_value(cfg, "unknown.key")
  |> should.equal(None)
}

pub fn default_config_invariants_test() {
  let types_config.SadConfig(
    server_host: server_host,
    server_port: server_port,
    api_key: api_key,
    timeouts: timeouts,
    profiles: profiles,
    runner: runner_cfg,
    storage: storage,
    limits: limits,
    stream: stream,
    landlock_mode: landlock_mode,
  ) = types_config.default_sad_config()

  let types_config.SadTimeouts(
    call_timeout_ms: call_timeout_ms,
    status_timeout_ms: status_timeout_ms,
    registry_timeout_ms: registry_timeout_ms,
    health_check_timeout_ms: health_check_timeout_ms,
    shutdown_timeout_ms: shutdown_timeout_ms,
  ) = timeouts

  let types_config.ProfilesConfig(
    sources: profiles_sources,
    git_cache_dir: profiles_git_cache_dir,
  ) = profiles

  let types_config.RunnerSystemConfig(
    python_bin: runners_python_bin,
    io: runner_io,
    wrapper: wrapper,
    port_range_min: port_range_min,
    port_range_max: port_range_max,
    managed_port_host: managed_port_host,
  ) = runner_cfg

  let types_config.StorageConfig(
    workspaces_directory: workspaces_directory,
    artifacts: artifacts,
  ) = storage

  let types_config.SadLimits(
    log_buffer_bytes: log_buffer_bytes,
    max_stdout_bytes: max_stdout_bytes,
    max_runner_event_bytes: max_runner_event_bytes,
    max_request_body_bytes: max_request_body_bytes,
    max_http_response_bytes: max_http_response_bytes,
    max_file_fetch_bytes: max_file_fetch_bytes,
  ) = limits

  let types_config.StreamConfig(
    sse_keep_alive_interval_ms: sse_keep_alive_interval_ms,
    log_stream: log_stream,
    interaction_stream: interaction_stream,
  ) = stream

  server_host |> should.equal("0.0.0.0")
  server_port |> should.equal(8080)
  api_key |> types_core.secret_to_env_value |> should.equal("")
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
  landlock_mode |> should.equal(types_enums.LandlockBestEffort)

  profiles_sources
  |> should.equal([types_config.ProfileSourceDir(path: ".")])

  let types_config.LogStreamConfig(
    batch_byte_size: log_batch_byte_size,
    flush_interval_ms: log_flush_interval_ms,
  ) = log_stream

  log_batch_byte_size |> should.equal(4096)
  log_flush_interval_ms |> should.equal(50)

  let types_config.InteractionStreamConfig(
    batch_byte_size: interaction_batch_byte_size,
    flush_interval_ms: interaction_flush_interval_ms,
    push_timeout_ms: interaction_push_timeout_ms,
  ) = interaction_stream

  interaction_batch_byte_size |> should.equal(4096)
  interaction_flush_interval_ms |> should.equal(25)
  interaction_push_timeout_ms |> should.equal(250)

  let types_config.RunnerIoConfig(
    read_timeout_ms: read_timeout_ms,
    max_read_attempts: max_read_attempts,
  ) = runner_io

  read_timeout_ms |> should.equal(200)
  max_read_attempts |> should.equal(200)

  let types_config.WrapperConfig(
    read_buffer_bytes: read_buffer_bytes,
    control_line_bytes: control_line_bytes,
    poll_interval_ms: poll_interval_ms,
    post_kill_wait_ms: post_kill_wait_ms,
  ) = wrapper

  read_buffer_bytes |> should.equal(4096)
  control_line_bytes |> should.equal(262_144)
  poll_interval_ms |> should.equal(50)
  post_kill_wait_ms |> should.equal(200)

  let types_config.ArtifactStoreConfig(base_path: base_path) = artifacts
  base_path |> should.equal("/artifacts/")
}

pub fn runner_event_variants_test() {
  let response = types_runner.RunnerSuccess(data: None, artifacts: [])

  let events = [
    types_runner.RunnerEventLog(message: "ok", level: "info"),
    types_runner.RunnerEventChunk(delta: "hello"),
    types_runner.RunnerEventResult(response: response),
    types_runner.RunnerEventProvisionResult(
      result: types_runner.RunnerProvisionResult(
        status: types_runner.StatusSuccess,
        log_files: [],
      ),
    ),
  ]

  list.length(events)
  |> should.equal(4)
}

pub fn runner_event_roundtrip_test() {
  // Note: these JSON shapes are part of the runner JSONL contract.
  // This test ensures the `types_runner.RunnerEvent` variants match what the
  // decoder expects.

  let log_line = "{\"t\":\"log\",\"message\":\"hello\",\"level\":\"info\"}"
  case runner_contract.decode_event(log_line) {
    Ok(types_runner.RunnerEventLog(message: m, level: l)) -> {
      m |> should.equal("hello")
      l |> should.equal("info")
    }
    Ok(other) -> panic as string.inspect(other)
    Error(e) -> panic as string.inspect(e)
  }

  let chunk_line = "{\"t\":\"chunk\",\"delta\":\"hi\"}"
  case runner_contract.decode_event(chunk_line) {
    Ok(types_runner.RunnerEventChunk(delta: d)) -> d |> should.equal("hi")
    Ok(other) -> panic as string.inspect(other)
    Error(e) -> panic as string.inspect(e)
  }

  let result_line =
    "{\"t\":\"result\",\"status\":\"success\",\"data\":{\"ok\":true},\"artifacts\":[{\"name\":\"a\",\"path\":\"out.txt\",\"mime\":\"text/plain\"}]}"

  case runner_contract.decode_event(result_line) {
    Ok(types_runner.RunnerEventResult(response: resp)) ->
      case resp {
        types_runner.RunnerSuccess(data: data, artifacts: arts) -> {
          data |> should.not_equal(None)

          list.length(arts) |> should.equal(1)
          let assert [types_runner.ArtifactRef(name: n, path: p, mime: mime)] =
            arts
          n |> should.equal("a")
          p |> should.equal("out.txt")
          mime |> should.equal("text/plain")
        }

        types_runner.RunnerFailure(..) -> panic as "Expected success response"
      }

    Ok(other) -> panic as string.inspect(other)
    Error(e) -> panic as string.inspect(e)
  }

  let provision_line =
    "{\"t\":\"provision_result\",\"status\":\"success\",\"log_files\":[\"provision.log\"]}"

  case runner_contract.decode_event(provision_line) {
    Ok(types_runner.RunnerEventProvisionResult(result: result)) -> {
      let types_runner.RunnerProvisionResult(status: s, log_files: files) =
        result
      s |> should.equal(types_runner.StatusSuccess)
      files |> should.equal(["provision.log"])
    }

    Ok(other) -> panic as string.inspect(other)
    Error(e) -> panic as string.inspect(e)
  }
}
