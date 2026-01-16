/// Ejecuta health check contra servidor continuous.
/// Usa health_check_timeout_ms de config.
pub fn health_check(
  interface: Interface,
  config: SaarConfig,
  trace_id: TraceId,
) -> Result(Nil, InteractionError) {
  case interface {
    RunnerInterface(_) -> Ok(Nil)
    // No aplica
    HttpInterface(base_url, headers, health_check, _) -> {
      case health_check {
        None -> Ok(Nil)
        // Sin health check configurado
        Some(hc) -> {
          let url = base_url <> hc.path
          // hc.method ya es http.Method (parseado por decoder)
          // Firma: request(Method, String, Dict, Option(Json), Int)
          let result =
            request(
              hc.method,
              url,
              headers,
              None,
              config.health_check_timeout_ms,
            )

          case result {
            Error(err) ->
              Error(InteractionError(
                InfraError,
                "Health check failed: " <> http_error_to_string(err),
                trace_id,
              ))
            Ok(response) -> {
              case list.contains(hc.expect_statuses, response.status) {
                True -> Ok(Nil)
                False ->
                  Error(InteractionError(
                    InfraError,
                    "Health check returned " <> int.to_string(response.status),
                    trace_id,
                  ))
              }
            }
          }
        }
      }
    }
  }
}
