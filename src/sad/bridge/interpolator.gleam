import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sad/types
import sad/types/core as types_core
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
  InvalidPointer(pointer: String)
}

pub fn interpolation_error_to_string(err: InterpolationError) -> String {
  case err {
    UnknownNamespace(ns, key) ->
      "Interpolation failed: Unknown namespace '{{" <> ns <> "." <> key <> "}}'"
    UnknownKey(ns, key) ->
      "Interpolation failed: Unknown key '{{" <> ns <> "." <> key <> "}}'"
    ValueNotScalar(key) ->
      "Interpolation failed: Value for '" <> key <> "' is not scalar"
    InvalidPointer(pointer) ->
      "Interpolation failed: Invalid JSON pointer '" <> pointer <> "'"
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

pub fn build_context(
  params: types.ResolvedParams,
  input: types_input.InputPayload,
  context: types_input.RequestContext,
  runner_host: Option(String),
  runner_port: Option(Int),
) -> InterpContext {
  InterpContext(
    params: params,
    input: input,
    context: context,
    helpers: Some(types_input.derive_helpers(input)),
    runner_host: runner_host,
    runner_port: runner_port,
  )
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

pub fn interpolate_json(
  template: json.Json,
  ctx: InterpContext,
) -> Result(json.Json, InterpolationError) {
  let dynamic_template = json_to_dynamic(template)
  use interpolated <- result.try(interpolate_dynamic(dynamic_template, ctx))
  Ok(dynamic_to_json(interpolated))
}

pub fn resolve_json_pointer(
  pointer: String,
  value: json.Json,
) -> Result(json.Json, InterpolationError) {
  use segments <- result.try(parse_json_pointer(pointer))
  let root = json_to_dynamic(value)
  use resolved <- result.try(resolve_dynamic_pointer(segments, root, pointer))
  Ok(dynamic_to_json(resolved))
}

pub fn resolve_placeholder(
  namespace: String,
  key: String,
  ctx: InterpContext,
) -> Result(String, InterpolationError) {
  case namespace {
    "params" -> resolve_params(key, ctx.params)
    "helpers" -> resolve_helpers(key, ctx.helpers)
    "context" -> resolve_context(key, ctx.context)
    "runner" -> resolve_runner(key, ctx.runner_host, ctx.runner_port)
    "input" -> resolve_input(key, ctx.input)
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

fn resolve_helpers(
  key: String,
  helpers: Option(types_input.SadHelpers),
) -> Result(String, InterpolationError) {
  case helpers {
    None -> Error(UnknownKey("helpers", key))
    Some(types_input.SadHelpers(last_user_content, _)) ->
      case key {
        "last_user_content" ->
          case last_user_content {
            Some(content) -> Ok(content)
            None -> Ok("")
          }
        "last_user_files" -> Error(ValueNotScalar("helpers.last_user_files"))
        _ -> Error(UnknownKey("helpers", key))
      }
  }
}

fn resolve_context(
  key: String,
  ctx: types_input.RequestContext,
) -> Result(String, InterpolationError) {
  case key {
    "trace_id" -> Ok(types_core.trace_id_to_string(ctx.trace_id))
    _ -> Error(UnknownKey("context", key))
  }
}

fn resolve_runner(
  key: String,
  host: Option(String),
  port: Option(Int),
) -> Result(String, InterpolationError) {
  case key {
    "host" ->
      case host {
        Some(value) -> Ok(value)
        None -> Error(UnknownKey("runner", "host"))
      }
    "port" ->
      case port {
        Some(value) -> Ok(int.to_string(value))
        None -> Error(UnknownKey("runner", "port"))
      }
    _ -> Error(UnknownKey("runner", key))
  }
}

fn resolve_input(
  key: String,
  input: types_input.InputPayload,
) -> Result(String, InterpolationError) {
  case input {
    types_input.PayloadChat(_, extra) | types_input.PayloadMixed(_, _, extra) ->
      case dict.get(extra, key) {
        Ok(value) ->
          case is_scalar_value(value) {
            True -> Ok(types_core.value_to_string(value))
            False -> Error(ValueNotScalar("input." <> key))
          }
        Error(_) -> Error(UnknownKey("input", key))
      }
    types_input.PayloadFiles(_) -> Error(UnknownKey("input", key))
  }
}

fn is_scalar_value(value: types_input.InputValue) -> Bool {
  case value {
    types_core.ListVal(_) -> False
    _ -> True
  }
}

fn interpolate_dynamic(
  value: dynamic.Dynamic,
  ctx: InterpContext,
) -> Result(dynamic.Dynamic, InterpolationError) {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(fields) -> {
      case extract_from_pointer(fields) {
        Some(pointer) -> {
          use resolved <- result.try(resolve_json_pointer(
            pointer,
            interp_context_to_json(ctx),
          ))
          Ok(json_to_dynamic(resolved))
        }
        None -> {
          fields
          |> dict.to_list
          |> list.try_map(fn(pair) {
            let #(key, field_value) = pair
            use interpolated <- result.try(interpolate_dynamic(field_value, ctx))
            Ok(#(dynamic.string(key), interpolated))
          })
          |> result.map(dynamic.properties)
        }
      }
    }
    Error(_) ->
      case decode.run(value, decode.list(of: decode.dynamic)) {
        Ok(items) -> {
          items
          |> list.try_map(fn(item) { interpolate_dynamic(item, ctx) })
          |> result.map(dynamic.list)
        }
        Error(_) ->
          case decode.run(value, decode.string) {
            Ok(text) -> {
              use interpolated <- result.try(interpolate_string_strict(
                text,
                ctx,
              ))
              Ok(dynamic.string(interpolated))
            }
            Error(_) -> Ok(value)
          }
      }
  }
}

fn extract_from_pointer(fields: Dict(String, dynamic.Dynamic)) -> Option(String) {
  case dict.size(fields) == 1 {
    False -> None
    True ->
      case dict.get(fields, "$from") {
        Ok(value) ->
          case decode.run(value, decode.string) {
            Ok(pointer) -> Some(pointer)
            Error(_) -> None
          }
        Error(_) -> None
      }
  }
}

fn interp_context_to_json(ctx: InterpContext) -> json.Json {
  json.object([
    #("params", params_to_json(ctx.params)),
    #("input", input_payload_to_json(ctx.input)),
    #("context", request_context_to_json(ctx.context)),
    #("helpers", helpers_to_json(ctx.helpers)),
  ])
}

fn params_to_json(params: types.ResolvedParams) -> json.Json {
  params
  |> dict.to_list
  |> list.map(fn(pair) {
    #(pair.0, json.string(types.resolved_value_to_env(pair.1)))
  })
  |> json.object
}

fn request_context_to_json(ctx: types_input.RequestContext) -> json.Json {
  let base =
    ctx.extra
    |> dict.insert("trace_id", types_core.trace_id_to_string(ctx.trace_id))
    |> dict.to_list
    |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) })

  json.object(base)
}

fn helpers_to_json(helpers: Option(types_input.SadHelpers)) -> json.Json {
  case helpers {
    None -> json.null()
    Some(types_input.SadHelpers(last_user_content, last_user_files)) ->
      json.object([
        #("last_user_content", case last_user_content {
          Some(content) -> json.string(content)
          None -> json.null()
        }),
        #("last_user_files", json.array(last_user_files, file_ref_to_json)),
      ])
  }
}

fn input_payload_to_json(payload: types_input.InputPayload) -> json.Json {
  case payload {
    types_input.PayloadChat(messages, extra) -> {
      let base = [#("messages", json.array(messages, chat_message_to_json))]
      let extra_fields =
        extra
        |> dict.to_list
        |> list.map(fn(pair) { #(pair.0, input_value_to_json(pair.1)) })
      json.object(list.append(base, extra_fields))
    }
    types_input.PayloadFiles(files) ->
      json.object([#("files", json.array(files, file_ref_to_json))])
    types_input.PayloadMixed(messages, files, extra) -> {
      let base = [
        #("messages", json.array(messages, chat_message_to_json)),
        #("files", json.array(files, file_ref_to_json)),
      ]
      let extra_fields =
        extra
        |> dict.to_list
        |> list.map(fn(pair) { #(pair.0, input_value_to_json(pair.1)) })
      json.object(list.append(base, extra_fields))
    }
  }
}

fn chat_message_to_json(message: types_input.ChatMessage) -> json.Json {
  json.object([
    #("role", json.string(message.role)),
    #("content", json.string(message.content)),
  ])
}

fn file_ref_to_json(file: types_input.FileRef) -> json.Json {
  json.object([
    #("url", json.string(file.url)),
    #("mime", json.string(file.mime)),
    #("name", json.string(file.name)),
    #("context", case file.context {
      Some(ctx) -> json.string(ctx)
      None -> json.null()
    }),
  ])
}

fn input_value_to_json(value: types_input.InputValue) -> json.Json {
  case value {
    types_core.StringVal(s) -> json.string(s)
    types_core.IntVal(i) -> json.int(i)
    types_core.FloatVal(f) -> json.float(f)
    types_core.BoolVal(b) -> json.bool(b)
    types_core.ListVal(items) -> json.array(items, json.string)
  }
}

fn json_to_dynamic(value: json.Json) -> dynamic.Dynamic {
  let assert Ok(dynamic_value) =
    json.to_string(value)
    |> json.parse(using: decode.dynamic)
  dynamic_value
}

fn dynamic_to_json(value: dynamic.Dynamic) -> json.Json {
  case decode.run(value, decode.optional(decode.dynamic)) {
    Ok(None) -> json.null()
    Ok(Some(inner)) -> dynamic_to_json_non_null(inner)
    Error(_) -> json.null()
  }
}

fn dynamic_to_json_non_null(value: dynamic.Dynamic) -> json.Json {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(entries) ->
      entries
      |> dict.to_list
      |> list.map(fn(pair) { #(pair.0, dynamic_to_json(pair.1)) })
      |> json.object
    Error(_) ->
      case decode.run(value, decode.list(of: decode.dynamic)) {
        Ok(items) -> json.array(items, dynamic_to_json)
        Error(_) ->
          case decode.run(value, decode.string) {
            Ok(text) -> json.string(text)
            Error(_) ->
              case decode.run(value, decode.bool) {
                Ok(flag) -> json.bool(flag)
                Error(_) ->
                  case decode.run(value, decode.int) {
                    Ok(number) -> json.int(number)
                    Error(_) ->
                      case decode.run(value, decode.float) {
                        Ok(number) -> json.float(number)
                        Error(_) -> json.null()
                      }
                  }
              }
          }
      }
  }
}

fn parse_json_pointer(
  pointer: String,
) -> Result(List(String), InterpolationError) {
  case pointer {
    "" -> Ok([])
    _ ->
      case string.split(pointer, "/") {
        ["", ..segments] ->
          list.try_map(segments, fn(segment) {
            decode_pointer_segment(segment, pointer)
          })
        _ -> Error(InvalidPointer(pointer))
      }
  }
}

fn decode_pointer_segment(
  segment: String,
  pointer: String,
) -> Result(String, InterpolationError) {
  segment
  |> string.to_graphemes
  |> decode_pointer_chars(pointer, [])
}

fn decode_pointer_chars(
  chars: List(String),
  pointer: String,
  acc: List(String),
) -> Result(String, InterpolationError) {
  case chars {
    [] -> Ok(acc |> list.reverse |> string.join(""))
    ["~"] -> Error(InvalidPointer(pointer))
    ["~", "0", ..rest] -> decode_pointer_chars(rest, pointer, ["~", ..acc])
    ["~", "1", ..rest] -> decode_pointer_chars(rest, pointer, ["/", ..acc])
    ["~", _, ..] -> Error(InvalidPointer(pointer))
    [char, ..rest] -> decode_pointer_chars(rest, pointer, [char, ..acc])
  }
}

fn resolve_dynamic_pointer(
  segments: List(String),
  current: dynamic.Dynamic,
  pointer: String,
) -> Result(dynamic.Dynamic, InterpolationError) {
  case segments {
    [] -> Ok(current)
    [segment, ..rest] ->
      case decode.run(current, decode.dict(decode.string, decode.dynamic)) {
        Ok(fields) ->
          case dict.get(fields, segment) {
            Ok(next) -> resolve_dynamic_pointer(rest, next, pointer)
            Error(_) -> Error(InvalidPointer(pointer))
          }
        Error(_) ->
          case decode.run(current, decode.list(of: decode.dynamic)) {
            Ok(items) -> resolve_list_pointer(segment, rest, items, pointer)
            Error(_) -> Error(InvalidPointer(pointer))
          }
      }
  }
}

fn resolve_list_pointer(
  segment: String,
  rest: List(String),
  items: List(dynamic.Dynamic),
  pointer: String,
) -> Result(dynamic.Dynamic, InterpolationError) {
  case int.parse(segment) {
    Ok(index) ->
      case index < 0 {
        True -> Error(InvalidPointer(pointer))
        False ->
          case list.drop(items, index) |> list.first {
            Ok(value) -> resolve_dynamic_pointer(rest, value, pointer)
            Error(_) -> Error(InvalidPointer(pointer))
          }
      }
    Error(_) -> Error(InvalidPointer(pointer))
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
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_",
    char,
  )
}

fn is_key_char(char: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
    char,
  )
}
