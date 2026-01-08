import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sad/types
import sad/types/input as types_input

pub type InterpContext {
  InterpContext(
    params: types.ResolvedParams,
    input: types_input.InputPayload,
    context: types_input.RequestContext,
    helpers: Option(types_input.SadHelpers),
    runner_host: Option(String),
    runner_port: Option(Int),
  )
}

pub type InterpolationError {
  UnknownNamespace(namespace: String, key: String)
  UnknownKey(namespace: String, key: String)
  ValueNotScalar(key: String)
}

pub fn interpolation_error_to_string(err: InterpolationError) -> String {
  case err {
    UnknownNamespace(ns, key) ->
      "Interpolation failed: Unknown namespace '{{" <> ns <> "." <> key <> "}}'"
    UnknownKey(ns, key) ->
      "Interpolation failed: Unknown key '{{" <> ns <> "." <> key <> "}}'"
    ValueNotScalar(key) ->
      "Interpolation failed: Value for '" <> key <> "' is not scalar"
  }
}

pub fn interpolate_string_strict(
  template: String,
  ctx: InterpContext,
) -> Result(String, InterpolationError) {
  case string.split(template, "{{") {
    [] -> Ok(template)
    [head, ..tail] -> {
      tail
      |> list.try_fold(head, fn(acc, part) {
        case string.split(part, "}}") {
          [] -> Ok(acc <> "{{" <> part)
          [inside] -> Ok(acc <> "{{" <> inside)
          [inside, ..rest] -> {
            let remainder = string.join(rest, "}}")
            case parse_placeholder(inside) {
              Some(#(namespace, key)) -> {
                use value <- result.try(resolve_placeholder(namespace, key, ctx))
                Ok(acc <> value <> remainder)
              }
              None -> Ok(acc <> "{{" <> inside <> "}}" <> remainder)
            }
          }
        }
      })
    }
  }
}

pub fn interpolate_dict(
  templates: Dict(String, String),
  ctx: InterpContext,
) -> Result(Dict(String, String), InterpolationError) {
  templates
  |> dict.to_list
  |> list.try_map(fn(pair) {
    let #(k, v) = pair
    use interpolated <- result.try(interpolate_string_strict(v, ctx))
    Ok(#(k, interpolated))
  })
  |> result.map(dict.from_list)
}

pub fn interpolate_list(
  templates: List(String),
  ctx: InterpContext,
) -> Result(List(String), InterpolationError) {
  list.try_map(templates, fn(t) { interpolate_string_strict(t, ctx) })
}

fn resolve_placeholder(
  namespace: String,
  key: String,
  ctx: InterpContext,
) -> Result(String, InterpolationError) {
  case namespace {
    "params" -> resolve_params(key, ctx.params)
    _ -> Error(UnknownNamespace(namespace, key))
  }
}

fn resolve_params(
  key: String,
  params: types.ResolvedParams,
) -> Result(String, InterpolationError) {
  case dict.get(params, key) {
    Ok(value) -> Ok(types.resolved_value_to_env(value))
    Error(_) -> Error(UnknownKey("params", key))
  }
}

fn parse_placeholder(raw: String) -> Option(#(String, String)) {
  case string.split(raw, ".") {
    [namespace, key] -> {
      case is_valid_namespace(namespace), is_valid_key(key) {
        True, True -> Some(#(namespace, key))
        _, _ -> None
      }
    }
    _ -> None
  }
}

fn is_valid_namespace(value: String) -> Bool {
  case string.is_empty(value) {
    True -> False
    False ->
      value
      |> string.to_graphemes
      |> list.all(is_namespace_char)
  }
}

fn is_valid_key(value: String) -> Bool {
  case string.is_empty(value) {
    True -> False
    False ->
      value
      |> string.to_graphemes
      |> list.all(is_key_char)
  }
}

fn is_namespace_char(char: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_", char)
}

fn is_key_char(char: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
    char,
  )
}
