//// SAD TOML configuration loader.
////
//// Mission: load `SadConfig` from a TOML file with strict key validation and
//// environment interpolation.
////
//// Responsibilities:
//// - Resolve a config path (CLI > env > default).
//// - Interpolate `${VAR}` placeholders from the environment.
//// - Parse TOML and reject unknown keys.
//// - Apply defaults from `sad/types/config.default_sad_config`.
////
//// Non-responsibilities:
//// - Starting supervisors/servers.
//// - Loading profiles/runners from sources.
////
//// Relationships:
//// - Produces `sad/types/config.SadConfig` consumed by bootstrap code.
//// - Uses `tom` for TOML parsing and `envoy`/`simplifile` for boundary IO.

import envoy
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
import simplifile
import tom

/// Errors returned while loading or parsing `config.toml`.
pub type ConfigLoadError {
  ConfigFileNotFound(path: String)
  ConfigReadFailed(path: String, reason: String)
  TomlParseFailed(message: String)
  UnknownKey(key: String)
  InvalidValue(key: String, message: String)
  EnvVarMissing(name: String)
  MissingApiKey
}

/// Resolves the config path using the precedence:
/// `--config` > `SAD_CONFIG_PATH` > `./config.toml`.
///
/// Example:
/// ```gleam
/// import gleam/option.{Some, None}
/// import sad/config_loader
///
/// let path = config_loader.resolve_config_path(Some("./my.toml"))
/// ```
pub fn resolve_config_path(cli_config: Option(String)) -> String {
  resolve_config_path_with_env(cli_config, envoy.get)
}

pub fn resolve_config_path_with_env(
  cli_config: Option(String),
  get_env: fn(String) -> Result(String, Nil),
) -> String {
  case cli_config {
    Some(path) -> path
    None ->
      case get_env("SAD_CONFIG_PATH") {
        Ok(path) -> path
        Error(_) -> "./config.toml"
      }
  }
}

/// Loads and validates a `SadConfig` from disk.
///
/// Defaults are taken from `types_config.default_sad_config()`.
///
/// Fails if `auth.api_key` is missing or empty.
pub fn load(
  cli_config: Option(String),
) -> Result(types_config.SadConfig, ConfigLoadError) {
  let path = resolve_config_path(cli_config)
  load_from_path(path, envoy.get, simplifile.read)
}

pub fn load_from_path(
  path: String,
  get_env: fn(String) -> Result(String, Nil),
  read_file: fn(String) -> Result(String, simplifile.FileError),
) -> Result(types_config.SadConfig, ConfigLoadError) {
  use raw <- result.try(
    read_file(path)
    |> result.map_error(fn(err) {
      case err {
        simplifile.Enoent -> ConfigFileNotFound(path: path)
        _ ->
          ConfigReadFailed(path: path, reason: simplifile.describe_error(err))
      }
    }),
  )

  use interpolated <- result.try(interpolate_env(raw, get_env))

  use parsed <- result.try(
    tom.parse(interpolated)
    |> result.map_error(fn(err) {
      TomlParseFailed(message: string.inspect(err))
    }),
  )

  use _ <- result.try(validate_no_unknown_keys(parsed))

  let cfg = decode_with_defaults(parsed, types_config.default_sad_config())

  case cfg {
    Ok(cfg) ->
      case is_api_key_present(cfg) {
        True -> Ok(cfg)
        False -> Error(MissingApiKey)
      }

    Error(err) -> Error(err)
  }
}

fn is_api_key_present(cfg: types_config.SadConfig) -> Bool {
  let types_config.SadConfig(api_key: api_key, ..) = cfg
  types_core.secret_is_empty(api_key) == False
}

fn interpolate_env(
  input: String,
  get_env: fn(String) -> Result(String, Nil),
) -> Result(String, ConfigLoadError) {
  do_interpolate_env(input, get_env, "")
}

fn do_interpolate_env(
  remaining: String,
  get_env: fn(String) -> Result(String, Nil),
  acc: String,
) -> Result(String, ConfigLoadError) {
  case string.split_once(remaining, on: "${") {
    Error(_) -> Ok(acc <> remaining)

    Ok(#(before, after_open)) ->
      case string.split_once(after_open, on: "}") {
        Error(_) ->
          Error(InvalidValue(key: "config", message: "unclosed ${VAR}"))

        Ok(#(name, rest)) ->
          case is_valid_env_name(name) {
            False ->
              Error(InvalidValue(
                key: "config",
                message: "invalid env placeholder ${" <> name <> "}",
              ))

            True ->
              case get_env(name) {
                Ok(value) ->
                  do_interpolate_env(rest, get_env, acc <> before <> value)
                Error(_) -> Error(EnvVarMissing(name: name))
              }
          }
      }
  }
}

fn is_valid_env_name(name: String) -> Bool {
  case string.is_empty(name) {
    True -> False
    False ->
      name
      |> string.to_graphemes
      |> list.all(fn(ch) {
        string.contains(
          "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_",
          ch,
        )
      })
  }
}

fn validate_no_unknown_keys(
  root: Dict(String, tom.Toml),
) -> Result(Nil, ConfigLoadError) {
  root
  |> dict.to_list
  |> list.try_map(fn(pair) {
    let #(k, v) = pair
    validate_top_level_key(k, v)
  })
  |> result.map(fn(_) { Nil })
}

fn validate_top_level_key(
  key: String,
  value: tom.Toml,
) -> Result(Nil, ConfigLoadError) {
  case key {
    "server" -> validate_table_fields("server", value, ["host", "port"])
    "auth" -> validate_table_fields("auth", value, ["api_key"])
    "profiles" -> validate_profiles_table(value)
    "runners" -> validate_table_fields("runners", value, ["python_bin"])
    "workspaces" -> validate_table_fields("workspaces", value, ["directory"])

    "limits" ->
      validate_table_fields("limits", value, [
        "call_timeout_ms",
        "status_timeout_ms",
        "registry_timeout_ms",
        "health_check_timeout_ms",
        "shutdown_timeout_ms",
        "log_buffer_bytes",
        "max_stdout_bytes",
        "max_runner_event_bytes",
        "max_request_body_bytes",
        "max_http_response_bytes",
        "max_file_fetch_bytes",
        "sse_keep_alive_interval_ms",
        "port_range_min",
        "port_range_max",
      ])

    "network" -> validate_table_fields("network", value, ["managed_port_host"])

    "log_stream" ->
      validate_table_fields("log_stream", value, [
        "batch_byte_size",
        "flush_interval_ms",
      ])

    "interaction_stream" ->
      validate_table_fields("interaction_stream", value, [
        "batch_byte_size",
        "flush_interval_ms",
        "push_timeout_ms",
      ])

    "security" -> validate_table_fields("security", value, ["landlock_mode"])

    _ -> Error(UnknownKey(key: key))
  }
}

fn validate_table_fields(
  prefix: String,
  value: tom.Toml,
  allowed: List(String),
) -> Result(Nil, ConfigLoadError) {
  use table <- result.try(
    tom.as_table(value)
    |> result.map_error(fn(_) {
      InvalidValue(key: prefix, message: "expected table")
    }),
  )

  table
  |> dict.keys
  |> list.try_map(fn(k) {
    case list.contains(allowed, k) {
      True -> Ok(Nil)
      False -> Error(UnknownKey(key: prefix <> "." <> k))
    }
  })
  |> result.map(fn(_) { Nil })
}

fn validate_profiles_table(value: tom.Toml) -> Result(Nil, ConfigLoadError) {
  use table <- result.try(
    tom.as_table(value)
    |> result.map_error(fn(_) {
      InvalidValue(key: "profiles", message: "expected table")
    }),
  )

  table
  |> dict.keys
  |> list.try_map(fn(k) {
    case k {
      "sources" | "git_cache_dir" -> Ok(Nil)
      other -> Error(UnknownKey(key: "profiles." <> other))
    }
  })
  |> result.try(fn(_) {
    case dict.get(table, "sources") {
      Ok(sources) -> validate_profiles_sources(sources)
      Error(_) -> Ok(Nil)
    }
  })
  |> result.map(fn(_) { Nil })
}

fn validate_profiles_sources(value: tom.Toml) -> Result(Nil, ConfigLoadError) {
  use items <- result.try(
    tom.as_array(value)
    |> result.map_error(fn(_) {
      InvalidValue(key: "profiles.sources", message: "expected array")
    }),
  )

  items
  |> list.try_map(fn(item) { validate_profile_source(item) })
  |> result.map(fn(_) { Nil })
}

fn validate_profile_source(item: tom.Toml) -> Result(Nil, ConfigLoadError) {
  use table <- result.try(
    tom.as_table(item)
    |> result.map_error(fn(_) {
      InvalidValue(key: "profiles.sources", message: "expected table item")
    }),
  )

  let kind: Result(String, ConfigLoadError) = case dict.get(table, "type") {
    Ok(t) ->
      tom.as_string(t)
      |> result.map_error(fn(_) {
        InvalidValue(key: "profiles.sources.type", message: "expected string")
      })

    Error(_) ->
      Error(InvalidValue(key: "profiles.sources.type", message: "required"))
  }

  use kind <- result.try(kind)

  table
  |> dict.keys
  |> list.try_map(fn(k) {
    case list.contains(["type", "path", "url", "ref"], k) {
      True -> Ok(Nil)
      False -> Error(UnknownKey(key: "profiles.sources." <> k))
    }
  })
  |> result.try(fn(_) {
    case kind {
      "dir" ->
        case dict.get(table, "path") {
          Ok(v) ->
            tom.as_string(v)
            |> result.map(fn(_) { Nil })
            |> result.map_error(fn(_) {
              InvalidValue(
                key: "profiles.sources.path",
                message: "expected string",
              )
            })

          Error(_) ->
            Error(InvalidValue(
              key: "profiles.sources.path",
              message: "required",
            ))
        }

      "git" ->
        case dict.get(table, "url") {
          Ok(v) ->
            tom.as_string(v)
            |> result.map(fn(_) { Nil })
            |> result.map_error(fn(_) {
              InvalidValue(
                key: "profiles.sources.url",
                message: "expected string",
              )
            })

          Error(_) ->
            Error(InvalidValue(key: "profiles.sources.url", message: "required"))
        }

      other ->
        Error(InvalidValue(
          key: "profiles.sources.type",
          message: "unknown: " <> other,
        ))
    }
  })
}

fn decode_with_defaults(
  root: Dict(String, tom.Toml),
  defaults: types_config.SadConfig,
) -> Result(types_config.SadConfig, ConfigLoadError) {
  let cfg = defaults
  use cfg <- result.try(apply_server(cfg, root))
  use cfg <- result.try(apply_auth(cfg, root))
  use cfg <- result.try(apply_profiles(cfg, root))
  use cfg <- result.try(apply_runners(cfg, root))
  use cfg <- result.try(apply_workspaces(cfg, root))
  use cfg <- result.try(apply_limits(cfg, root))
  use cfg <- result.try(apply_network(cfg, root))
  use cfg <- result.try(apply_log_stream(cfg, root))
  use cfg <- result.try(apply_interaction_stream(cfg, root))
  use cfg <- result.try(apply_security(cfg, root))
  Ok(cfg)
}

fn apply_server(
  cfg: types_config.SadConfig,
  root: Dict(String, tom.Toml),
) -> Result(types_config.SadConfig, ConfigLoadError) {
  case dict.get(root, "server") {
    Error(_) -> Ok(cfg)
    Ok(v) -> {
      use host <- result.try(optional_string(v, "host", "server.host"))
      use port <- result.try(optional_int(v, "port", "server.port"))

      let types_config.SadConfig(
        server_host: old_host,
        server_port: old_port,
        ..,
      ) = cfg

      let next_host = option.unwrap(host, old_host)
      let next_port = option.unwrap(port, old_port)

      Ok(
        types_config.SadConfig(
          ..cfg,
          server_host: next_host,
          server_port: next_port,
        ),
      )
    }
  }
}

fn apply_auth(
  cfg: types_config.SadConfig,
  root: Dict(String, tom.Toml),
) -> Result(types_config.SadConfig, ConfigLoadError) {
  case dict.get(root, "auth") {
    Error(_) -> Ok(cfg)
    Ok(v) -> {
      use api_key <- result.try(optional_string(v, "api_key", "auth.api_key"))

      let types_config.SadConfig(api_key: old_key, ..) = cfg
      let next = case api_key {
        Some(value) -> types_core.secret_value(value)
        None -> old_key
      }

      Ok(types_config.SadConfig(..cfg, api_key: next))
    }
  }
}

fn apply_profiles(
  cfg: types_config.SadConfig,
  root: Dict(String, tom.Toml),
) -> Result(types_config.SadConfig, ConfigLoadError) {
  case dict.get(root, "profiles") {
    Error(_) -> Ok(cfg)
    Ok(v) -> {
      let types_config.SadConfig(profiles: profiles_cfg, ..) = cfg
      let types_config.ProfilesConfig(
        sources: old_sources,
        git_cache_dir: old_dir,
      ) = profiles_cfg

      use sources <- result.try(optional_profile_sources(v))
      use cache_dir <- result.try(optional_string(
        v,
        "git_cache_dir",
        "profiles.git_cache_dir",
      ))

      let next_sources = option.unwrap(sources, old_sources)
      let next_dir = option.unwrap(cache_dir, old_dir)

      let next_profiles =
        types_config.ProfilesConfig(
          sources: next_sources,
          git_cache_dir: next_dir,
        )

      Ok(types_config.SadConfig(..cfg, profiles: next_profiles))
    }
  }
}

fn optional_profile_sources(
  profiles_table: tom.Toml,
) -> Result(Option(List(types_config.ProfileSource)), ConfigLoadError) {
  use table <- result.try(
    tom.as_table(profiles_table)
    |> result.map_error(fn(_) {
      InvalidValue(key: "profiles", message: "expected table")
    }),
  )

  case dict.get(table, "sources") {
    Error(_) -> Ok(None)
    Ok(v) -> {
      use items <- result.try(
        tom.as_array(v)
        |> result.map_error(fn(_) {
          InvalidValue(key: "profiles.sources", message: "expected array")
        }),
      )

      items
      |> list.try_map(fn(item) { decode_profile_source(item) })
      |> result.map(Some)
    }
  }
}

fn decode_profile_source(
  item: tom.Toml,
) -> Result(types_config.ProfileSource, ConfigLoadError) {
  use table <- result.try(
    tom.as_table(item)
    |> result.map_error(fn(_) {
      InvalidValue(key: "profiles.sources", message: "expected table item")
    }),
  )

  use kind <- result.try(required_string(table, "type", "profiles.sources.type"))

  case kind {
    "dir" -> {
      use path <- result.try(required_string(
        table,
        "path",
        "profiles.sources.path",
      ))
      Ok(types_config.ProfileSourceDir(path: path))
    }

    "git" -> {
      use url <- result.try(required_string(
        table,
        "url",
        "profiles.sources.url",
      ))
      let ref = optional_string_from_table(table, "ref")
      Ok(types_config.ProfileSourceGit(url: url, ref: ref))
    }

    other ->
      Error(InvalidValue(
        key: "profiles.sources.type",
        message: "unknown: " <> other,
      ))
  }
}

fn optional_string_from_table(
  table: Dict(String, tom.Toml),
  key: String,
) -> Option(String) {
  case dict.get(table, key) {
    Ok(v) ->
      case tom.as_string(v) {
        Ok(s) -> Some(s)
        Error(_) -> None
      }

    Error(_) -> None
  }
}

fn apply_runners(
  cfg: types_config.SadConfig,
  root: Dict(String, tom.Toml),
) -> Result(types_config.SadConfig, ConfigLoadError) {
  case dict.get(root, "runners") {
    Error(_) -> Ok(cfg)
    Ok(v) -> {
      use python <- result.try(optional_string(
        v,
        "python_bin",
        "runners.python_bin",
      ))

      let types_config.SadConfig(runner: runner_cfg, ..) = cfg
      let types_config.RunnerSystemConfig(python_bin: old, ..) = runner_cfg

      let next_python = option.unwrap(python, old)
      let next_runner =
        types_config.RunnerSystemConfig(..runner_cfg, python_bin: next_python)

      Ok(types_config.SadConfig(..cfg, runner: next_runner))
    }
  }
}

fn apply_workspaces(
  cfg: types_config.SadConfig,
  root: Dict(String, tom.Toml),
) -> Result(types_config.SadConfig, ConfigLoadError) {
  case dict.get(root, "workspaces") {
    Error(_) -> Ok(cfg)
    Ok(v) -> {
      use dir <- result.try(optional_string(
        v,
        "directory",
        "workspaces.directory",
      ))

      let types_config.SadConfig(storage: storage_cfg, ..) = cfg
      let types_config.StorageConfig(
        workspaces_directory: old,
        artifacts: artifacts,
      ) = storage_cfg

      let next_dir = option.unwrap(dir, old)
      let next_storage =
        types_config.StorageConfig(
          workspaces_directory: next_dir,
          artifacts: artifacts,
        )

      Ok(types_config.SadConfig(..cfg, storage: next_storage))
    }
  }
}

fn apply_limits(
  cfg: types_config.SadConfig,
  root: Dict(String, tom.Toml),
) -> Result(types_config.SadConfig, ConfigLoadError) {
  case dict.get(root, "limits") {
    Error(_) -> Ok(cfg)
    Ok(v) -> {
      use call_timeout_ms <- result.try(optional_int(
        v,
        "call_timeout_ms",
        "limits.call_timeout_ms",
      ))
      use status_timeout_ms <- result.try(optional_int(
        v,
        "status_timeout_ms",
        "limits.status_timeout_ms",
      ))
      use registry_timeout_ms <- result.try(optional_int(
        v,
        "registry_timeout_ms",
        "limits.registry_timeout_ms",
      ))
      use health_timeout_ms <- result.try(optional_int(
        v,
        "health_check_timeout_ms",
        "limits.health_check_timeout_ms",
      ))
      use shutdown_timeout_ms <- result.try(optional_int(
        v,
        "shutdown_timeout_ms",
        "limits.shutdown_timeout_ms",
      ))

      use log_buffer_bytes <- result.try(optional_int(
        v,
        "log_buffer_bytes",
        "limits.log_buffer_bytes",
      ))
      use max_stdout_bytes <- result.try(optional_int(
        v,
        "max_stdout_bytes",
        "limits.max_stdout_bytes",
      ))
      use max_runner_event_bytes <- result.try(optional_int(
        v,
        "max_runner_event_bytes",
        "limits.max_runner_event_bytes",
      ))
      use max_request_body_bytes <- result.try(optional_int(
        v,
        "max_request_body_bytes",
        "limits.max_request_body_bytes",
      ))
      use max_http_response_bytes <- result.try(optional_int(
        v,
        "max_http_response_bytes",
        "limits.max_http_response_bytes",
      ))
      use max_file_fetch_bytes <- result.try(optional_int(
        v,
        "max_file_fetch_bytes",
        "limits.max_file_fetch_bytes",
      ))

      use sse_keep_alive_ms <- result.try(optional_int(
        v,
        "sse_keep_alive_interval_ms",
        "limits.sse_keep_alive_interval_ms",
      ))
      use port_range_min <- result.try(optional_int(
        v,
        "port_range_min",
        "limits.port_range_min",
      ))
      use port_range_max <- result.try(optional_int(
        v,
        "port_range_max",
        "limits.port_range_max",
      ))

      let types_config.SadConfig(
        timeouts: timeouts,
        limits: limits_cfg,
        stream: stream_cfg,
        runner: runner_cfg,
        ..,
      ) = cfg

      let types_config.SadTimeouts(
        call_timeout_ms: old_call,
        status_timeout_ms: old_status,
        registry_timeout_ms: old_registry,
        health_check_timeout_ms: old_health,
        shutdown_timeout_ms: old_shutdown,
      ) = timeouts

      let next_timeouts =
        types_config.SadTimeouts(
          call_timeout_ms: option.unwrap(call_timeout_ms, old_call),
          status_timeout_ms: option.unwrap(status_timeout_ms, old_status),
          registry_timeout_ms: option.unwrap(registry_timeout_ms, old_registry),
          health_check_timeout_ms: option.unwrap(health_timeout_ms, old_health),
          shutdown_timeout_ms: option.unwrap(shutdown_timeout_ms, old_shutdown),
        )

      let types_config.SadLimits(
        log_buffer_bytes: old_log_buf,
        max_stdout_bytes: old_max_stdout,
        max_runner_event_bytes: old_max_event,
        max_request_body_bytes: old_max_body,
        max_http_response_bytes: old_max_http,
        max_file_fetch_bytes: old_max_fetch,
      ) = limits_cfg

      let next_limits =
        types_config.SadLimits(
          log_buffer_bytes: option.unwrap(log_buffer_bytes, old_log_buf),
          max_stdout_bytes: option.unwrap(max_stdout_bytes, old_max_stdout),
          max_runner_event_bytes: option.unwrap(
            max_runner_event_bytes,
            old_max_event,
          ),
          max_request_body_bytes: option.unwrap(
            max_request_body_bytes,
            old_max_body,
          ),
          max_http_response_bytes: option.unwrap(
            max_http_response_bytes,
            old_max_http,
          ),
          max_file_fetch_bytes: option.unwrap(
            max_file_fetch_bytes,
            old_max_fetch,
          ),
        )

      let types_config.StreamConfig(
        sse_keep_alive_interval_ms: old_keep_alive,
        log_stream: log_stream,
        interaction_stream: interaction_stream,
      ) = stream_cfg

      let next_stream =
        types_config.StreamConfig(
          sse_keep_alive_interval_ms: option.unwrap(
            sse_keep_alive_ms,
            old_keep_alive,
          ),
          log_stream: log_stream,
          interaction_stream: interaction_stream,
        )

      let types_config.RunnerSystemConfig(
        port_range_min: old_min,
        port_range_max: old_max,
        ..,
      ) = runner_cfg

      let next_runner =
        types_config.RunnerSystemConfig(
          ..runner_cfg,
          port_range_min: option.unwrap(port_range_min, old_min),
          port_range_max: option.unwrap(port_range_max, old_max),
        )

      Ok(
        types_config.SadConfig(
          ..cfg,
          timeouts: next_timeouts,
          limits: next_limits,
          stream: next_stream,
          runner: next_runner,
        ),
      )
    }
  }
}

fn apply_network(
  cfg: types_config.SadConfig,
  root: Dict(String, tom.Toml),
) -> Result(types_config.SadConfig, ConfigLoadError) {
  case dict.get(root, "network") {
    Error(_) -> Ok(cfg)
    Ok(v) -> {
      use host <- result.try(optional_string(
        v,
        "managed_port_host",
        "network.managed_port_host",
      ))

      let types_config.SadConfig(runner: runner_cfg, ..) = cfg
      let types_config.RunnerSystemConfig(managed_port_host: old, ..) =
        runner_cfg

      let next_host = option.unwrap(host, old)
      let next_runner =
        types_config.RunnerSystemConfig(
          ..runner_cfg,
          managed_port_host: next_host,
        )

      Ok(types_config.SadConfig(..cfg, runner: next_runner))
    }
  }
}

fn apply_log_stream(
  cfg: types_config.SadConfig,
  root: Dict(String, tom.Toml),
) -> Result(types_config.SadConfig, ConfigLoadError) {
  case dict.get(root, "log_stream") {
    Error(_) -> Ok(cfg)
    Ok(v) -> {
      use batch <- result.try(optional_int(
        v,
        "batch_byte_size",
        "log_stream.batch_byte_size",
      ))
      use flush <- result.try(optional_int(
        v,
        "flush_interval_ms",
        "log_stream.flush_interval_ms",
      ))

      let types_config.SadConfig(stream: stream_cfg, ..) = cfg
      let types_config.StreamConfig(
        log_stream: log_stream,
        sse_keep_alive_interval_ms: keep_alive,
        interaction_stream: interaction_stream,
      ) = stream_cfg

      let types_config.LogStreamConfig(
        batch_byte_size: old_batch,
        flush_interval_ms: old_flush,
      ) = log_stream

      let next_log_stream =
        types_config.LogStreamConfig(
          batch_byte_size: option.unwrap(batch, old_batch),
          flush_interval_ms: option.unwrap(flush, old_flush),
        )

      let next_stream =
        types_config.StreamConfig(
          sse_keep_alive_interval_ms: keep_alive,
          log_stream: next_log_stream,
          interaction_stream: interaction_stream,
        )

      Ok(types_config.SadConfig(..cfg, stream: next_stream))
    }
  }
}

fn apply_interaction_stream(
  cfg: types_config.SadConfig,
  root: Dict(String, tom.Toml),
) -> Result(types_config.SadConfig, ConfigLoadError) {
  case dict.get(root, "interaction_stream") {
    Error(_) -> Ok(cfg)
    Ok(v) -> {
      use batch <- result.try(optional_int(
        v,
        "batch_byte_size",
        "interaction_stream.batch_byte_size",
      ))
      use flush <- result.try(optional_int(
        v,
        "flush_interval_ms",
        "interaction_stream.flush_interval_ms",
      ))
      use push <- result.try(optional_int(
        v,
        "push_timeout_ms",
        "interaction_stream.push_timeout_ms",
      ))

      let types_config.SadConfig(stream: stream_cfg, ..) = cfg
      let types_config.StreamConfig(
        interaction_stream: interaction_stream,
        sse_keep_alive_interval_ms: keep_alive,
        log_stream: log_stream,
      ) = stream_cfg

      let types_config.InteractionStreamConfig(
        batch_byte_size: old_batch,
        flush_interval_ms: old_flush,
        push_timeout_ms: old_push,
      ) = interaction_stream

      let next_interaction =
        types_config.InteractionStreamConfig(
          batch_byte_size: option.unwrap(batch, old_batch),
          flush_interval_ms: option.unwrap(flush, old_flush),
          push_timeout_ms: option.unwrap(push, old_push),
        )

      let next_stream =
        types_config.StreamConfig(
          sse_keep_alive_interval_ms: keep_alive,
          log_stream: log_stream,
          interaction_stream: next_interaction,
        )

      Ok(types_config.SadConfig(..cfg, stream: next_stream))
    }
  }
}

fn apply_security(
  cfg: types_config.SadConfig,
  root: Dict(String, tom.Toml),
) -> Result(types_config.SadConfig, ConfigLoadError) {
  case dict.get(root, "security") {
    Error(_) -> Ok(cfg)
    Ok(v) -> {
      use mode <- result.try(optional_string(
        v,
        "landlock_mode",
        "security.landlock_mode",
      ))

      let next = case mode {
        None -> Ok(cfg)
        Some(value) ->
          types_enums.landlock_mode_from_string(value)
          |> result.map(fn(m) {
            types_config.SadConfig(..cfg, landlock_mode: m)
          })
          |> result.map_error(fn(_) {
            InvalidValue(key: "security.landlock_mode", message: "invalid")
          })
      }

      next
    }
  }
}

fn optional_int(
  table_value: tom.Toml,
  field: String,
  key: String,
) -> Result(Option(Int), ConfigLoadError) {
  use table <- result.try(
    tom.as_table(table_value)
    |> result.map_error(fn(_) {
      InvalidValue(key: key, message: "expected table")
    }),
  )

  case dict.get(table, field) {
    Error(_) -> Ok(None)
    Ok(v) ->
      tom.as_int(v)
      |> result.map(Some)
      |> result.map_error(fn(_) {
        InvalidValue(key: key, message: "expected int")
      })
  }
}

fn optional_string(
  table_value: tom.Toml,
  field: String,
  key: String,
) -> Result(Option(String), ConfigLoadError) {
  use table <- result.try(
    tom.as_table(table_value)
    |> result.map_error(fn(_) {
      InvalidValue(key: key, message: "expected table")
    }),
  )

  case dict.get(table, field) {
    Error(_) -> Ok(None)
    Ok(v) ->
      tom.as_string(v)
      |> result.map(Some)
      |> result.map_error(fn(_) {
        InvalidValue(key: key, message: "expected string")
      })
  }
}

fn required_string(
  table: Dict(String, tom.Toml),
  field: String,
  key: String,
) -> Result(String, ConfigLoadError) {
  case dict.get(table, field) {
    Error(_) -> Error(InvalidValue(key: key, message: "required"))
    Ok(v) ->
      tom.as_string(v)
      |> result.map_error(fn(_) {
        InvalidValue(key: key, message: "expected string")
      })
  }
}
