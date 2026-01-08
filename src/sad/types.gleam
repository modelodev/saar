import gleam/dict.{type Dict}
import sad/types/core as types_core

pub type ResolvedValue {
  NormalValue(types_core.Value)
  SecretVal(types_core.SecretValue)
}

pub type ResolvedParams =
  Dict(String, ResolvedValue)

pub fn resolved_value_to_env(value: ResolvedValue) -> String {
  case value {
    NormalValue(v) -> types_core.value_to_string(v)
    SecretVal(secret) -> types_core.secret_to_env_value(secret)
  }
}

pub fn resolved_value_inspect(value: ResolvedValue) -> String {
  case value {
    NormalValue(v) -> types_core.value_to_string(v)
    SecretVal(secret) -> types_core.secret_inspect(secret)
  }
}

pub fn failure_reason_port_pool_exhausted() -> String {
  "PORT_POOL_EXHAUSTED"
}
