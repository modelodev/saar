/// Interpola un string. Falla si falta algún placeholder.
/// Sintaxis soportada: {{namespace.key}} (solo un nivel de profundidad)
/// - namespace: `[A-Za-z0-9_]+` (en la práctica: uno de los namespaces soportados)
/// - key: `[A-Za-z0-9_-]+` (incluye guiones, ej: `api-key`)
pub fn interpolate_string(
  template: String,
  ctx: InterpContext,
) -> Result(String, InterpolationError) {
  // 1. Buscar todos los placeholders con regex: \{\{([A-Za-z0-9_]+)\.([A-Za-z0-9_-]+)\}\}
  // 2. Para cada match, resolver el valor
  // 3. Si alguno falla, retornar Error
  // 4. Si todos OK, sustituir y retornar el string

  let placeholder_regex =
    regexp.from_string("\\{\\{([A-Za-z0-9_]+)\\.([A-Za-z0-9_-]+)\\}\\}")

  regexp.scan(placeholder_regex, template)
  |> list.try_fold(template, fn(acc, match) {
    let assert [namespace, key] = match.submatches
    use value <- result.try(resolve_placeholder(namespace, key, ctx))
    Ok(string.replace(acc, match.content, value))
  })
}

/// Interpola un Dict de strings (para env_map, headers).
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

/// Interpola una lista de strings (para args).
pub fn interpolate_list(
  templates: List(String),
  ctx: InterpContext,
) -> Result(List(String), InterpolationError) {
  list.try_map(templates, fn(t) { interpolate_string(t, ctx) })
}

/// Interpola recursivamente los valores string de un JSON.
/// Las claves NO se interpolan, solo los valores.
/// Además soporta inserción de valores estructurados vía:
///   {"$from": "/json/pointer"}  (RFC 6901) sobre el `SAD_INPUT_JSON`.
/// Esto permite inyectar listas/objetos (ej. `/input/messages`) sin extender la sintaxis `{{...}}`.
pub fn interpolate_json(
  template: Json,
  ctx: InterpContext,
) -> Result(Json, InterpolationError) {
  case template {
    json.String(s) -> {
      use interpolated <- result.try(interpolate_string(s, ctx))
      Ok(json.String(interpolated))
    }
    // Inserción estructurada por JSON Pointer: {"$from": "/input/messages"}
    // El puntero se resuelve contra la estructura de `SAD_INPUT_JSON`.
    // (Conceptual: implementar resolviendo sobre el Json generado por sad_input_to_json()).
    json.Object([#("$from", json.String(ptr))]) ->
      resolve_from_sad_input_json(ptr, ctx)
    json.Object(fields) -> {
      fields
      |> list.try_map(fn(pair) {
        let #(k, v) = pair
        use interpolated_v <- result.try(interpolate_json(v, ctx))
        Ok(#(k, interpolated_v))
        // Claves NO se interpolan
      })
      |> result.map(json.Object)
    }
    json.Array(items) -> {
      items
      |> list.try_map(fn(item) { interpolate_json(item, ctx) })
      |> result.map(json.Array)
    }
    // Int, Float, Bool, Null: dejar intactos
    other -> Ok(other)
  }
}
