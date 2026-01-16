import filepath
import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/string
import gleeunit
import gleeunit/should
import port_helpers
import saar/app_state
import saar/bridge/http_client
import saar/config_loader
import saar/core/artifact_registry_protocol
import saar/core/root_supervisor
import saar/core/supervisor_names
import saar/net/tcp_listener
import saar/otp/safe_call
import saar/profiles_sources
import saar/types/config as types_config
import saar/types/core as types_core
import saar/workspace
import simplifile

const api_key = "test-key"

const host = "127.0.0.1"

pub fn main() {
  gleeunit.main()
}

type SaarEnv {
  SaarEnv(
    base_url: String,
    artifact_registry: process.Subject(
      artifact_registry_protocol.ArtifactRegistryMsg,
    ),
    workspaces_dir: String,
  )
}

pub fn get_artifact_serves_file_test() {
  let SaarEnv(base_url: base_url, ..) = start_saar()

  let instance_id = "inst-artifacts-1"
  create_agent(base_url, "artifact_gen", instance_id)
  wait_phase(base_url, instance_id, "ready_transient", 300)

  let url = generate_artifact_url(base_url, instance_id)

  let resp =
    http_client.request_sync_bits(
      http.Get,
      base_url <> url,
      auth_headers(),
      option.None,
      5000,
      1024 * 1024,
    )
    |> assert_ok

  case resp.status {
    200 -> Nil
    other -> {
      let body = case bit_array.to_string(resp.body) {
        Ok(s) -> s
        Error(_) -> "<non-utf8>"
      }
      let msg =
        "GET artifact status=" <> int.to_string(other) <> " body=" <> body
      panic as msg
    }
  }

  should.equal(
    find_header(resp.headers, "content-type"),
    option.Some("application/pdf"),
  )
  should.equal(
    find_header(resp.headers, "x-content-type-options"),
    option.Some("nosniff"),
  )
  should.equal(
    find_header(resp.headers, "content-disposition"),
    option.Some("attachment"),
  )

  let as_string = bit_array.to_string(resp.body) |> result_unwrap
  should.equal(string.contains(as_string, "%PDF-1.4"), True)
}

pub fn get_artifact_auth_required_test() {
  let SaarEnv(base_url: base_url, ..) = start_saar()

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> "/artifacts/any",
      dict.new(),
      option.None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(401)
}

pub fn get_artifact_outside_workspace_test() {
  let SaarEnv(
    base_url: base_url,
    artifact_registry: artifact_registry,
    workspaces_dir: workspaces_dir,
  ) = start_saar()

  let instance_raw = "inst-artifacts-escape-1"
  let assert Ok(instance_id) = types_core.instance_id(instance_raw)

  let root = workspace.workspace_for_instance(workspaces_dir, instance_id)

  let outside_file = "./build/test-artifacts-outside.txt"
  let link_path = filepath.join(root, "escape.txt")

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: outside_file)

  let assert Ok(_) = simplifile.create_directory_all(root)
  let assert Ok(_) = simplifile.write(to: outside_file, contents: "secret")
  let assert Ok(_) =
    simplifile.create_symlink(to: outside_file, from: link_path)

  let assert Ok(path) = workspace.workspace_path_validate("escape.txt")

  let artifact_id =
    safe_call.call(artifact_registry, 1000, fn(reply_to) {
      artifact_registry_protocol.RegisterArtifact(
        path,
        "text/plain",
        instance_id,
        reply_to,
      )
    })
    |> assert_ok

  let url = "/artifacts/" <> types_core.artifact_id_to_string(artifact_id)

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> url,
      auth_headers(),
      option.None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(404)
}

pub fn artifact_after_agent_stopped_test() {
  let SaarEnv(base_url: base_url, ..) = start_saar()

  let instance_id = "inst-artifacts-stop-1"
  create_agent(base_url, "artifact_gen", instance_id)
  wait_phase(base_url, instance_id, "ready_transient", 300)

  let url = generate_artifact_url(base_url, instance_id)

  let _ =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/sys/agents/" <> instance_id <> "/stop",
      auth_headers(),
      option.None,
      5000,
      1024 * 1024,
    )
    |> assert_ok

  wait_phase(base_url, instance_id, "stopped", 300)

  let resp =
    http_client.request_sync_bits(
      http.Get,
      base_url <> url,
      auth_headers(),
      option.None,
      5000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(200)
}

pub fn artifact_after_agent_deleted_test() {
  let SaarEnv(base_url: base_url, ..) = start_saar()

  let instance_id = "inst-artifacts-del-1"
  create_agent(base_url, "artifact_gen", instance_id)
  wait_phase(base_url, instance_id, "ready_transient", 300)

  let url = generate_artifact_url(base_url, instance_id)

  let _ =
    http_client.request_sync_string(
      http.Delete,
      base_url <> "/sys/agents/" <> instance_id,
      auth_headers(),
      option.None,
      5000,
      1024 * 1024,
    )
    |> assert_ok

  let resp =
    http_client.request_sync_string(
      http.Get,
      base_url <> url,
      auth_headers(),
      option.None,
      2000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(404)
}

fn start_saar() -> SaarEnv {
  port_helpers.ensure_wrapper_path()

  let cfg0 =
    config_loader.load_from_path(
      "./test/fixtures/config/test_config.toml",
      fn(name) {
        case name {
          "SAAR_TEST_API_KEY" -> Ok(api_key)
          _ -> Error(Nil)
        }
      },
      simplifile.read,
    )
    |> assert_ok

  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)
  tcp_listener.close(listener)

  let names = supervisor_names.new_names_with_suffix(int.to_string(port))

  let cfg = types_config.SaarConfig(..cfg0, server_port: port)

  let profiles = profiles_sources.load_profiles_from_sources(cfg) |> assert_ok

  let state = app_state.AppState(config: cfg, initial_profiles: profiles)
  let assert Ok(actor.Started(..)) = root_supervisor.start(state, names)

  let supervisor_names.RootNames(_registry, artifact_registry_name, ..) = names

  let types_config.SaarConfig(storage: storage, ..) = cfg
  let types_config.StorageConfig(workspaces_directory: workspaces_dir, ..) =
    storage

  SaarEnv(
    base_url: "http://" <> host <> ":" <> int.to_string(port),
    artifact_registry: process.named_subject(artifact_registry_name),
    workspaces_dir: workspaces_dir,
  )
}

fn auth_headers() -> dict.Dict(String, String) {
  dict.from_list([#("authorization", "Bearer " <> api_key)])
}

fn create_agent(
  base_url: String,
  profile_id: String,
  instance_id: String,
) -> Nil {
  let body =
    "{"
    <> "\"profile_id\":\""
    <> profile_id
    <> "\","
    <> "\"instance_id\":\""
    <> instance_id
    <> "\""
    <> "}"

  http_client.request_sync_string(
    http.Post,
    base_url <> "/sys/agents",
    dict.insert(auth_headers(), "content-type", "application/json"),
    option.Some(body),
    5000,
    1024 * 1024,
  )
  |> assert_ok
  |> fn(resp) { resp.status |> should.equal(201) }

  Nil
}

fn generate_artifact_url(base_url: String, instance_id: String) -> String {
  let body =
    "{"
    <> "\"capability\":\"generate\","
    <> "\"inputs\":{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]},"
    <> "\"context\":{\"trace_id\":\"trace-artifacts-1\"}"
    <> "}"

  let resp =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/agents/" <> instance_id <> "/interact",
      dict.insert(auth_headers(), "content-type", "application/json"),
      option.Some(body),
      5000,
      1024 * 1024,
    )
    |> assert_ok

  case resp.status {
    200 -> Nil
    other -> {
      let msg =
        "POST /interact failed status="
        <> int.to_string(other)
        <> " body="
        <> resp.body
      panic as msg
    }
  }

  let url = extract_json_field(resp.body, "url")

  url
}

fn extract_json_field(body: String, field: String) -> String {
  let needle = "\"" <> field <> "\":\""

  case string.split_once(body, on: needle) {
    Ok(#(_before, after)) ->
      case string.split_once(after, on: "\"") {
        Ok(#(value, _rest)) -> value
        Error(_) -> panic as "missing field terminator"
      }

    Error(_) -> panic as "missing field"
  }
}

fn wait_phase(
  base_url: String,
  instance_id: String,
  expected_phase: String,
  attempts: Int,
) -> Nil {
  case attempts {
    0 -> panic as "Timed out waiting for phase"

    _ -> {
      let resp =
        http_client.request_sync_string(
          http.Get,
          base_url <> "/sys/agents/" <> instance_id <> "/status",
          auth_headers(),
          option.None,
          1000,
          1024 * 1024,
        )
        |> assert_ok

      resp.status |> should.equal(200)

      case string.contains(resp.body, "\"phase\":\"failed\"") {
        True -> {
          let msg = "Agent failed: " <> resp.body
          panic as msg
        }
        False -> Nil
      }

      case
        string.contains(resp.body, "\"phase\":\"" <> expected_phase <> "\"")
      {
        True -> Nil
        False -> {
          process.sleep(25)
          wait_phase(base_url, instance_id, expected_phase, attempts - 1)
        }
      }
    }
  }
}

fn find_header(
  headers: List(#(String, String)),
  key: String,
) -> option.Option(String) {
  headers
  |> list.fold(option.None, fn(acc, pair) {
    case acc {
      option.Some(_) -> acc
      option.None ->
        case string.lowercase(pair.0) == key {
          True -> option.Some(pair.1)
          False -> option.None
        }
    }
  })
}

fn result_unwrap(value: Result(a, e)) -> a {
  case value {
    Ok(v) -> v
    Error(_) -> panic as "unexpected error"
  }
}

fn assert_ok(value: Result(a, e)) -> a {
  case value {
    Ok(v) -> v
    Error(e) -> panic as string.inspect(e)
  }
}
