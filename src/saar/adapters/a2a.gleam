////
//// Mission: translate between A2A wire payloads and SAAR core types.
////
//// Responsibilities:
//// - Decode A2A message requests into `saar/types/input.InputPayload`.
//// - Encode `InteractionResult` into A2A `result` payloads.
//// - Produce A2A SSE frames (`task_status` and `message`).
//// - Build A2A Agent Cards derived from an instance profile snapshot.
////
//// Non-responsibilities:
//// - HTTP routing/authentication.
//// - Executing interactions or managing agent lifecycle.
////
//// Relationships:
//// - Used by `saar/gateway/a2a_api` (S16).
//// - Uses `saar/sse` for exact SSE framing.

import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import saar/adapters/a2ui
import saar/json_pointer
import saar/sse
import saar/types/agent as types_agent
import saar/types/core as types_core
import saar/types/enums as types_enums
import saar/types/input as types_input
import saar/types/output as types_output
import saar/types/profile as types_profile
import saar/types/stream
import saar/types/task as types_task

/// A2A message role (user or assistant).
pub type A2aRole {
  User
  Assistant
}

/// A2A message part: text, file reference, or A2UI data.
pub type A2aPart {
  TextPart(text: String)
  FilePart(uri: String, media_type: String, name: String)
  A2uiDataPart(data: json.Json)
}

/// A2A message containing an ID, role, and list of parts.
pub type A2aMessage {
  A2aMessage(message_id: String, role: A2aRole, parts: List(A2aPart))
}

type FileInfo {
  FileInfo(uri: String, media_type: String, name: String)
}

/// Errors that may occur when decoding A2A wire payloads.
pub type DecodeError {
  MissingMessage
  MissingParts
  MissingAgentCardName
  MissingAgentCardUrl
  InvalidRole(raw: String)
  InvalidTaskId(raw: String)
  FileBytesRejected
  A2uiExtensionRequired
  InvalidA2uiMimeType(raw: String)
  InvalidA2uiShape
}

/// Represents which A2A extensions are active for this request.
pub type Extensions {
  NoExtensions
  A2uiV08
}

/// Decoded request body for `message:send` and `message:stream`.
pub type MessageSendRequest {
  MessageSendRequest(message: A2aMessage, context_id: Option(String))
}

/// Converts an A2A message into an `InputPayload`.
///
/// This implements the v0 mapping documented in `docs/arquitectura/protocolos.md`.
pub fn message_to_payload(message: A2aMessage) -> types_input.InputPayload {
  let A2aMessage(role: role, parts: parts, ..) = message
  let role_str = role_to_string(role)

  let #(texts, files_info) = split_parts(parts)

  let files =
    files_info
    |> list.map(fn(info) {
      let FileInfo(uri: uri, media_type: media_type, name: name) = info
      types_input.FileRef(url: uri, mime: media_type, name: name, context: None)
    })

  let content = texts |> string.join("")

  case list.is_empty(files), string.is_empty(content) {
    True, True ->
      types_input.PayloadChat(messages: [], extra_params: dict.new())

    True, False ->
      types_input.PayloadChat(
        messages: [types_input.ChatMessage(role: role_str, content: content)],
        extra_params: dict.new(),
      )

    False, True -> types_input.PayloadFiles(files)

    False, False ->
      types_input.PayloadMixed(
        messages: [types_input.ChatMessage(role: role_str, content: content)],
        files: files,
        extra_params: dict.new(),
      )
  }
}

/// Converts an A2A role to its wire string representation.
pub fn role_to_string(role: A2aRole) -> String {
  case role {
    User -> "user"
    Assistant -> "assistant"
  }
}

fn split_parts(parts: List(A2aPart)) -> #(List(String), List(FileInfo)) {
  parts
  |> list.fold(#([], []), fn(acc, part) {
    let #(texts, files) = acc

    case part {
      TextPart(text: text) -> #([text, ..texts], files)

      FilePart(uri: uri, media_type: media_type, name: name) -> #(texts, [
        FileInfo(uri: uri, media_type: media_type, name: name),
        ..files
      ])

      A2uiDataPart(_) -> #(texts, files)
    }
  })
  |> fn(acc) {
    let #(texts, files) = acc
    #(list.reverse(texts), list.reverse(files))
  }
}

/// Decodes an A2A `message:send` request body.
///
/// Unknown top-level keys and unknown part shapes are ignored.
pub fn decode_message_send_request(
  body: String,
  extensions: Extensions,
) -> Result(MessageSendRequest, DecodeError) {
  use root <- result.try(
    json.parse(body, decode.dynamic)
    |> result.replace_error(MissingMessage),
  )

  let decoder = {
    use message <- decode.field("message", decode.dynamic)
    use context <- decode.optional_field(
      "context",
      dict.new(),
      decode.dict(decode.string, decode.dynamic),
    )
    decode.success(#(message, context))
  }

  use decoded <- result.try(
    decode.run(root, decoder)
    |> result.replace_error(MissingMessage),
  )

  let #(message_dyn, context_dyn) = decoded

  use message <- result.try(decode_message(message_dyn, extensions))

  let context_id = decode_context_id(context_dyn)

  Ok(MessageSendRequest(message: message, context_id: context_id))
}

fn decode_context_id(ctx: dict.Dict(String, dynamic.Dynamic)) -> Option(String) {
  case dict.get(ctx, "contextId") {
    Ok(value) ->
      case decode.run(value, decode.string) {
        Ok(s) -> Some(s)
        Error(_) -> None
      }

    Error(_) -> None
  }
}

fn decode_message(
  value: dynamic.Dynamic,
  extensions: Extensions,
) -> Result(A2aMessage, DecodeError) {
  use obj <- result.try(
    decode.run(value, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error(MissingMessage),
  )

  use message_id <- result.try(
    dict.get(obj, "messageId")
    |> result.map_error(fn(_) { MissingMessage })
    |> result.try(fn(v) {
      decode.run(v, decode.string) |> result.replace_error(MissingMessage)
    }),
  )

  use role <- result.try(
    dict.get(obj, "role")
    |> result.map_error(fn(_) { InvalidRole(raw: "") })
    |> result.try(fn(v) {
      decode.run(v, decode.string)
      |> result.replace_error(InvalidRole(raw: ""))
      |> result.try(role_from_string)
    }),
  )

  use parts_value <- result.try(
    dict.get(obj, "parts")
    |> result.map_error(fn(_) { MissingParts })
    |> result.try(fn(v) {
      decode.run(v, decode.list(of: decode.dynamic))
      |> result.replace_error(MissingParts)
    }),
  )

  let parts =
    parts_value
    |> list.fold(Ok([]), fn(acc, part_dyn) {
      use parts <- result.try(acc)
      use maybe_part <- result.try(decode_part(part_dyn, extensions))

      Ok(case maybe_part {
        None -> parts
        Some(part) -> [part, ..parts]
      })
    })
    |> result.map(list.reverse)

  use parts <- result.try(parts)

  Ok(A2aMessage(message_id: message_id, role: role, parts: parts))
}

fn role_from_string(s: String) -> Result(A2aRole, DecodeError) {
  case s {
    "user" -> Ok(User)
    "assistant" -> Ok(Assistant)
    other -> Error(InvalidRole(raw: other))
  }
}

fn decode_part(
  value: dynamic.Dynamic,
  extensions: Extensions,
) -> Result(Option(A2aPart), DecodeError) {
  // Forward-compatible: unknown shapes are ignored.
  use obj <- result.try(
    decode.run(value, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error(InvalidA2uiShape),
  )

  case dict.get(obj, "text") {
    Ok(text_dyn) ->
      decode.run(text_dyn, decode.string)
      |> result.replace_error(InvalidA2uiShape)
      |> result.map(fn(text) { Some(TextPart(text: text)) })

    Error(_) ->
      case dict.get(obj, "file") {
        Ok(file_dyn) -> decode_file_part(file_dyn)
        Error(_) ->
          case dict.get(obj, "data") {
            Ok(data_dyn) -> decode_a2ui_data_part(obj, data_dyn, extensions)
            Error(_) -> Ok(None)
          }
      }
  }
}

fn decode_file_part(
  value: dynamic.Dynamic,
) -> Result(Option(A2aPart), DecodeError) {
  use obj <- result.try(
    decode.run(value, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error(InvalidA2uiShape),
  )

  use _ <- result.try(case dict.has_key(obj, "bytes") {
    True -> Error(FileBytesRejected)
    False -> Ok(Nil)
  })

  use uri <- result.try(
    dict.get(obj, "uri")
    |> result.map_error(fn(_) { InvalidA2uiShape })
    |> result.try(fn(v) {
      decode.run(v, decode.string) |> result.replace_error(InvalidA2uiShape)
    }),
  )

  let media_type = case dict.get(obj, "mediaType") {
    Ok(v) ->
      case decode.run(v, decode.string) {
        Ok(s) -> s
        Error(_) -> "application/octet-stream"
      }
    Error(_) -> "application/octet-stream"
  }

  let name = case dict.get(obj, "name") {
    Ok(v) ->
      case decode.run(v, decode.string) {
        Ok(s) -> s
        Error(_) -> name_from_uri(uri)
      }
    Error(_) -> name_from_uri(uri)
  }

  Ok(Some(FilePart(uri: uri, media_type: media_type, name: name)))
}

fn decode_a2ui_data_part(
  full_part: dict.Dict(String, dynamic.Dynamic),
  data_dyn: dynamic.Dynamic,
  extensions: Extensions,
) -> Result(Option(A2aPart), DecodeError) {
  case extensions {
    NoExtensions -> Error(A2uiExtensionRequired)

    A2uiV08 -> {
      // Validate metadata.mimeType.
      use meta_dyn <- result.try(
        dict.get(full_part, "metadata")
        |> result.map_error(fn(_) { InvalidA2uiMimeType(raw: "") }),
      )

      use meta <- result.try(
        decode.run(meta_dyn, decode.dict(decode.string, decode.dynamic))
        |> result.replace_error(InvalidA2uiMimeType(raw: "")),
      )

      let mime_type = case dict.get(meta, "mimeType") {
        Ok(v) ->
          case decode.run(v, decode.string) {
            Ok(s) -> s
            Error(_) -> ""
          }
        Error(_) -> ""
      }

      use _ <- result.try(case mime_type == "application/json+a2ui" {
        True -> Ok(Nil)
        False -> Error(InvalidA2uiMimeType(raw: mime_type))
      })

      let data_json = json_pointer.dynamic_to_json(data_dyn)

      case validate_a2ui_json(data_json) {
        Ok(_) -> Ok(Some(A2uiDataPart(data: data_json)))
        Error(_) -> Error(InvalidA2uiShape)
      }
    }
  }
}

fn validate_a2ui_json(payload: json.Json) -> Result(Nil, Nil) {
  let encoded = json.to_string(payload)

  case json.parse(encoded, decode.dict(decode.string, decode.dynamic)) {
    Ok(obj) ->
      case dict.size(obj) == 1 {
        True ->
          case dict.keys(obj) {
            [key] ->
              case key {
                "beginRendering"
                | "surfaceUpdate"
                | "dataModelUpdate"
                | "deleteSurface" -> Ok(Nil)
                _ -> Error(Nil)
              }
            _ -> Error(Nil)
          }

        False -> Error(Nil)
      }

    Error(_) -> Error(Nil)
  }
}

/// Converts a core SAAR error to an A2A RFC7807 payload.
pub fn saar_error_to_a2a_error(err: types_output.SaarError) -> #(Int, json.Json) {
  let #(status, title, type_url) = case err.kind {
    types_enums.BadRequest -> #(
      400,
      "Bad Request",
      "https://a2a-protocol.org/errors/invalid-request",
    )
    types_enums.AgentError -> #(
      422,
      "Unprocessable Entity",
      "https://a2a-protocol.org/errors/upstream-error",
    )
    types_enums.InfraError -> #(
      500,
      "Internal Server Error",
      "https://a2a-protocol.org/errors/infra-error",
    )
  }

  #(
    status,
    json.object([
      #("type", json.string(type_url)),
      #("status", json.int(status)),
      #("title", json.string(title)),
      #("detail", json.string(err.message)),
    ]),
  )
}

/// Returns an SSE `data:` frame formatted by `saar/sse.line`.
pub fn to_sse_line_format(payload: String) -> String {
  sse.line(payload)
}

pub type A2aStreamEvent {
  StreamStarted(task_id: types_core.TraceId, context_id: String)
  ContentChunk(delta: String)
  StreamFinished(artifacts: List(types_output.PublicArtifact))
  StreamError(err: types_output.InteractionError)
}

pub type A2aStreamState {
  A2aStreamState(
    task_id: types_core.TraceId,
    context_id: String,
    extensions: Extensions,
    a2ui_started: Bool,
  )
}

pub fn new_stream(
  task_id: types_core.TraceId,
  context_id: String,
  extensions: Extensions,
) -> A2aStreamState {
  A2aStreamState(
    task_id: task_id,
    context_id: context_id,
    extensions: extensions,
    a2ui_started: False,
  )
}

pub fn convert_stream(
  state: A2aStreamState,
  event: A2aStreamEvent,
) -> #(A2aStreamState, List(stream.StreamEvent)) {
  let A2aStreamState(
    task_id: task_id,
    context_id: context_id,
    extensions: extensions,
    a2ui_started: a2ui_started,
  ) = state

  case event {
    StreamStarted(task_id: task_id, context_id: context_id) -> {
      let payload =
        json.object([
          #("taskId", json.string(types_core.trace_id_to_string(task_id))),
          #("contextId", json.string(context_id)),
          #("status", json.object([#("state", json.string("working"))])),
        ])
        |> json.to_string

      #(state, [stream.event(sse.named_event("task_status", payload))])
    }

    ContentChunk(delta) ->
      case extensions {
        NoExtensions -> {
          let payload = message_text_json(delta)
          #(state, [
            stream.event(sse.named_event("message", json.to_string(payload))),
          ])
        }

        A2uiV08 ->
          case a2ui_started {
            False -> {
              let begin = a2ui.begin_rendering_json(task_id)
              let update = a2ui.data_model_update_json(task_id, delta)

              let msg1 = message_a2ui_json(begin)
              let msg2 = message_a2ui_json(update)

              let next =
                A2aStreamState(
                  task_id: task_id,
                  context_id: context_id,
                  extensions: extensions,
                  a2ui_started: True,
                )

              #(next, [
                stream.event(sse.named_event("message", json.to_string(msg1))),
                stream.event(sse.named_event("message", json.to_string(msg2))),
              ])
            }

            True -> {
              let update = a2ui.data_model_update_json(task_id, delta)
              let msg = message_a2ui_json(update)

              #(state, [
                stream.event(sse.named_event("message", json.to_string(msg))),
              ])
            }
          }
      }

    StreamFinished(artifacts) -> {
      let fields = [
        #("taskId", json.string(types_core.trace_id_to_string(task_id))),
        #("contextId", json.string(context_id)),
        #("status", json.object([#("state", json.string("completed"))])),
      ]

      let fields = case artifacts {
        [] -> fields
        _ ->
          list.append(fields, [
            #("artifacts", json.array(artifacts, encode_a2a_artifact)),
          ])
      }

      let payload = json.object(fields) |> json.to_string

      #(state, [stream.event(sse.named_event("task_status", payload))])
    }

    StreamError(err) -> {
      let payload =
        json.object([
          #("taskId", json.string(types_core.trace_id_to_string(task_id))),
          #("contextId", json.string(context_id)),
          #(
            "status",
            json.object([
              #("state", json.string("failed")),
              #(
                "error",
                json.object([
                  #(
                    "kind",
                    json.string(types_enums.error_kind_to_string(err.kind)),
                  ),
                  #("message", json.string(err.message)),
                  #(
                    "trace_id",
                    json.string(types_core.trace_id_to_string(task_id)),
                  ),
                ]),
              ),
            ]),
          ),
        ])
        |> json.to_string

      #(state, [stream.event(sse.named_event("task_status", payload))])
    }
  }
}

fn message_text_json(delta: String) -> json.Json {
  json.object([
    #("role", json.string("assistant")),
    #(
      "parts",
      json.array(
        [
          json.object([#("text", json.string(delta))]),
        ],
        fn(item) { item },
      ),
    ),
  ])
}

fn message_a2ui_json(data: json.Json) -> json.Json {
  json.object([
    #("role", json.string("assistant")),
    #(
      "parts",
      json.array(
        [
          json.object([
            #("data", data),
            #(
              "metadata",
              json.object([
                #("mimeType", json.string("application/json+a2ui")),
              ]),
            ),
          ]),
        ],
        fn(item) { item },
      ),
    ),
  ])
}

fn ingest_part_json(ingest: json.Json) -> json.Json {
  json.object([
    #("data", json.object([#("ingest", ingest)])),
    #(
      "metadata",
      json.object([
        #("mimeType", json.string("application/json")),
      ]),
    ),
  ])
}

fn message_ingest_json(ingest: json.Json) -> json.Json {
  json.object([
    #("role", json.string("assistant")),
    #(
      "parts",
      json.array(
        [ingest_part_json(ingest)],
        fn(item) { item },
      ),
    ),
  ])
}

fn encode_a2a_artifact(artifact: types_output.PublicArtifact) -> json.Json {
  json.object([
    #("id", json.string(types_core.artifact_id_to_string(artifact.id))),
    #("name", json.string(artifact.name)),
    #("uri", case artifact.url {
      Some(u) -> json.string(u)
      None -> json.null()
    }),
    #("mediaType", json.string(artifact.mime)),
  ])
}

fn message_from_result(result: types_output.InteractionResult) -> json.Json {
  let parts = case result.data.content {
    Some(text) -> [json.object([#("text", json.string(text))])]
    None -> []
  }

  let ingest_part = case dict.get(result.data.metadata, "ingest") {
    Ok(ingest) -> Some(ingest_part_json(ingest))
    Error(_) -> None
  }

  let parts = case ingest_part {
    Some(part) -> list.append(parts, [part])
    None -> parts
  }

  json.object([
    #("role", json.string("assistant")),
    #("parts", json.array(parts, fn(item) { item })),
  ])
}

/// Builds an A2A stream event carrying ingest metadata.
pub fn ingest_data_event(ingest: json.Json) -> stream.StreamEvent {
  let payload = message_ingest_json(ingest) |> json.to_string
  stream.event(sse.named_event("message", payload))
}

fn artifacts_from_result(result: types_output.InteractionResult) -> json.Json {
  json.array(result.artifacts, encode_a2a_artifact)
}

/// Builds an A2A `result` payload from an `InteractionResult`.
pub fn interaction_result_to_task(
  result: types_output.InteractionResult,
  context_id: String,
) -> json.Json {
  json.object([
    #("id", json.string(types_core.trace_id_to_string(result.trace_id))),
    #("contextId", json.string(context_id)),
    #("status", json.object([#("state", json.string("completed"))])),
    #("message", message_from_result(result)),
    #("artifacts", artifacts_from_result(result)),
  ])
}

/// Builds an A2A Task payload from a stored task record.
pub fn task_record_to_task(record: types_task.TaskRecord) -> json.Json {
  let types_task.TaskRecord(id: id, context_id: context_id, status: status, ..) =
    record

  let fields = [
    #("id", json.string(types_core.trace_id_to_string(id))),
    #("contextId", task_context_id(context_id)),
    #("status", task_status_json(status, id)),
  ]

  case status {
    types_task.TaskCompleted(result) ->
      json.object(
        list.append(fields, [
          #("message", message_from_result(result)),
          #("artifacts", artifacts_from_result(result)),
        ]),
      )

    _ -> json.object(fields)
  }
}

fn task_context_id(value: Option(String)) -> json.Json {
  case value {
    Some(id) -> json.string(id)
    None -> json.null()
  }
}

fn task_status_json(
  status: types_task.TaskStatus,
  task_id: types_core.TraceId,
) -> json.Json {
  case status {
    types_task.TaskRunning -> json.object([#("state", json.string("working"))])

    types_task.TaskCompleted(_) ->
      json.object([#("state", json.string("completed"))])

    types_task.TaskFailed(err) ->
      json.object([
        #("state", json.string("failed")),
        #("error", task_error_json(err, task_id)),
      ])

    types_task.TaskCancelled(err) ->
      json.object([
        #("state", json.string("cancelled")),
        #("error", task_error_json(err, task_id)),
      ])
  }
}

fn task_error_json(
  err: types_output.InteractionError,
  task_id: types_core.TraceId,
) -> json.Json {
  json.object([
    #("kind", json.string(types_enums.error_kind_to_string(err.kind))),
    #("message", json.string(err.message)),
    #("trace_id", json.string(types_core.trace_id_to_string(task_id))),
  ])
}

/// Builds an A2A `message:send` JSON response.
pub fn message_send_response(
  result: types_output.InteractionResult,
  context_id: String,
) -> json.Json {
  json.object([
    #("result", interaction_result_to_task(result, context_id)),
  ])
}

/// Builds an A2A Agent Card JSON payload.
pub fn agent_card_from_instance(
  info: types_agent.AgentInfoView,
  base_url: String,
) -> json.Json {
  let types_agent.AgentInfoView(meta: meta, interface: interface, ..) = info

  let types_profile.ProfileMeta(
    id: id,
    name: name,
    description: description,
    ..,
  ) = meta

  let card_name = case name {
    Some(n) -> n
    None -> types_core.profile_id_to_string(id)
  }

  let url =
    base_url
    <> "/instances/"
    <> types_core.instance_id_to_string(info.status.instance_id)
    <> "/a2a"

  let skills = capabilities_to_skills(interface)
  let extensions = agent_card_extensions(interface)

  json.object([
    #("name", json.string(card_name)),
    #("description", json.string(description)),
    #("url", json.string(url)),
    #("version", json.string("1.0.0")),
    #("protocolVersion", json.string("1.0")),
    #(
      "capabilities",
      json.object([
        #("streaming", json.bool(True)),
        #("pushNotifications", json.bool(False)),
      ]),
    ),
    #("extensions", extensions),
    #("skills", json.array(skills, fn(item) { item })),
  ])
}

fn capabilities_to_skills(interface: types_profile.Interface) -> List(json.Json) {
  case interface {
    types_profile.RunnerInterface(caps) ->
      caps
      |> dict.to_list
      |> list.map(fn(pair) {
        let #(id, cap) = pair
        let types_profile.RunnerCapability(
          input_schema: schema,
          description: description,
          files: files,
          ..,
        ) = cap
        skill_json(id, schema, description, files, None)
      })

    types_profile.HttpInterface(_, _, _, caps) ->
      caps
      |> dict.to_list
      |> list.map(fn(pair) {
        let #(id, cap) = pair
        let types_profile.HttpCapability(
          input_schema: schema,
          description: description,
          files: files,
          response: response,
          ..,
        ) = cap
        skill_json(id, schema, description, files, response)
      })
  }
}

fn skill_json(
  id: String,
  schema: Option(types_profile.InputSchema),
  description: Option(String),
  files: Option(types_profile.FilesSemantics),
  response: Option(types_profile.ResponseConfig),
) -> json.Json {
  let desc = case description {
    Some(text) -> text
    None -> ""
  }

  let input_modes = input_modes(schema)
  let output_modes = output_modes(files, response)
  let extensions = skill_extensions(files)

  json.object([
    #("id", json.string(id)),
    #("name", json.string(id)),
    #("description", json.string(desc)),
    #(
      "inputModes",
      json.array(input_modes, fn(item) { json.string(item) }),
    ),
    #(
      "outputModes",
      json.array(output_modes, fn(item) { json.string(item) }),
    ),
    #("extensions", extensions),
  ])
}

fn input_modes(schema: Option(types_profile.InputSchema)) -> List(String) {
  case schema {
    Some(types_profile.SchemaFiles) -> ["file"]
    _ -> ["text"]
  }
}

fn output_modes(
  files: Option(types_profile.FilesSemantics),
  response: Option(types_profile.ResponseConfig),
) -> List(String) {
  let base = ["text"]

  case has_structured_output(files, response) {
    True -> list.append(base, ["data"])
    False -> base
  }
}

fn has_structured_output(
  files: Option(types_profile.FilesSemantics),
  response: Option(types_profile.ResponseConfig),
) -> Bool {
  case files {
    Some(types_profile.FilesSemantics(accepts: True, ..)) -> True
    _ ->
      case response {
        None -> False
        Some(types_profile.ResponseConfig(mapping: mapping, capture: capture)) ->
          dict.size(capture) > 0
          || case mapping {
            types_profile.Artifacts(_) -> True
            types_profile.Both(_, _) -> True
            _ -> False
          }
      }
  }
}

fn skill_extensions(files: Option(types_profile.FilesSemantics)) -> json.Json {
  case files {
    None -> json.object([])
    Some(types_profile.FilesSemantics(
      max_files: max_files,
      ingest_effect: ingest_effect,
      ..,
    )) ->
      json.object([
        #(
          "urn:saar:extensions:files-semantics:v1",
          json.object([
            #("maxFiles", json.int(max_files)),
            #("ingestEffect", case ingest_effect {
              Some(effect) ->
                json.string(types_profile.ingest_effect_to_string(effect))
              None -> json.null()
            }),
          ]),
        ),
      ])
  }
}

fn agent_card_extensions(interface: types_profile.Interface) -> json.Json {
  case interface_has_files_semantics(interface) {
    True -> json.array([
      json.string("urn:saar:extensions:files-semantics:v1"),
    ], fn(item) { item })
    False -> json.array([], fn(item) { item })
  }
}

fn interface_has_files_semantics(interface: types_profile.Interface) -> Bool {
  case interface {
    types_profile.RunnerInterface(caps) ->
      caps
      |> dict.to_list
      |> list.any(fn(pair) {
        let #(_, cap) = pair
        case cap.files {
          Some(_) -> True
          None -> False
        }
      })

    types_profile.HttpInterface(_, _, _, caps) ->
      caps
      |> dict.to_list
      |> list.any(fn(pair) {
        let #(_, cap) = pair
        case cap.files {
          Some(_) -> True
          None -> False
        }
      })
  }
}

/// Validates minimal required Agent Card fields.
pub fn validate_agent_card(card: json.Json) -> Result(Nil, DecodeError) {
  use obj <- result.try(
    json.parse(json.to_string(card), decode.dict(decode.string, decode.dynamic))
    |> result.replace_error(InvalidA2uiShape),
  )

  case dict.has_key(obj, "name"), dict.has_key(obj, "url") {
    True, True -> Ok(Nil)
    False, _ -> Error(MissingAgentCardName)
    True, False -> Error(MissingAgentCardUrl)
  }
}

fn name_from_uri(uri: String) -> String {
  uri
  |> string.split("/")
  |> list.reverse
  |> list.find(fn(seg) { !string.is_empty(seg) })
  |> result.unwrap("file")
}

/// Validates an A2A task id as a UUID-like string (v0 minimal).
pub fn validate_task_id(id: String) -> Result(Nil, DecodeError) {
  case is_uuid_like(id) {
    True -> Ok(Nil)
    False -> Error(InvalidTaskId(raw: id))
  }
}

fn is_uuid_like(value: String) -> Bool {
  case string.split(value, "-") {
    [a, b, c, d, e] ->
      string.length(a) == 8
      && string.length(b) == 4
      && string.length(c) == 4
      && string.length(d) == 4
      && string.length(e) == 12

    _ -> False
  }
}
