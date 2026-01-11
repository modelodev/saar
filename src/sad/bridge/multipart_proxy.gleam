//// Multipart proxy for URL-backed files.
////
//// Mission: send URL-backed `FileRef`s to HTTP agents using multipart/form-data.
////
//// Responsibilities:
//// - Fetch file bytes from `FileRef.url` with `max_file_fetch_bytes` limits.
//// - Build a multipart body that supports binary files (PDF, images, etc.).
//// - Send multipart requests using the bridge HTTP client.
//// - Execute multiple uploads as N requests (fail-fast).
////
//// Non-responsibilities:
//// - Accepting inbound uploads to SAD.
//// - Retrying or readiness waiting.
////
//// Relationships:
//// - Uses `sad/bridge/http_client` for HTTP and file fetching.
//// - Used by higher-level HTTP capability execution.

import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/http.{type Method}
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import sad/bridge/http_client
import sad/ffi
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/input as types_input
import sad/types/output as types_output

/// Rejects multipart when `streaming` is enabled.
pub fn ensure_multipart_allowed(
  trace_id: types_core.TraceId,
  streaming: Bool,
) -> Result(Nil, types_output.InteractionError) {
  case streaming {
    True ->
      Error(types_output.sad_error(
        trace_id,
        types_enums.BadRequest,
        "Multipart body is not supported for streaming in v0",
      ))
    False -> Ok(Nil)
  }
}

/// Builds and sends a multipart request for a single input file.
///
/// The file content is fetched from `file.url` and bounded by `limits.max_file_fetch_bytes`.
pub fn request_multipart_file(
  trace_id: types_core.TraceId,
  method: Method,
  url: String,
  headers: Dict(String, String),
  fields: Dict(String, String),
  file_field: String,
  file: types_input.FileRef,
  streaming: Bool,
  config: types_config.SadConfig,
  timeout_ms: Int,
) -> Result(http_client.HttpResponse, types_output.InteractionError) {
  use _ <- result.try(ensure_multipart_allowed(trace_id, streaming))

  let types_config.SadConfig(limits: limits, ..) = config
  let types_config.SadLimits(
    max_file_fetch_bytes: max_file_bytes,
    max_http_response_bytes: max_resp_bytes,
    ..,
  ) = limits

  use file_bits <- result.try(
    http_client.fetch_bits(file.url, timeout_ms, max_file_bytes)
    |> result.map_error(fn(err) {
      types_output.sad_error(
        trace_id,
        types_enums.InfraError,
        "File fetch failed: " <> http_client.http_error_to_string(err),
      )
    }),
  )

  let #(boundary, body) = build_multipart(fields, file_field, file, file_bits)

  let headers =
    headers
    |> dict.insert("content-type", "multipart/form-data; boundary=" <> boundary)

  http_client.request_sync_bytes(
    method,
    url,
    headers,
    Some(body),
    timeout_ms,
    max_resp_bytes,
  )
  |> result.map_error(fn(err) {
    types_output.sad_error(
      trace_id,
      types_enums.InfraError,
      http_client.http_error_to_string(err),
    )
  })
}

/// Sends multiple multipart uploads as N requests (fail-fast).
///
/// Returns a list of responses in the same order as `files`.
pub fn request_multipart_files(
  trace_id: types_core.TraceId,
  method: Method,
  url: String,
  headers: Dict(String, String),
  fields: Dict(String, String),
  file_field: String,
  files: List(types_input.FileRef),
  streaming: Bool,
  config: types_config.SadConfig,
  timeout_ms: Int,
) -> Result(List(http_client.HttpResponse), types_output.InteractionError) {
  use _ <- result.try(ensure_multipart_allowed(trace_id, streaming))

  files
  |> list.try_map(fn(file) {
    request_multipart_file(
      trace_id,
      method,
      url,
      headers,
      fields,
      file_field,
      file,
      streaming,
      config,
      timeout_ms,
    )
  })
}

fn build_multipart(
  fields: Dict(String, String),
  file_field: String,
  file: types_input.FileRef,
  file_bits: BitArray,
) -> #(String, bytes_tree.BytesTree) {
  let boundary =
    "sad_boundary_" <> int.to_string(int.absolute_value(ffi.now_ms()))

  let field_trees =
    fields
    |> dict.to_list
    |> list.map(fn(pair) {
      bytes_tree.from_string(
        "--"
        <> boundary
        <> "\r\n"
        <> "Content-Disposition: form-data; name=\""
        <> pair.0
        <> "\"\r\n\r\n"
        <> pair.1
        <> "\r\n",
      )
    })

  let types_input.FileRef(url: _, mime: mime, name: name, context: _) = file

  let file_headers =
    bytes_tree.from_string(
      "--"
      <> boundary
      <> "\r\n"
      <> "Content-Disposition: form-data; name=\""
      <> file_field
      <> "\"; filename=\""
      <> name
      <> "\"\r\n"
      <> "Content-Type: "
      <> mime
      <> "\r\n\r\n",
    )

  let file_body = bytes_tree.from_bit_array(file_bits)

  let file_trailer = bytes_tree.from_string("\r\n")

  let end = bytes_tree.from_string("--" <> boundary <> "--\r\n")

  let body =
    bytes_tree.concat(
      list.append(field_trees, [file_headers, file_body, file_trailer, end]),
    )

  #(boundary, body)
}
