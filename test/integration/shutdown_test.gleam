import envoy
import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import gleeunit
import gleeunit/should
import port_helpers
import saar/app_state
import saar/bridge/http_client
import saar/config_loader
import saar/core/messages
import saar/core/root_supervisor
import saar/core/shutdown_all
import saar/core/supervisor_names
import saar/daemon_control
import saar/ffi/daemon as daemon_ffi
import saar/net/tcp_listener
import saar/profiles_sources
import saar/types/config as types_config
import simplifile

const host = "127.0.0.1"

const api_key = "test-key"

const config_path = "./test/fixtures/config/test_config.toml"

pub fn main() {
  gleeunit.main()
}

pub fn shutdown_completes_inflight_request_test() {
  let #(pid, base_url, pidfile) =
    start_external_saar("build/test-workspaces/shutdown-inflight")

  let instance_id = "inst-shutdown-inflight"
  create_agent(base_url, "echo_server", instance_id)
  wait_phase(base_url, instance_id, "ready_continuous", 300)

  let reply = process.new_subject()
  spawn_sleep_request(reply, base_url, instance_id, 1500, 7000)

  // Ensure the request is in-flight.
  process.sleep(50)

  let kill_reply = process.new_subject()
  spawn_kill(kill_reply, pidfile, 2000)

  // The in-flight request must still complete.
  let interact_res = process.receive(reply, 8000) |> assert_ok |> assert_ok
  interact_res.status |> should.equal(200)

  let kill_res = process.receive(kill_reply, 5000) |> assert_ok
  case kill_res {
    Ok(_) -> Nil
    Error(_) -> panic as "Expected kill ok"
  }

  // PID file is deleted by the server shutdown flow.
  should.equal(pidfile_exists(pidfile), False)
  wait_process_dead(pid, 40)
  should.equal(daemon_ffi.process_alive(pid), False)
}

pub fn shutdown_rejects_new_requests_test() {
  let #(pid, base_url, pidfile) =
    start_external_saar("build/test-workspaces/shutdown-reject")

  let instance_id = "inst-shutdown-reject"
  create_agent(base_url, "echo_server", instance_id)
  wait_phase(base_url, instance_id, "ready_continuous", 300)

  let reply = process.new_subject()
  spawn_sleep_request(reply, base_url, instance_id, 1500, 7000)
  process.sleep(50)

  let kill_reply = process.new_subject()
  spawn_kill(kill_reply, pidfile, 2000)

  // Wait until the gateway starts rejecting new requests.
  let resp = wait_for_rejecting_health(base_url, 40)
  resp.status |> should.equal(503)
  should.equal(string.contains(resp.body, "\"code\":\"shutting_down\""), True)

  // Shutdown should still complete normally.
  let _ = process.receive(reply, 8000)
  let _ = process.receive(kill_reply, 5000)

  should.equal(pidfile_exists(pidfile), False)
  wait_process_dead(pid, 40)
  should.equal(daemon_ffi.process_alive(pid), False)
}

pub fn shutdown_force_kills_after_timeout_test() {
  let #(pid, base_url, pidfile) =
    start_external_saar("build/test-workspaces/shutdown-timeout")

  let instance_id = "inst-shutdown-timeout"
  create_agent(base_url, "echo_server", instance_id)
  wait_phase(base_url, instance_id, "ready_continuous", 300)

  let reply = process.new_subject()
  spawn_sleep_request(reply, base_url, instance_id, 5000, 7000)
  process.sleep(50)

  let kill_reply = process.new_subject()
  spawn_kill(kill_reply, pidfile, 2000)

  // The interaction should not complete successfully.
  let interact_res = process.receive(reply, 8000) |> assert_ok
  case interact_res {
    Ok(resp) -> should.equal(resp.status == 200, False)
    Error(_) -> Nil
  }

  let kill_res = process.receive(kill_reply, 5000) |> assert_ok
  case kill_res {
    Ok(_) -> Nil
    Error(_) -> panic as "Expected kill ok"
  }

  should.equal(pidfile_exists(pidfile), False)
  wait_process_dead(pid, 40)
  should.equal(daemon_ffi.process_alive(pid), False)
}

pub fn shutdown_sends_terminate_to_all_agents_test() {
  let #(base_url, registry) = start_inprocess_saar()

  let id1 = "inst-shutdown-all-1"
  let id2 = "inst-shutdown-all-2"

  create_agent(base_url, "echo_cli", id1)
  create_agent(base_url, "echo_cli", id2)

  wait_phase(base_url, id1, "ready_transient", 200)
  wait_phase(base_url, id2, "ready_transient", 200)

  should.equal(shutdown_all.all_instances_stopped(registry, 1000), False)

  shutdown_all.send_terminate_to_all(registry, 1000)
  wait_registry_empty(registry, 200)
}

fn start_external_saar(root: String) -> #(Int, String, String) {
  port_helpers.ensure_wrapper_path()

  let pidfile = root <> "/saar.pid"
  let logfile = root <> "/saar.log"

  let _ = simplifile.delete(file_or_dir_at: root)
  let assert Ok(_) = simplifile.create_directory_all(root)

  envoy.set("SAAR_TEST_API_KEY", api_key)
  envoy.set("SAAR_PID_FILE", pidfile)
  envoy.set("SAAR_LOG_FILE", logfile)
  envoy.set("ERL_LIBS", "build/dev/erlang")

  let port = free_port()

  let pid =
    daemon_ffi.daemonize(
      "erl",
      [
        "-noshell",
        "-eval",
        "application:ensure_all_started(hackney), saar:main().",
        "-extra",
        "serve",
        "--port",
        int.to_string(port),
        "--config",
        config_path,
      ],
      pidfile,
      logfile,
    )
    |> assert_ok_pid

  let base_url = "http://" <> host <> ":" <> int.to_string(port)
  wait_health_ok(base_url, 60)

  #(pid, base_url, pidfile)
}

fn spawn_kill(
  reply_to: process.Subject(Result(Nil, daemon_control.KillError)),
  pidfile: String,
  timeout_ms: Int,
) -> Nil {
  let _ =
    process.spawn(fn() {
      let res = daemon_control.kill(pidfile, timeout_ms)
      process.send(reply_to, res)
    })
  Nil
}

fn spawn_sleep_request(
  reply_to: process.Subject(
    Result(http_client.HttpResponse, http_client.HttpError),
  ),
  base_url: String,
  instance_id: String,
  sleep_ms: Int,
  timeout_ms: Int,
) -> Nil {
  let _ =
    process.spawn(fn() {
      let url =
        base_url
        <> "/agents/"
        <> instance_id
        <> "/ui/sleep?ms="
        <> int.to_string(sleep_ms)

      let res =
        http_client.request_sync_string(
          http.Get,
          url,
          auth_headers(),
          None,
          timeout_ms,
          1024 * 1024,
        )

      process.send(reply_to, res)
    })

  Nil
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

  let resp =
    http_client.request_sync_string(
      http.Post,
      base_url <> "/sys/agents",
      dict.insert(auth_headers(), "content-type", "application/json"),
      Some(body),
      5000,
      1024 * 1024,
    )
    |> assert_ok

  resp.status |> should.equal(201)
}

fn wait_health_ok(base_url: String, attempts: Int) -> Nil {
  case attempts {
    0 -> panic as "Timed out waiting for /health"
    _ ->
      case
        http_client.request_sync_string(
          http.Get,
          base_url <> "/health",
          dict.new(),
          None,
          250,
          1024 * 1024,
        )
      {
        Ok(resp) if resp.status == 200 -> Nil
        _ -> {
          process.sleep(50)
          wait_health_ok(base_url, attempts - 1)
        }
      }
  }
}

fn wait_for_rejecting_health(
  base_url: String,
  attempts: Int,
) -> http_client.HttpResponse {
  case attempts {
    0 -> panic as "Timed out waiting for 503"
    _ ->
      case
        http_client.request_sync_string(
          http.Get,
          base_url <> "/health",
          dict.new(),
          None,
          250,
          1024 * 1024,
        )
      {
        Ok(resp) if resp.status == 503 -> resp
        _ -> {
          process.sleep(25)
          wait_for_rejecting_health(base_url, attempts - 1)
        }
      }
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
          None,
          1000,
          1024 * 1024,
        )
        |> assert_ok

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

fn wait_registry_empty(
  registry: process.Subject(messages.RegistryMsg),
  attempts: Int,
) -> Nil {
  case attempts {
    0 -> panic as "Timed out waiting for registry to empty"
    _ ->
      case shutdown_all.all_instances_stopped(registry, 1000) {
        True -> Nil
        False -> {
          process.sleep(50)
          wait_registry_empty(registry, attempts - 1)
        }
      }
  }
}

fn free_port() -> Int {
  let assert Ok(#(listener, port)) = tcp_listener.listen(host, 0)
  tcp_listener.close(listener)
  port
}

fn auth_headers() -> dict.Dict(String, String) {
  dict.from_list([#("authorization", "Bearer " <> api_key)])
}

fn pidfile_exists(pidfile_path: String) -> Bool {
  case simplifile.read(pidfile_path) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn wait_process_dead(pid: Int, attempts: Int) -> Nil {
  case attempts {
    0 -> Nil

    _ ->
      case daemon_ffi.process_alive(pid) {
        True -> {
          process.sleep(50)
          wait_process_dead(pid, attempts - 1)
        }

        False -> Nil
      }
  }
}

fn start_inprocess_saar() -> #(String, process.Subject(messages.RegistryMsg)) {
  port_helpers.ensure_wrapper_path()

  envoy.set("SAAR_TEST_API_KEY", api_key)

  let cfg0 = load_cfg0()
  let profiles = profiles_sources.load_profiles_from_sources(cfg0) |> assert_ok

  let port = free_port()
  let names = supervisor_names.new_names_with_suffix(int.to_string(port))
  let cfg = types_config.SaarConfig(..cfg0, server_port: port)

  let state =
    app_state.AppState(
      config: cfg,
      config_path: config_path,
      initial_profiles: profiles,
    )

  let assert Ok(actor.Started(data: ref, ..)) =
    root_supervisor.start(state, names)

  #(
    "http://" <> host <> ":" <> int.to_string(port),
    root_supervisor.registry(ref),
  )
}

fn load_cfg0() -> types_config.SaarConfig {
  config_loader.load_from_path(
    config_path,
    fn(name) {
      case name {
        "SAAR_TEST_API_KEY" -> Ok(api_key)
        _ -> Error(Nil)
      }
    },
    simplifile.read,
  )
  |> assert_ok
}

fn assert_ok(value: Result(a, b)) -> a {
  case value {
    Ok(v) -> v
    Error(_) -> panic as "Expected Ok"
  }
}

fn assert_ok_pid(value: Result(Int, daemon_ffi.DaemonError)) -> Int {
  case value {
    Ok(pid) -> pid
    Error(_) -> panic as "Expected Ok(pid)"
  }
}
