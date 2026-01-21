import gleam/dict
import gleam/list
import gleam/option.{None}
import gleeunit
import gleeunit/should
import saar/params as params_resolver
import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/profile as types_profile
import saar/types/resolved_params

pub fn main() {
  gleeunit.main()
}

pub fn config_param_reads_params_namespace() {
  let cfg0 = types_config.default_saar_config()

  let params = dict.from_list([#("model", types_core.StringVal("gpt-4o-mini"))])

  let cfg = types_config.SaarConfig(..cfg0, params: params)

  let parameters =
    dict.from_list([
      #(
        "model",
        types_profile.ConfigParam(
          "params.model",
          None,
          types_profile.ParamString,
        ),
      ),
    ])

  let config_values = types_config.config_values_for_keys(cfg, ["params.model"])

  let assert Ok(resolved) =
    params_resolver.resolve_params(
      parameters,
      config_values,
      fn(_) { Error(Nil) },
      dict.new(),
    )

  dict.get(resolved, "model")
  |> should.equal(
    Ok(resolved_params.NormalValue(types_core.StringVal("gpt-4o-mini"))),
  )
}

pub fn config_param_missing_params_namespace_errors() {
  let cfg0 = types_config.default_saar_config()
  let cfg = types_config.SaarConfig(..cfg0, params: dict.new())

  let parameters =
    dict.from_list([
      #(
        "model",
        types_profile.ConfigParam(
          "params.model",
          None,
          types_profile.ParamString,
        ),
      ),
    ])

  let config_values = types_config.config_values_for_keys(cfg, ["params.model"])

  let result =
    params_resolver.resolve_params(
      parameters,
      config_values,
      fn(_) { Error(Nil) },
      dict.new(),
    )

  let assert Error(errors) = result
  list.length(errors) |> should.equal(1)

  case list.first(errors) {
    Ok(params_resolver.MissingConfig("model", "params.model")) ->
      should.equal(True, True)
    _ -> should.equal(True, False)
  }
}
