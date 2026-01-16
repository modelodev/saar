import gleam/http.{type Method}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{type Option, None, Some}
import gleam/string
import httpp/hackney
import httpp/send

/// Respuesta HTTP simplificada para uso interno.
pub type HttpResponse {
  HttpResponse(status: Int, headers: List(#(String, String)), body: String)
}

/// Error de cliente HTTP (ADT reducido).
/// El bridge traduce estos a InteractionError(InfraError, ...).
pub type HttpError {
  /// Error de conexión (DNS, red, refused)
  ConnectionError(String)
  /// Timeout de request
  Timeout
  /// URL malformada
  InvalidUrl(String)
  /// Error de SSL/TLS
  TlsError(String)
  /// Error inesperado
  Unexpected(String)
}

pub fn http_error_to_string(err: HttpError) -> String {
  case err {
    ConnectionError(msg) -> "Connection error: " <> msg
    Timeout -> "Request timeout"
    InvalidUrl(url) -> "Invalid URL: " <> url
    TlsError(msg) -> "TLS error: " <> msg
    Unexpected(msg) -> "HTTP error: " <> msg
  }
}

/// Ejecuta un request HTTP síncrono.
/// 
/// IMPORTANTE: `method` es `http.Method`, NO string.
/// El decoder ya convierte strings a Method; aquí no se parsea.
/// Firma única y estable para facilitar TDD.
pub fn request(
  method: Method,
  url: String,
  headers: Dict(String, String),
  body: Option(Json),
  timeout_ms: Int,
) -> Result(HttpResponse, HttpError) {
  // Construir request de gleam_http
  let req =
    request.new()
    |> request.set_method(method)
    // Ya es Method, no parse
    |> request.set_host(extract_host(url))
    |> request.set_path(extract_path(url))
    |> request.set_scheme(extract_scheme(url))

  // Añadir headers
  let req =
    headers
    |> dict.to_list
    |> list.fold(req, fn(r, h) { request.set_header(r, h.0, h.1) })

  // Añadir body si existe
  let req = case body {
    None -> req
    Some(json) -> request.set_body(req, json.to_string(json))
  }

  // Ejecutar con `httpp` (basado en hackney) y mapear errores al ADT
  // v0: imponer límite de tamaño al body de respuesta (`SaarConfig.max_http_response_bytes`) para evitar OOM.
  case send.send(req) {
    Error(hackney.TimedOut) -> Error(Timeout)
    Error(hackney.ConnectionClosed(_)) ->
      Error(ConnectionError("Connection closed"))
    Error(hackney.InvalidUtf8Response) ->
      Error(Unexpected("Invalid UTF-8 in response"))
    Error(err) -> Error(Unexpected("HTTP error: " <> string.inspect(err)))
    Ok(resp) ->
      Ok(HttpResponse(
        status: resp.status,
        headers: resp.headers,
        body: resp.body,
      ))
  }
}
