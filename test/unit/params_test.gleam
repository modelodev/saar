import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import sad/params
import sad/types
import sad/types/core as types_core
import sad/types/profile as types_profile

pub fn main() {
  gleeunit.main()
}

pub fn secret_without_default_is_required_test() {
  let params =
    dict.from_list([
      #(
        "api_key",
        types_profile.SecretParam("API_KEY", types_profile.ParamString),
      ),
    ])

  let result =
    params.resolve_params(params, dict.new(), fn(_) { Error(Nil) }, dict.new())

  let assert Error(errors) = result
  list.length(errors)
  |> should.equal(1)

  case list.first(errors) {
    Ok(params.MissingSecret("api_key", "API_KEY")) -> should.equal(True, True)
    _ -> should.equal(True, False)
  }
}

pub fn fixed_uses_value_test() {
  let params =
    dict.from_list([
      #("delay_ms", types_profile.FixedParam(types_core.IntVal(100))),
    ])

  let assert Ok(resolved) =
    params.resolve_params(params, dict.new(), fn(_) { Error(Nil) }, dict.new())

  dict.get(resolved, "delay_ms")
  |> should.equal(Ok(types.NormalValue(types_core.IntVal(100))))
}

pub fn defaults_applied_test() {
  let params =
    dict.from_list([
      #(
        "model",
        types_profile.ConfigParam(
          "model",
          Some(types_core.StringVal("gpt-4")),
          types_profile.ParamString,
        ),
      ),
      #(
        "timeout",
        types_profile.InitParam(
          "timeout",
          Some(types_core.IntVal(30)),
          types_profile.ParamInt,
        ),
      ),
    ])

  let assert Ok(resolved) =
    params.resolve_params(params, dict.new(), fn(_) { Error(Nil) }, dict.new())

  dict.get(resolved, "model")
  |> should.equal(Ok(types.NormalValue(types_core.StringVal("gpt-4"))))

  dict.get(resolved, "timeout")
  |> should.equal(Ok(types.NormalValue(types_core.IntVal(30))))
}

pub fn missing_config_accumulates_test() {
  let params =
    dict.from_list([
      #(
        "model",
        types_profile.ConfigParam("model", None, types_profile.ParamString),
      ),
      #(
        "region",
        types_profile.ConfigParam("region", None, types_profile.ParamString),
      ),
    ])

  let result =
    params.resolve_params(params, dict.new(), fn(_) { Error(Nil) }, dict.new())

  let assert Error(errors) = result
  list.length(errors)
  |> should.equal(2)
}

pub fn type_mismatch_in_secret_test() {
  let params =
    dict.from_list([
      #("count", types_profile.SecretParam("COUNT", types_profile.ParamInt)),
    ])

  let result =
    params.resolve_params(
      params,
      dict.new(),
      fn(_) { Ok("not-a-number") },
      dict.new(),
    )

  let assert Error(errors) = result
  case list.first(errors) {
    Ok(params.TypeMismatch("count", types_core.TypeInt, types_core.TypeString)) ->
      should.equal(True, True)
    _ -> should.equal(True, False)
  }
}
