/// Resuelve un placeholder {{namespace.key}} a su valor string.
fn resolve_placeholder(
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
