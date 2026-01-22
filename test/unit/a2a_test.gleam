import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import saar/adapters/a2a
import saar/types/agent as types_agent
import saar/types/core as types_core
import saar/types/enums as types_enums
import saar/types/input as types_input
import saar/types/output as types_output
import saar/types/profile as types_profile
import saar/types/runner as types_runner
import saar/types/stream

pub fn main() {
  gleeunit.main()
}

pub fn message_to_payload_text_only() {
  let msg =
    a2a.A2aMessage(message_id: "msg-1", role: a2a.User, parts: [
      a2a.TextPart(text: "Hello"),
    ])

  a2a.message_to_payload(msg)
  |> should.equal(types_input.PayloadChat(
    messages: [types_input.ChatMessage(role: "user", content: "Hello")],
    extra_params: dict.new(),
  ))
}

pub fn message_to_payload_files_only() {
  let msg =
    a2a.A2aMessage(message_id: "msg-1", role: a2a.User, parts: [
      a2a.FilePart(
        uri: "https://example.com/doc.pdf",
        media_type: "application/pdf",
        name: "doc.pdf",
      ),
    ])

  a2a.message_to_payload(msg)
  |> should.equal(
    types_input.PayloadFiles([
      types_input.FileRef(
        url: "https://example.com/doc.pdf",
        mime: "application/pdf",
        name: "doc.pdf",
        context: None,
      ),
    ]),
  )
}

pub fn message_to_payload_mixed() {
  let msg =
    a2a.A2aMessage(message_id: "msg-1", role: a2a.User, parts: [
      a2a.TextPart(text: "Hello"),
      a2a.FilePart(
        uri: "https://example.com/doc.pdf",
        media_type: "application/pdf",
        name: "doc.pdf",
      ),
    ])

  a2a.message_to_payload(msg)
  |> should.equal(types_input.PayloadMixed(
    messages: [types_input.ChatMessage(role: "user", content: "Hello")],
    files: [
      types_input.FileRef(
        url: "https://example.com/doc.pdf",
        mime: "application/pdf",
        name: "doc.pdf",
        context: None,
      ),
    ],
    extra_params: dict.new(),
  ))
}

pub fn message_to_payload_empty() {
  let msg = a2a.A2aMessage(message_id: "msg-1", role: a2a.User, parts: [])

  a2a.message_to_payload(msg)
  |> should.equal(types_input.PayloadChat(
    messages: [],
    extra_params: dict.new(),
  ))
}

pub fn interaction_result_to_task() {
  let trace_id = types_core.trace_id("trace-abc-789")

  let result =
    types_output.InteractionResult(
      data: types_output.ResponseData(
        content: Some("Respuesta final."),
        metadata: dict.new(),
      ),
      artifacts: [],
      trace_id: trace_id,
    )

  a2a.interaction_result_to_task(result, "conv-456")
  |> json.to_string
  |> should.equal(
    "{\"id\":\"trace-abc-789\",\"contextId\":\"conv-456\",\"status\":{\"state\":\"completed\"},\"message\":{\"role\":\"assistant\",\"parts\":[{\"text\":\"Respuesta final.\"}]},\"artifacts\":[]}",
  )
}

pub fn agent_card_uses_meta_id() {
  let assert Ok(instance_id) = types_core.instance_id("inst-1")

  let meta =
    types_profile.ProfileMeta(
      id: types_core.profile_id("aider"),
      name: None,
      lifecycle: types_enums.Transient,
      description: "AI pair programmer",
    )

  let runner =
    types_runner.Runner(
      type_: "test",
      tool_config: types_runner.ToolConfigScript("noop"),
      runtime: types_runner.NoNetwork,
      env_map: dict.new(),
      args: [],
      artifact_config: types_runner.default_artifact_config(),
      exec_path: None,
    )

  let status =
    types_agent.AgentStatusView(
      profile_id: types_core.profile_id("aider"),
      instance_id: instance_id,
      lifecycle: types_enums.Transient,
      phase: types_agent.Created,
      mode: types_agent.RunIdle,
      assigned_port: None,
    )

  let info =
    types_agent.AgentInfoView(
      meta: meta,
      runner: runner,
      interface: types_profile.RunnerInterface(dict.new()),
      status: status,
    )

  let card = a2a.agent_card_from_instance(info, "http://localhost:8080")

  json.to_string(card)
  |> should.equal(
    "{\"name\":\"aider\",\"description\":\"AI pair programmer\",\"url\":\"http://localhost:8080/instances/inst-1/a2a\",\"version\":\"1.0.0\",\"protocolVersion\":\"1.0\",\"capabilities\":{\"streaming\":true,\"pushNotifications\":false},\"extensions\":[\"urn:saar:extensions:files-semantics:v1\"],\"skills\":[]}",
  )
}

pub fn saar_error_to_a2a_error() {
  let trace_id = types_core.trace_id("trace-1")

  let bad = types_output.saar_error(trace_id, types_enums.BadRequest, "bad")
  let #(status1, json1) = a2a.saar_error_to_a2a_error(bad)
  status1 |> should.equal(400)
  json.to_string(json1)
  |> should.equal(
    "{\"type\":\"https://a2a-protocol.org/errors/invalid-request\",\"status\":400,\"title\":\"Bad Request\",\"detail\":\"bad\"}",
  )

  let agent = types_output.saar_error(trace_id, types_enums.AgentError, "no")
  let #(status2, _) = a2a.saar_error_to_a2a_error(agent)
  status2 |> should.equal(422)

  let infra = types_output.saar_error(trace_id, types_enums.InfraError, "boom")
  let #(status3, _) = a2a.saar_error_to_a2a_error(infra)
  status3 |> should.equal(500)
}

pub fn to_sse_line_format() {
  a2a.to_sse_line_format("{\"x\":1}")
  |> should.equal("data: {\"x\":1}\n\n")
}

pub fn decode_a2a_message_missing_parts() {
  let body = "{\"message\":{\"messageId\":\"m\",\"role\":\"user\"}}"

  a2a.decode_message_send_request(body, a2a.NoExtensions)
  |> should.equal(Error(a2a.MissingParts))
}

pub fn decode_a2a_message_invalid_role() {
  let body =
    "{\"message\":{\"messageId\":\"m\",\"role\":\"alien\",\"parts\":[{\"text\":\"hi\"}]}}"

  a2a.decode_message_send_request(body, a2a.NoExtensions)
  |> should.equal(Error(a2a.InvalidRole(raw: "alien")))
}

pub fn decode_a2a_task_invalid_id() {
  a2a.validate_task_id("not-a-uuid")
  |> should.equal(Error(a2a.InvalidTaskId(raw: "not-a-uuid")))
}

pub fn decode_a2a_part_unknown_ignored() {
  let body =
    "{\"message\":{\"messageId\":\"m\",\"role\":\"user\",\"parts\":[{\"unknown\":1},{\"text\":\"hi\"}]}}"

  let assert Ok(req) = a2a.decode_message_send_request(body, a2a.NoExtensions)
  let a2a.MessageSendRequest(message: message, ..) = req
  let a2a.A2aMessage(parts: parts, ..) = message

  list.length(parts) |> should.equal(1)
}

pub fn decode_a2a_file_bytes_rejected() {
  let body =
    "{\"message\":{\"messageId\":\"m\",\"role\":\"user\",\"parts\":[{\"file\":{\"bytes\":\"AA\",\"uri\":\"https://x\"}}]}}"

  a2a.decode_message_send_request(body, a2a.NoExtensions)
  |> should.equal(Error(a2a.FileBytesRejected))
}

pub fn decode_a2a_file_media_type_optional() {
  let body =
    "{\"message\":{\"messageId\":\"m\",\"role\":\"user\",\"parts\":[{\"file\":{\"uri\":\"https://example.com/doc.bin\"}}]}}"

  let assert Ok(req) = a2a.decode_message_send_request(body, a2a.NoExtensions)
  let a2a.MessageSendRequest(message: message, ..) = req
  let a2a.A2aMessage(parts: parts, ..) = message

  let assert [a2a.FilePart(media_type: media_type, ..)] = parts
  media_type |> should.equal("application/octet-stream")
}

pub fn decode_a2a_text_parts_concatenated() {
  let msg =
    a2a.A2aMessage(message_id: "msg-1", role: a2a.User, parts: [
      a2a.TextPart(text: "a"),
      a2a.TextPart(text: "b"),
    ])

  let payload = a2a.message_to_payload(msg)

  let assert types_input.PayloadChat(messages: messages, ..) = payload
  let assert [types_input.ChatMessage(content: content, ..)] = messages

  content |> should.equal("ab")
}

pub fn a2a_message_send_shape_exact() {
  let trace_id = types_core.trace_id("trace-abc-789")

  let result =
    types_output.InteractionResult(
      data: types_output.ResponseData(
        content: Some("Respuesta final."),
        metadata: dict.new(),
      ),
      artifacts: [
        types_output.PublicArtifact(
          id: types_core.artifact_id("01J..."),
          name: "report.pdf",
          url: None,
          mime: "application/pdf",
        ),
      ],
      trace_id: trace_id,
    )

  a2a.message_send_response(result, "conv-456")
  |> json.to_string
  |> should.equal(
    "{\"result\":{\"id\":\"trace-abc-789\",\"contextId\":\"conv-456\",\"status\":{\"state\":\"completed\"},\"message\":{\"role\":\"assistant\",\"parts\":[{\"text\":\"Respuesta final.\"}]},\"artifacts\":[{\"id\":\"01J...\",\"name\":\"report.pdf\",\"uri\":null,\"mediaType\":\"application/pdf\"}]}}",
  )
}

pub fn a2a_stream_success_sequence_exact() {
  let task_id = types_core.trace_id("trace-abc-123")
  let ctx = "conv-789"

  let state0 = a2a.new_stream(task_id, ctx, a2a.NoExtensions)

  let #(_state1, started) =
    a2a.convert_stream(
      state0,
      a2a.StreamStarted(task_id: task_id, context_id: ctx),
    )

  let #(state2, messages) =
    a2a.convert_stream(state0, a2a.ContentChunk("partial chunk"))
  let #(_state3, finished) = a2a.convert_stream(state2, a2a.StreamFinished([]))

  let actual =
    started
    |> list.append(messages)
    |> list.append(finished)
    |> list.map(stream.payload)
    |> string.join("")

  let expected =
    "event: task_status\ndata: {\"taskId\":\"trace-abc-123\",\"contextId\":\"conv-789\",\"status\":{\"state\":\"working\"}}\n\n"
    <> "event: message\ndata: {\"role\":\"assistant\",\"parts\":[{\"text\":\"partial chunk\"}]}\n\n"
    <> "event: task_status\ndata: {\"taskId\":\"trace-abc-123\",\"contextId\":\"conv-789\",\"status\":{\"state\":\"completed\"}}\n\n"

  actual |> should.equal(expected)
}

pub fn a2a_stream_error_payload_exact() {
  let task_id = types_core.trace_id("trace-abc-123")
  let ctx = "conv-789"

  let state0 = a2a.new_stream(task_id, ctx, a2a.NoExtensions)

  let err =
    types_output.InteractionError(
      kind: types_enums.AgentError,
      message: "Upstream rejected request",
      trace_id: task_id,
    )

  let #(_state1, events) = a2a.convert_stream(state0, a2a.StreamError(err))

  let actual = events |> list.map(stream.payload) |> string.join("")

  let expected =
    "event: task_status\ndata: {\"taskId\":\"trace-abc-123\",\"contextId\":\"conv-789\",\"status\":{\"state\":\"failed\",\"error\":{\"kind\":\"agent_error\",\"message\":\"Upstream rejected request\",\"trace_id\":\"trace-abc-123\"}}}\n\n"

  actual |> should.equal(expected)
}

pub fn a2ui_data_part_requires_extension() {
  let body =
    "{\"message\":{\"messageId\":\"m\",\"role\":\"user\",\"parts\":[{\"data\":{\"beginRendering\":{\"surfaceId\":\"x\"}},\"metadata\":{\"mimeType\":\"application/json+a2ui\"}}]}}"

  a2a.decode_message_send_request(body, a2a.NoExtensions)
  |> should.equal(Error(a2a.A2uiExtensionRequired))
}

pub fn a2ui_stream_message_shape_exact() {
  let task_id = types_core.trace_id("trace-abc-123")
  let ctx = "conv-789"

  let state0 = a2a.new_stream(task_id, ctx, a2a.A2uiV08)

  let #(_state1, events) = a2a.convert_stream(state0, a2a.ContentChunk("delta"))

  // First chunk emits beginRendering + dataModelUpdate messages.
  list.length(events) |> should.equal(2)

  let assert [first, second] = events

  stream.payload(first)
  |> should.equal(
    "event: message\ndata: {\"role\":\"assistant\",\"parts\":[{\"data\":{\"beginRendering\":{\"surfaceId\":\"trace-abc-123\"}},\"metadata\":{\"mimeType\":\"application/json+a2ui\"}}]}\n\n",
  )

  stream.payload(second)
  |> should.equal(
    "event: message\ndata: {\"role\":\"assistant\",\"parts\":[{\"data\":{\"dataModelUpdate\":{\"surfaceId\":\"trace-abc-123\",\"delta\":\"delta\"}},\"metadata\":{\"mimeType\":\"application/json+a2ui\"}}]}\n\n",
  )
}

pub fn validate_agent_card_missing_name() {
  let card = json.object([#("url", json.string("x"))])
  a2a.validate_agent_card(card) |> should.equal(Error(a2a.MissingAgentCardName))
}

pub fn validate_agent_card_missing_url() {
  let card = json.object([#("name", json.string("x"))])
  a2a.validate_agent_card(card) |> should.equal(Error(a2a.MissingAgentCardUrl))
}
