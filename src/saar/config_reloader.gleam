//// Configuration reload coordination.
////
//// Mission: orchestrate manual config reloads with validation and debouncing.
////
//// Responsibilities:
//// - Track reload state and debounce timing.
//// - Load and merge reloadable config slices (profiles + params).
//// - Surface reload outcomes and error details to callers.
////
//// Non-responsibilities:
//// - Exposing HTTP endpoints or logging.
//// - Performing IO directly (callers inject loaders).
////
//// Relationships:
//// - Used by `saar/gateway/sys_api` for `/sys/reload`.
//// - Delegates parsing to `saar/config_loader` and profile loading to
////   `saar/profiles_sources`.

import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import saar/config_loader
import saar/profiles_sources
import saar/types/config as types_config

/// Stable error code for config reload failures.
pub const config_reload_failed_code = "CONFIG_RELOAD_FAILED"

/// Stable error code for profiles reload failures.
pub const profiles_reload_failed_code = "PROFILES_RELOAD_FAILED"

/// Default debounce window in milliseconds.
pub const default_debounce_ms = 250

/// In-memory state for manual reloads.
pub type ReloadState {
  ReloadState(
    config: types_config.SaarConfig,
    config_path: String,
    last_reload_ms: Option(Int),
    debounce_ms: Int,
  )
}

/// Errors that can occur while reloading config.
pub type ReloadError {
  ConfigReloadFailed(detail: String)
  ProfilesReloadFailed(detail: String)
}

/// Outcome returned from a reload attempt.
pub type ReloadOutcome {
  Reloaded(
    config: types_config.SaarConfig,
    summary: profiles_sources.ReloadSummary,
  )
  Rejected(ReloadError)
  Debounced
}

/// Returns a stable code for a reload error.
pub fn reload_error_code(err: ReloadError) -> String {
  case err {
    ConfigReloadFailed(_) -> config_reload_failed_code
    ProfilesReloadFailed(_) -> profiles_reload_failed_code
  }
}

/// Returns the human-readable detail for a reload error.
pub fn reload_error_detail(err: ReloadError) -> String {
  case err {
    ConfigReloadFailed(detail) -> detail
    ProfilesReloadFailed(detail) -> detail
  }
}

/// Attempts to reload config using the provided loader and profile reloaders.
pub fn reload(
  state: ReloadState,
  now_ms: Int,
  load_config: fn(String) ->
    Result(types_config.SaarConfig, config_loader.ConfigLoadError),
  reload_profiles: fn(types_config.SaarConfig) ->
    Result(profiles_sources.ReloadSummary, profiles_sources.ProfilesSourceError),
) -> #(ReloadState, ReloadOutcome) {
  let ReloadState(
    config: current_config,
    config_path: config_path,
    last_reload_ms: last_reload_ms,
    debounce_ms: debounce_ms,
  ) = state

  case should_debounce(last_reload_ms, debounce_ms, now_ms) {
    True -> #(state, Debounced)
    False -> {
      let loaded =
        load_config(config_path)
        |> result.map_error(fn(err) { ConfigReloadFailed(string.inspect(err)) })

      case loaded {
        Error(err) -> #(state, Rejected(err))

        Ok(next_loaded) -> {
          let next_config = merge_reloadable_config(current_config, next_loaded)

          case reload_profiles(next_config) {
            Ok(summary) -> {
              let next_state =
                ReloadState(
                  ..state,
                  config: next_config,
                  last_reload_ms: Some(now_ms),
                )
              #(next_state, Reloaded(config: next_config, summary: summary))
            }

            Error(err) -> #(
              state,
              Rejected(ProfilesReloadFailed(string.inspect(err))),
            )
          }
        }
      }
    }
  }
}

fn should_debounce(
  last_reload_ms: Option(Int),
  debounce_ms: Int,
  now_ms: Int,
) -> Bool {
  case last_reload_ms {
    None -> False
    Some(last) -> int.max(now_ms - last, 0) < debounce_ms
  }
}

fn merge_reloadable_config(
  current: types_config.SaarConfig,
  loaded: types_config.SaarConfig,
) -> types_config.SaarConfig {
  let types_config.SaarConfig(profiles: next_profiles, params: next_params, ..) =
    loaded

  types_config.SaarConfig(
    ..current,
    profiles: next_profiles,
    params: next_params,
  )
}
