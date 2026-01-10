import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sad/json_pointer
import sad/types
import sad/types/core as types_core
import sad/types/input as types_input

pub type RunnerAddress {
  RunnerAddress(host: Option(String), port: Option(Int))
}

pub type InterpContext {
  InterpContext(
    params: types.ResolvedParams,
    input: types_input.InputPayload,
    context: types_input.RequestContext,
    runner: RunnerAddress,
  )
}

pub type InterpValue {
  Null
  Str(String)
  Int(Int)
  Float(Float)
  Bool(Bool)
  Array(List(InterpValue))
  Object(Dict(String, InterpValue))
}

type Token {
  Literal(String)
  Placeholder(namespace: String, key: String)
}

pub type InterpolationError {
  UnknownNamespace(namespace: String, key: String)
  UnknownKey(namespace: String, key: String)
  ValueNotScalar(key: String)
  InvalidPointer(pointer: String)
  InvalidPlaceholder(placeholder: String)
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
    InvalidPlaceholder(placeholder) ->
      "Interpolation failed: Invalid placeholder '{{" <> placeholder <> "}}'"
  }
}

pub fn interpolate_string(
  template: String,
  ctx: InterpContext,
) -> Result(String, InterpolationError) {
  let context = string_context_value(ctx)
  use tokens <- result.try(tokenize(template))
  use parts <- result.try(
    list.try_map(tokens, fn(token) {
      case token {
        Literal(text) -> Ok(text)
        Placeholder(namespace, key) ->
          resolve_placeholder_with_context(namespace, key, context)
      }
    }),
  )
  Ok(string.join(parts, with: ""))
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
    runner: RunnerAddress(host: runner_host, port: runner_port),
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
    use interpolated <- result.try(interpolate_string(v, ctx))
    Ok(#(k, interpolated))
  })
  |> result.map(dict.from_list)
}

pub fn interpolate_list(
  templates: List(String),
  ctx: InterpContext,
) -> Result(List(String), InterpolationError) {
  list.try_map(templates, fn(t) { interpolate_string(t, ctx) })
}

pub fn interpolate_json(
  template: json.Json,
  ctx: InterpContext,
) -> Result(json.Json, InterpolationError) {
  let value = json_to_value(template)
  let string_context = string_context_value(ctx)
  let pointer_context = pointer_context_value(ctx)

  use interpolated <- result.try(
    interpolate_value(value, string_context, pointer_context),
  )
  Ok(value_to_json(interpolated))
}

pub fn resolve_json_pointer(
  pointer: String,
  value: json.Json,
) -> Result(json.Json, InterpolationError) {
  let root = json_to_value(value)
  use resolved <- result.try(resolve_pointer(pointer, root))
  Ok(value_to_json(resolved))
}

pub fn resolve_placeholder(
  namespace: String,
  key: String,
  ctx: InterpContext,
) -> Result(String, InterpolationError) {
  resolve_placeholder_with_context(namespace, key, string_context_value(ctx))
}

fn resolve_placeholder_with_context(
  namespace: String,
  key: String,
  context: InterpValue,
) -> Result(String, InterpolationError) {
  case context {
    Object(namespaces) ->
      case dict.get(namespaces, namespace) {
        Ok(value) -> resolve_value_key(namespace, key, value)
        Error(_) -> Error(UnknownNamespace(namespace, key))
      }
    _ -> Error(UnknownNamespace(namespace, key))
  }
}

fn resolve_value_key(
  namespace: String,
  key: String,
  value: InterpValue,
) -> Result(String, InterpolationError) {
  case value {
    Object(fields) ->
      case dict.get(fields, key) {
        Ok(field) -> value_to_string(field, namespace <> "." <> key)
        Error(_) -> Error(UnknownKey(namespace, key))
      }
    _ -> Error(UnknownKey(namespace, key))
  }
}

fn value_to_string(
  value: InterpValue,
  full_key: String,
) -> Result(String, InterpolationError) {
  case value {
    Str(text) -> Ok(text)
    Int(number) -> Ok(int.to_string(number))
    Float(number) -> Ok(float.to_string(number))
    Bool(True) -> Ok("true")
    Bool(False) -> Ok("false")
    Null -> Ok("")
    _ -> Error(ValueNotScalar(full_key))
  }
}

fn string_context_value(ctx: InterpContext) -> InterpValue {
  Object(
    dict.from_list([
      #("params", params_to_value(ctx.params)),
      #("input", input_extra_to_value(ctx.input)),
      #("context", context_to_value(ctx.context, False)),
      #("helpers", helpers_to_value(ctx.input)),
      #("runner", runner_to_value(ctx.runner)),
    ]),
  )
}

fn pointer_context_value(ctx: InterpContext) -> InterpValue {
  Object(
    dict.from_list([
      #("params", params_to_value(ctx.params)),
      #("input", input_full_to_value(ctx.input)),
      #("context", context_to_value(ctx.context, True)),
      #("helpers", helpers_to_value(ctx.input)),
      #("runner", runner_to_value(ctx.runner)),
    ]),
  )
}

fn params_to_value(params: types.ResolvedParams) -> InterpValue {
  params
  |> dict.to_list
  |> list.map(fn(pair) {
    #(
      pair.0,
      Str(types.resolved_value_to_env(pair.1)),
    )
  })
  |> dict.from_list
  |> Object
}

fn input_extra_to_value(payload: types_input.InputPayload) -> InterpValue {
  case payload {
    types_input.PayloadChat(_, extra) | types_input.PayloadMixed(_, _, extra) ->
      extra
      |> dict.to_list
      |> list.map(fn(pair) { #(pair.0, input_value_to_value(pair.1)) })
      |> dict.from_list
      |> Object

    types_input.PayloadFiles(_) -> Object(dict.new())
  }
}

fn input_full_to_value(payload: types_input.InputPayload) -> InterpValue {
  case payload {
    types_input.PayloadChat(messages, extra) -> {
      let base = [
        #(
          "messages",
          Array(list.map(messages, chat_message_to_value)),
        ),
      ]
      let extra_fields =
        extra
        |> dict.to_list
        |> list.map(fn(pair) { #(pair.0, input_value_to_value(pair.1)) })

      dict.from_list(list.append(base, extra_fields))
      |> Object
    }

    types_input.PayloadFiles(files) ->
      Object(
        dict.from_list([
          #("files", Array(list.map(files, file_ref_to_value))),
        ]),
      )

    types_input.PayloadMixed(messages, files, extra) -> {
      let base = [
        #(
          "messages",
          Array(list.map(messages, chat_message_to_value)),
        ),
        #(
          "files",
          Array(list.map(files, file_ref_to_value)),
        ),
      ]
      let extra_fields =
        extra
        |> dict.to_list
        |> list.map(fn(pair) { #(pair.0, input_value_to_value(pair.1)) })

      dict.from_list(list.append(base, extra_fields))
      |> Object
    }
  }
}

fn helpers_to_value(payload: types_input.InputPayload) -> InterpValue {
  let types_input.SadHelpers(last_user_content, last_user_files) =
    types_input.derive_helpers(payload)

  Object(
    dict.from_list([
      #("last_user_content", case last_user_content {
        Some(content) -> Str(content)
        None -> Null
      }),
      #(
        "last_user_files",
        Array(list.map(last_user_files, file_ref_to_value)),
      ),
    ]),
  )
}

fn context_to_value(
  ctx: types_input.RequestContext,
  include_extra: Bool,
) -> InterpValue {
  case include_extra {
    True ->
      ctx.extra
      |> dict.fold(dict.new(), fn(fields, key, value) {
        dict.insert(fields, key, Str(value))
      })
      |> dict.insert(
        "trace_id",
        Str(types_core.trace_id_to_string(ctx.trace_id)),
      )
      |> Object

    False ->
      dict.from_list([
        #("trace_id", Str(types_core.trace_id_to_string(ctx.trace_id))),
      ])
      |> Object
  }
}

fn runner_to_value(runner: RunnerAddress) -> InterpValue {
  let RunnerAddress(host:, port:) = runner
  let fields = dict.new()

  let fields = case host {
    Some(value) -> dict.insert(fields, "host", Str(value))
    None -> fields
  }

  let fields = case port {
    Some(value) -> dict.insert(fields, "port", Int(value))
    None -> fields
  }

  Object(fields)
}

fn chat_message_to_value(message: types_input.ChatMessage) -> InterpValue {
  Object(
    dict.from_list([
      #("role", Str(message.role)),
      #("content", Str(message.content)),
    ]),
  )
}

fn file_ref_to_value(file: types_input.FileRef) -> InterpValue {
  Object(
    dict.from_list([
      #("url", Str(file.url)),
      #("mime", Str(file.mime)),
      #("name", Str(file.name)),
      #("context", case file.context {
        Some(ctx) -> Str(ctx)
        None -> Null
      }),
    ]),
  )
}

fn input_value_to_value(value: types_input.InputValue) -> InterpValue {
  case value {
    types_core.StringVal(s) -> Str(s)
    types_core.IntVal(i) -> Int(i)
    types_core.FloatVal(f) -> Float(f)
    types_core.BoolVal(b) -> Bool(b)
    types_core.ListVal(items) -> Array(list.map(items, Str))
  }
}

fn interpolate_value(
  value: InterpValue,
  string_context: InterpValue,
  pointer_context: InterpValue,
) -> Result(InterpValue, InterpolationError) {
  case value {
    Object(fields) ->
      case extract_from_pointer(fields) {
        Some(pointer) -> resolve_pointer(pointer, pointer_context)
        None ->
          fields
          |> dict.to_list
          |> list.try_map(fn(pair) {
            let #(key, field_value) = pair
            use interpolated <- result.try(
              interpolate_value(field_value, string_context, pointer_context),
            )
            Ok(#(key, interpolated))
          })
          |> result.map(fn(entries) { Object(dict.from_list(entries)) })
      }

    Array(items) ->
      items
      |> list.try_map(fn(item) {
        interpolate_value(item, string_context, pointer_context)
      })
      |> result.map(Array)

    Str(text) ->
      interpolate_string_with_context(text, string_context)
      |> result.map(Str)

    _ -> Ok(value)
  }
}

fn interpolate_string_with_context(
  template: String,
  context: InterpValue,
) -> Result(String, InterpolationError) {
  use tokens <- result.try(tokenize(template))
  use parts <- result.try(
    list.try_map(tokens, fn(token) {
      case token {
        Literal(text) -> Ok(text)
        Placeholder(namespace, key) ->
          resolve_placeholder_with_context(namespace, key, context)
      }
    }),
  )
  Ok(string.join(parts, with: ""))
}

fn extract_from_pointer(fields: Dict(String, InterpValue)) -> Option(String) {
  case dict.size(fields) == 1 {
    False -> None
    True ->
      case dict.get(fields, "$from") {
        Ok(value) ->
          case value {
            Str(pointer) -> Some(pointer)
            _ -> None
          }
        Error(_) -> None
      }
  }
}

fn resolve_pointer(
  pointer: String,
  root: InterpValue,
) -> Result(InterpValue, InterpolationError) {
  use parsed_pointer <- result.try(
    json_pointer.parse(pointer)
    |> result.map_error(fn(_) { InvalidPointer(pointer) }),
  )

  case resolve_segments(json_pointer.segments(parsed_pointer), root) {
    Some(resolved) -> Ok(resolved)
    None -> Error(InvalidPointer(pointer))
  }
}

fn resolve_segments(
  segments: List(String),
  current: InterpValue,
) -> Option(InterpValue) {
  case segments {
    [] -> Some(current)
    [segment, ..rest] ->
      case current {
        Object(fields) ->
          case dict.get(fields, segment) {
            Ok(next) -> resolve_segments(rest, next)
            Error(_) -> None
          }
        Array(items) -> resolve_list_segment(segment, rest, items)
        _ -> None
      }
  }
}

fn resolve_list_segment(
  segment: String,
  rest: List(String),
  items: List(InterpValue),
) -> Option(InterpValue) {
  case int.parse(segment) {
    Ok(index) ->
      case index < 0 {
        True -> None
        False ->
          case list.drop(items, index) |> list.first {
            Ok(value) -> resolve_segments(rest, value)
            Error(_) -> None
          }
      }
    Error(_) -> None
  }
}

fn json_to_value(value: json.Json) -> InterpValue {
  let assert Ok(dynamic_value) =
    json.to_string(value)
    |> json.parse(using: decode.dynamic)
  dynamic_to_value(dynamic_value)
}

fn dynamic_to_value(value: dynamic.Dynamic) -> InterpValue {
  case decode.run(value, decode.optional(decode.dynamic)) {
    Ok(None) -> Null
    Ok(Some(inner)) -> dynamic_to_value_non_null(inner)
    Error(_) -> Null
  }
}

fn dynamic_to_value_non_null(value: dynamic.Dynamic) -> InterpValue {
  case first_some(value, [
    try_decode_dict,
    try_decode_list,
    try_decode_string,
    try_decode_bool,
    try_decode_int,
    try_decode_float,
  ]) {
    Some(decoded) -> decoded
    None -> Null
  }
}

fn first_some(
  value: dynamic.Dynamic,
  decoders: List(fn(dynamic.Dynamic) -> Option(InterpValue)),
) -> Option(InterpValue) {
  case decoders {
    [] -> None
    [decoder, ..rest] ->
      case decoder(value) {
        Some(decoded) -> Some(decoded)
        None -> first_some(value, rest)
      }
  }
}

fn try_decode_dict(value: dynamic.Dynamic) -> Option(InterpValue) {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(entries) ->
      entries
      |> dict.to_list
      |> list.map(fn(pair) { #(pair.0, dynamic_to_value(pair.1)) })
      |> dict.from_list
      |> Object
      |> Some
    Error(_) -> None
  }
}

fn try_decode_list(value: dynamic.Dynamic) -> Option(InterpValue) {
  case decode.run(value, decode.list(of: decode.dynamic)) {
    Ok(items) ->
      items
      |> list.map(dynamic_to_value)
      |> Array
      |> Some
    Error(_) -> None
  }
}

fn try_decode_string(value: dynamic.Dynamic) -> Option(InterpValue) {
  case decode.run(value, decode.string) {
    Ok(text) -> Some(Str(text))
    Error(_) -> None
  }
}

fn try_decode_bool(value: dynamic.Dynamic) -> Option(InterpValue) {
  case decode.run(value, decode.bool) {
    Ok(flag) -> Some(Bool(flag))
    Error(_) -> None
  }
}

fn try_decode_int(value: dynamic.Dynamic) -> Option(InterpValue) {
  case decode.run(value, decode.int) {
    Ok(number) -> Some(Int(number))
    Error(_) -> None
  }
}

fn try_decode_float(value: dynamic.Dynamic) -> Option(InterpValue) {
  case decode.run(value, decode.float) {
    Ok(number) -> Some(Float(number))
    Error(_) -> None
  }
}

fn value_to_json(value: InterpValue) -> json.Json {
  case value {
    Null -> json.null()
    Str(text) -> json.string(text)
    Int(number) -> json.int(number)
    Float(number) -> json.float(number)
    Bool(flag) -> json.bool(flag)
    Array(items) -> json.array(items, value_to_json)
    Object(fields) ->
      fields
      |> dict.to_list
      |> list.map(fn(pair) { #(pair.0, value_to_json(pair.1)) })
      |> json.object
  }
}

fn tokenize(template: String) -> Result(List(Token), InterpolationError) {
  do_tokenize(template, [])
}

fn do_tokenize(
  remaining: String,
  tokens: List(Token),
) -> Result(List(Token), InterpolationError) {
  case string.split_once(remaining, on: "{{") {
    Error(_) ->
      Ok(list.reverse(add_literal_token(tokens, remaining)))

    Ok(#(before, after_open)) -> {
      let tokens = add_literal_token(tokens, before)
      case string.split_once(after_open, on: "}}") {
        Error(_) -> Error(InvalidPlaceholder(after_open))
        Ok(#(raw, rest)) -> {
          use placeholder <- result.try(parse_placeholder(raw))
          do_tokenize(rest, [placeholder, ..tokens])
        }
      }
    }
  }
}

fn add_literal_token(tokens: List(Token), text: String) -> List(Token) {
  case string.is_empty(text) {
    True -> tokens
    False -> [Literal(text), ..tokens]
  }
}

fn parse_placeholder(raw: String) -> Result(Token, InterpolationError) {
  case string.split(raw, ".") {
    [namespace, key] ->
      case is_valid_namespace(namespace), is_valid_key(key) {
        True, True -> Ok(Placeholder(namespace: namespace, key: key))
        _, _ -> Error(InvalidPlaceholder(raw))
      }
    _ -> Error(InvalidPlaceholder(raw))
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
