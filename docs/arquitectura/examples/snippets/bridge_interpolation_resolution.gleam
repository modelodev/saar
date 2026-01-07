/// Resuelve un placeholder {{namespace.key}} a su valor string.
fn resolve_placeholder(
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

fn resolve_params(key: String, params: ResolvedParams) -> Result(String, InterpolationError) {
  case dict.get(params, key) {
    // Usar resolved_value_to_env porque los valores interpolados van a env/comandos
    Ok(value) -> Ok(resolved_value_to_env(value))
    Error(_) -> Error(UnknownKey("params", key))
  }
}

fn resolve_helpers(key: String, helpers: Option(SadHelpers)) -> Result(String, InterpolationError) {
  case helpers {
    None -> Error(UnknownKey("helpers", key))
    Some(h) -> case key {
      "last_user_content" -> case h.last_user_content {
        Some(content) -> Ok(content)
        None -> Ok("")  // Vacío si no hay mensaje de usuario
      }
      "last_user_files" -> Error(ValueNotScalar("helpers.last_user_files"))
      _ -> Error(UnknownKey("helpers", key))
    }
  }
}

fn resolve_context(key: String, ctx: RequestContext) -> Result(String, InterpolationError) {
  case key {
    "trace_id" -> Ok(trace_id_to_string(ctx.trace_id))
    _ -> Error(UnknownKey("context", key))
  }
}

fn resolve_runner(
  key: String,
  host: Option(String),
  port: Option(Int),
) -> Result(String, InterpolationError) {
  case key {
    "host" -> case host {
      Some(h) -> Ok(h)
      None -> Error(UnknownKey("runner", "host"))
    }
    "port" -> case port {
      Some(p) -> Ok(int.to_string(p))
      None -> Error(UnknownKey("runner", "port"))
    }
    _ -> Error(UnknownKey("runner", key))
  }
}

fn resolve_input(key: String, input: InputPayload) -> Result(String, InterpolationError) {
  // Solo accede a extra_params (valores planos), no a messages ni files
  case input {
    PayloadChat(_, extra) | PayloadMixed(_, _, extra) -> {
      case dict.get(extra, key) {
        Ok(value) -> case is_scalar(value) {
          True -> Ok(value_to_string(value))
          False -> Error(ValueNotScalar("input." <> key))
        }
        Error(_) -> Error(UnknownKey("input", key))
      }
    }
    PayloadFiles(_) -> Error(UnknownKey("input", key))
  }
}
