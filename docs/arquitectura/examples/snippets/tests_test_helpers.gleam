// test/test_helpers.gleam

import gleam/erlang/process
import saar/core/agent.{type AgentRef}
import saar/types.{type Profile, type SaarConfig}

/// Carga config de test.
pub fn test_config() -> SaarConfig {
  config.load("test/fixtures/config/test_config.toml")
  |> result.unwrap(default_test_config())
}

/// Carga perfil de test por nombre.
pub fn load_test_profile(name: String) -> Profile {
  let path = "test/fixtures/source_local/profiles/" <> name <> ".json"
  config.load_profile(path)
  |> result.unwrap_or_panic
}

/// Crea actor de agente para testing.
pub fn start_test_agent(profile: Profile) -> AgentRef {
  let config = test_config()
  let params = resolve_test_params(profile)
  agent.start(profile, params, config)
  |> result.unwrap_or_panic
}

/// Mock de env lookup que siempre falla.
pub fn empty_env(_key: String) -> Result(String, Nil) {
  Error(Nil)
}

/// Mock de env lookup con valores fijos.
pub fn mock_env(
  values: Dict(String, String),
) -> fn(String) -> Result(String, Nil) {
  fn(key) { dict.get(values, key) }
}

/// Espera un mensaje con timeout.
pub fn expect_message(subject: Subject(a), timeout_ms: Int) -> a {
  process.receive(subject, timeout_ms)
  |> result.unwrap_or_panic
}
