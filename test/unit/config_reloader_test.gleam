import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import saar/config_loader
import saar/config_reloader
import saar/profiles_sources
import saar/types/config as types_config
import saar/types/core as types_core

pub fn main() {
  gleeunit.main()
}

pub fn reload_on_valid_config_updates_state() {
  let cfg0 = types_config.default_saar_config()
  let types_config.SaarConfig(profiles: profiles0, ..) = cfg0

  let profiles1 =
    types_config.ProfilesConfig(..profiles0, git_cache_dir: "./next")

  let cfg1 = types_config.SaarConfig(..cfg0, profiles: profiles1)

  let state0 =
    config_reloader.ReloadState(
      config: cfg0,
      config_path: "./config.toml",
      last_reload_ms: None,
      debounce_ms: 0,
    )

  let load_config = fn(path) {
    path |> should.equal("./config.toml")
    Ok(cfg1)
  }

  let reload_profiles = fn(config) {
    config |> should.equal(cfg1)
    Ok(
      profiles_sources.ReloadSummary(count: 1, profile_ids: [
        types_core.profile_id("one"),
      ]),
    )
  }

  let #(state1, outcome) =
    config_reloader.reload(state0, 1000, load_config, reload_profiles)

  let config_reloader.ReloadState(
    config: updated_config,
    last_reload_ms: last_reload_ms,
    ..,
  ) = state1

  updated_config |> should.equal(cfg1)
  last_reload_ms |> should.equal(Some(1000))

  case outcome {
    config_reloader.Reloaded(summary: summary, ..) ->
      summary
      |> should.equal(
        profiles_sources.ReloadSummary(count: 1, profile_ids: [
          types_core.profile_id("one"),
        ]),
      )
    _ -> should.equal(True, False)
  }
}

pub fn reload_on_invalid_config_emits_rejected() {
  let cfg0 = types_config.default_saar_config()

  let state0 =
    config_reloader.ReloadState(
      config: cfg0,
      config_path: "./config.toml",
      last_reload_ms: None,
      debounce_ms: 0,
    )

  let load_config = fn(_) {
    Error(config_loader.InvalidValue(key: "params.bad", message: "expected"))
  }

  let reload_profiles = fn(_cfg) { panic as "reload should not run" }

  let #(state1, outcome) =
    config_reloader.reload(state0, 1000, load_config, reload_profiles)

  state1 |> should.equal(state0)

  case outcome {
    config_reloader.Rejected(config_reloader.ConfigReloadFailed(detail)) ->
      should.equal(string.contains(detail, "InvalidValue"), True)
    _ -> should.equal(True, False)
  }
}

pub fn reload_debounce_coalesces_changes() {
  let cfg0 = types_config.default_saar_config()

  let state0 =
    config_reloader.ReloadState(
      config: cfg0,
      config_path: "./config.toml",
      last_reload_ms: Some(1000),
      debounce_ms: 200,
    )

  let load_config = fn(_) { panic as "debounce should skip load" }
  let reload_profiles = fn(_) { panic as "debounce should skip reload" }

  let #(state1, outcome) =
    config_reloader.reload(state0, 1100, load_config, reload_profiles)

  state1 |> should.equal(state0)
  outcome |> should.equal(config_reloader.Debounced)
}
