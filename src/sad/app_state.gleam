////
//// Mission: carry the pure startup inputs required to boot the SAD OTP tree.
////
//// Responsibilities:
//// - Bundle runtime configuration and initial in-memory data.
//// - Provide a single value that can be assembled at the boundary (CLI/main).
////
//// Non-responsibilities:
//// - Loading profiles from disk/git.
//// - Parsing environment variables or TOML.
////
//// Relationships:
//// - Consumed by `sad/core/root_supervisor.start`.

import gleam/dict
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/profile as types_profile

pub type AppState {
  AppState(
    config: types_config.SadConfig,
    initial_profiles: dict.Dict(types_core.ProfileId, types_profile.Profile),
  )
}
