import gleam/dict
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import saar/types/config as types_config
import saar/types/core as types_core

pub fn main() {
  gleeunit.main()
}

pub fn config_value_resolves_params_namespace() {
  let cfg0 = types_config.default_saar_config()

  let params = dict.from_list([#("model", types_core.StringVal("gpt-4o"))])

  let cfg = types_config.SaarConfig(..cfg0, params: params)

  types_config.config_value(cfg, "params.model")
  |> should.equal(Some(types_core.StringVal("gpt-4o")))
}

pub fn config_value_does_not_override_system_keys() {
  let cfg0 = types_config.default_saar_config()

  let params = dict.from_list([#("server.port", types_core.IntVal(9999))])

  let cfg = types_config.SaarConfig(..cfg0, params: params)

  types_config.config_value(cfg, "server.port")
  |> should.equal(Some(types_core.IntVal(8080)))
}
