//// SAAR CLI entrypoint.
////
//// Mission: provide the `saar` executable entrypoint and map CLI arguments to
//// runtime operations.
////
//// Responsibilities:
//// - Read OS argv.
//// - Delegate parsing to `saar/cli`.
//// - Execute `serve` in foreground/background and daemon operations.
//// - Print user-facing output and exit with the correct code.
////
//// Non-responsibilities:
//// - Implementing HTTP handlers or OTP business logic.
//// - Duplicating CLI parsing rules (owned by `saar/cli`).
////
//// Relationships:
//// - Uses `saar/core/root_supervisor` to start the OTP tree.
//// - Uses `saar/daemon_control` + `saar/daemon_paths` + `saar/ffi/daemon` for
////   daemon-related operations.

import argv
import envoy
import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import saar/app_state
import saar/bridge/http_client
import saar/cli
import saar/cli_http
import saar/config_loader
import saar/core/root_supervisor
import saar/core/supervisor_names
import saar/daemon_control
import saar/daemon_paths
import saar/ffi/daemon
import saar/ffi/signals
import saar/profiles_sources
import saar/types/config as types_config
import saar/types/core as types_core
import simplifile
import tom

/// Represents the planned execution of a CLI command.
///
/// This opaque type holds the exit code, stdout/stderr lines, and any
/// deferred action (e.g., starting the server) that `execute_plan` will run.
pub opaque type RunPlan {
  RunPlan(
    exit_code: Int,
    stdout: List(String),
    stderr: List(String),
    action: Action,
  )
}

/// High-level action kind for inspecting a run plan.
pub type PlanAction {
  PlanNoAction
  PlanServeForeground
  PlanServeBackground
  PlanAgent
}

type Action {
  NoAction
  ServeForeground(ForegroundPlan)
  ServeBackground(BackgroundPlan)
  Agent(AgentPlan)
}

type ForegroundPlan {
  ForegroundPlan(config: types_config.SaarConfig, config_path: String)
}

type BackgroundPlan {
  BackgroundPlan(
    program: String,
    args: List(String),
    pidfile: String,
    logfile: String,
  )
}

type AgentPlan {
  AgentPlan(config: types_config.SaarConfig, command: cli.AgentCommand)
}

type AgentResult {
  AgentSuccess(List(String))
  AgentFailure(List(String))
}

/// Exit code for successful execution.
pub const exit_ok = 0

/// Exit code for usage errors (invalid arguments).
pub const exit_usage = 1

/// Exit code for operational errors (runtime failures).
pub const exit_operational = 2

/// Exit code for validation errors.
pub const exit_validation = 3

/// Main entrypoint. Reads argv, plans the command, and executes it.
pub fn main() {
  let argv.Argv(_runtime, program, args) = argv.load()

  let plan =
    plan(
      argv: args,
      program: program,
      get_env: envoy_get,
      read_file: simplifile.read,
      status: daemon_control.status,
      kill: daemon_control.kill,
    )

  execute_plan(plan)
}

/// Builds a `RunPlan` from CLI arguments without side effects.
///
/// This pure function allows testing CLI behavior by injecting dependencies
/// for environment variables, file reading, and daemon control.
pub fn plan(
  argv argv: List(String),
  program program: String,
  get_env get_env: fn(String) -> Result(String, Nil),
  read_file read_file: fn(String) -> Result(String, simplifile.FileError),
  status status_fn: fn(String) -> daemon_control.Status,
  kill kill_fn: fn(String, Int) -> Result(Nil, daemon_control.KillError),
) -> RunPlan {
  case cli.parse(argv) {
    Ok(cli.Help(_)) -> RunPlan(exit_ok, help_text(), [], NoAction)

    Ok(cli.Version) -> {
      let version = project_version(read_file)
      RunPlan(exit_ok, [version], [], NoAction)
    }

    Ok(cli.Serve(args)) ->
      plan_serve(args, program, get_env, read_file, status_fn, kill_fn)

    Ok(cli.Agent(cmd)) -> plan_agent(cmd, get_env, read_file)

    Ok(cli.Validate(_)) -> unimplemented("validate")
    Ok(cli.DryRun(_)) -> unimplemented("dry-run")
    Ok(cli.RunnerTest(_)) -> unimplemented("runner-test")

    Error(_) -> RunPlan(exit_usage, [], ["usage error"], NoAction)
  }
}

/// Returns the exit code from a `RunPlan`.
pub fn exit_code(plan: RunPlan) -> Int {
  let RunPlan(exit_code: code, ..) = plan
  code
}

/// Returns the high-level action kind from a `RunPlan`.
pub fn action_kind(plan: RunPlan) -> PlanAction {
  let RunPlan(action: action, ..) = plan

  case action {
    NoAction -> PlanNoAction
    ServeForeground(_) -> PlanServeForeground
    ServeBackground(_) -> PlanServeBackground
    Agent(_) -> PlanAgent
  }
}

/// Returns the stdout lines from a `RunPlan`.
pub fn stdout_lines(plan: RunPlan) -> List(String) {
  let RunPlan(stdout: out, ..) = plan
  out
}

/// Returns the stderr lines from a `RunPlan`.
pub fn stderr_lines(plan: RunPlan) -> List(String) {
  let RunPlan(stderr: err, ..) = plan
  err
}

fn envoy_get(name: String) -> Result(String, Nil) {
  envoy.get(name)
  |> result.map_error(fn(_) { Nil })
}

fn execute_plan(plan: RunPlan) -> Nil {
  let RunPlan(exit_code: code, stdout: out, stderr: err, action: action) = plan

  out |> list.each(io.println)
  err |> list.each(io.println_error)

  case action {
    NoAction -> halt(code)

    ServeForeground(ForegroundPlan(config: config, config_path: config_path)) ->
      serve_foreground(config, config_path)

    ServeBackground(background) -> {
      let res = serve_background(background)

      case res {
        Ok(_) -> halt(code)
        Error(_) -> halt(exit_operational)
      }
    }

    Agent(agent_plan) ->
      case execute_agent_plan(agent_plan) {
        AgentSuccess(lines) -> {
          lines |> list.each(io.println)
          halt(code)
        }

        AgentFailure(lines) -> {
          lines |> list.each(io.println_error)
          halt(exit_operational)
        }
      }
  }
}

fn serve_foreground(cfg: types_config.SaarConfig, config_path: String) -> Nil {
  let profiles = profiles_sources.load_profiles_from_sources(cfg)

  case profiles {
    Error(_) -> {
      io.println_error("failed to load profiles")
      halt(exit_operational)
    }

    Ok(initial_profiles) -> {
      let suffix = cfg |> server_port() |> int.to_string
      let names = supervisor_names.new_names_with_suffix(suffix)

      let state =
        app_state.AppState(
          config: cfg,
          config_path: config_path,
          initial_profiles: initial_profiles,
        )

      case root_supervisor.start(state, names) {
        Ok(actor.Started(data: ref, ..)) -> {
          install_sigterm_handler(ref)
          sleep_forever()
        }

        Error(_) -> {
          io.println_error("failed to start supervisor")
          halt(exit_operational)
        }
      }
    }
  }
}

fn server_port(cfg: types_config.SaarConfig) -> Int {
  let types_config.SaarConfig(server_port: port, ..) = cfg
  port
}

fn server_host(cfg: types_config.SaarConfig) -> String {
  let types_config.SaarConfig(server_host: host, ..) = cfg
  host
}

fn effective_config_banner(
  host: String,
  port: Int,
  config_path: String,
) -> String {
  "effective_config host="
  <> host
  <> " port="
  <> int.to_string(port)
  <> " config_path="
  <> config_path
}

fn serve_background(plan: BackgroundPlan) -> Result(Nil, Nil) {
  let BackgroundPlan(
    program: program,
    args: args,
    pidfile: pidfile,
    logfile: logfile,
  ) = plan

  case daemon.daemonize(program, args, pidfile, logfile) {
    Ok(_pid) -> Ok(Nil)
    Error(_) -> Error(Nil)
  }
}

fn sleep_forever() -> Nil {
  process.sleep(60_000)
  sleep_forever()
}

fn install_sigterm_handler(ref: root_supervisor.SupervisorRef) -> Nil {
  let shutdown_subject = root_supervisor.gateway_shutdown(ref)

  case process.subject_owner(shutdown_subject) {
    Ok(pid) -> signals.install_sigterm_handler(pid)
    Error(_) -> Nil
  }
}

fn help_text() -> List(String) {
  [
    "saar serve [--port <port>] [--config <path>] [-b|--background] [-k|--kill] [--status]",
    "saar agent list [--config <path>]",
    "saar agent create --profile <id> --instance <id> [--config <path>]",
    "saar agent status <instance_id> [--config <path>]",
    "saar agent start <instance_id> [--config <path>]",
    "saar agent stop <instance_id> [--config <path>]",
    "saar agent info <instance_id> [--config <path>]",
    "saar agent params <profile_id> [--config <path>]",
    "saar agent capability <profile_id> <capability> [--config <path>]",
    "saar validate <path> [--config <path>]",
    "saar dry-run --profile <id> --input <path> --capability <cap> [--config <path>]",
    "saar runner-test <profile_path> [--input <path>] [--config <path>]",
    "saar runner-test --contract <path> [--input <path>] [--config <path>]",
    "saar --help",
    "saar --version",
  ]
}

fn project_version(
  read_file: fn(String) -> Result(String, simplifile.FileError),
) -> String {
  case read_file("./gleam.toml") {
    Error(_) -> "unknown"
    Ok(raw) ->
      case tom.parse(raw) {
        Error(_) -> "unknown"
        Ok(parsed) ->
          case tom.get_string(parsed, ["version"]) {
            Ok(v) -> v
            Error(_) -> "unknown"
          }
      }
  }
}

fn plan_serve(
  args: cli.ServeArgs,
  program: String,
  get_env: fn(String) -> Result(String, Nil),
  read_file: fn(String) -> Result(String, simplifile.FileError),
  status_fn: fn(String) -> daemon_control.Status,
  kill_fn: fn(String, Int) -> Result(Nil, daemon_control.KillError),
) -> RunPlan {
  let cli.ServeArgs(mode: mode, port: cli_port, config_path: cli_config) = args

  let resolved_config_path =
    config_loader.resolve_config_path_with_env(cli_config, get_env)

  let loaded_cfg =
    config_loader.load_from_path(resolved_config_path, get_env, read_file)

  case loaded_cfg {
    Error(err) -> {
      let msg = "config load failed: " <> string.inspect(err)
      RunPlan(exit_operational, [], [msg], NoAction)
    }

    Ok(cfg0) -> {
      let cfg = apply_port_override(cfg0, cli_port)
      let port = server_port(cfg)

      case mode {
        cli.Status -> {
          let pidfile = daemon_paths.resolve_pidfile_path()
          let st = status_fn(pidfile)
          let msg = daemon_control.status_message(st, port)
          let code = daemon_control.status_exit_code(st)
          RunPlan(code, [msg], [], NoAction)
        }

        cli.Kill -> {
          let pidfile = daemon_paths.resolve_pidfile_path()
          let timeout_ms = shutdown_timeout_ms(cfg)
          let res = kill_fn(pidfile, timeout_ms)
          let code = daemon_control.kill_exit_code(res)

          case res {
            Ok(_) -> RunPlan(code, [], [], NoAction)
            Error(daemon_control.NoServer) -> RunPlan(code, [], [], NoAction)
            Error(_) -> RunPlan(code, [], ["failed to kill"], NoAction)
          }
        }

        cli.Background -> {
          let host = server_host(cfg)
          let banner = effective_config_banner(host, port, resolved_config_path)

          let pidfile = daemon_paths.resolve_pidfile_path()
          let logfile = daemon_paths.resolve_logfile_path()
          let args = background_args(port, resolved_config_path, cli_config)

          RunPlan(
            exit_ok,
            [banner],
            [],
            ServeBackground(BackgroundPlan(
              program: program,
              args: args,
              pidfile: pidfile,
              logfile: logfile,
            )),
          )
        }

        cli.Foreground -> {
          let host = server_host(cfg)
          let banner = effective_config_banner(host, port, resolved_config_path)

          RunPlan(
            exit_ok,
            [banner],
            [],
            ServeForeground(ForegroundPlan(
              config: cfg,
              config_path: resolved_config_path,
            )),
          )
        }
      }
    }
  }
}

fn plan_agent(
  cmd: cli.AgentCommand,
  get_env: fn(String) -> Result(String, Nil),
  read_file: fn(String) -> Result(String, simplifile.FileError),
) -> RunPlan {
  let config_path =
    config_loader.resolve_config_path_with_env(agent_config_path(cmd), get_env)

  let loaded_cfg = config_loader.load_from_path(config_path, get_env, read_file)

  case loaded_cfg {
    Error(err) -> {
      let msg = "config load failed: " <> string.inspect(err)
      RunPlan(exit_operational, [], [msg], NoAction)
    }

    Ok(cfg) ->
      RunPlan(exit_ok, [], [], Agent(AgentPlan(config: cfg, command: cmd)))
  }
}

fn agent_config_path(cmd: cli.AgentCommand) -> Option(String) {
  case cmd {
    cli.AgentList(config_path) -> config_path
    cli.AgentCreate(config_path: config_path, ..) -> config_path
    cli.AgentStatus(config_path: config_path, ..) -> config_path
    cli.AgentStart(config_path: config_path, ..) -> config_path
    cli.AgentStop(config_path: config_path, ..) -> config_path
    cli.AgentInfo(config_path: config_path, ..) -> config_path
    cli.AgentParams(config_path: config_path, ..) -> config_path
    cli.AgentCapability(config_path: config_path, ..) -> config_path
  }
}

fn execute_agent_plan(plan: AgentPlan) -> AgentResult {
  let AgentPlan(config: cfg, command: cmd) = plan

  case cmd {
    cli.AgentList(_) ->
      execute_agent_request(cfg, http.Get, "/sys/agents", None)

    cli.AgentCreate(profile_id: profile_id, instance_id: instance_id, ..) -> {
      let body =
        json.object([
          #("profile_id", json.string(profile_id)),
          #("instance_id", json.string(instance_id)),
        ])
        |> json.to_string

      execute_agent_request(cfg, http.Post, "/sys/agents", Some(body))
    }

    cli.AgentStatus(instance_id: instance_id, ..) ->
      execute_agent_request(
        cfg,
        http.Get,
        "/sys/agents/" <> instance_id <> "/status",
        None,
      )

    cli.AgentStart(instance_id: instance_id, ..) ->
      execute_agent_request(
        cfg,
        http.Post,
        "/sys/agents/" <> instance_id <> "/start",
        None,
      )

    cli.AgentStop(instance_id: instance_id, ..) ->
      execute_agent_request(
        cfg,
        http.Post,
        "/sys/agents/" <> instance_id <> "/stop",
        None,
      )

    cli.AgentInfo(instance_id: instance_id, ..) ->
      execute_agent_request(cfg, http.Get, "/agents/" <> instance_id, None)

    cli.AgentParams(profile_id: profile_id, ..) ->
      execute_agent_params(cfg, profile_id)

    cli.AgentCapability(profile_id: profile_id, capability: capability, ..) ->
      execute_agent_capability(cfg, profile_id, capability)
  }
}

fn execute_agent_request(
  cfg: types_config.SaarConfig,
  method: http.Method,
  path: String,
  body: Option(String),
) -> AgentResult {
  let base_url = cli_http.base_url_from_config(cfg)
  let url = base_url <> path

  let auth = cli_http.auth_header_from_config(cfg)

  let headers =
    dict.new()
    |> dict.insert(auth.0, auth.1)
    |> dict.insert("accept", "application/json")

  let headers = case body {
    None -> headers
    Some(_) -> dict.insert(headers, "content-type", "application/json")
  }

  let types_config.SaarConfig(timeouts: timeouts, limits: limits, ..) = cfg
  let types_config.SaarTimeouts(call_timeout_ms: timeout_ms, ..) = timeouts
  let types_config.SaarLimits(max_http_response_bytes: max_body_bytes, ..) =
    limits

  case
    http_client.request_sync_string(
      method,
      url,
      headers,
      body,
      timeout_ms,
      max_body_bytes,
    )
  {
    Ok(http_client.HttpResponse(status: status, body: response_body, ..)) ->
      case status >= 200 && status < 300 {
        True -> AgentSuccess([response_body])
        False -> AgentFailure([http_error_body(status, response_body)])
      }

    Error(err) -> AgentFailure([http_client.http_error_to_string(err)])
  }
}

fn http_error_body(status: Int, body: String) -> String {
  case string.is_empty(body) {
    True -> "http error " <> int.to_string(status)
    False -> body
  }
}

fn execute_agent_params(
  cfg: types_config.SaarConfig,
  profile_id: String,
) -> AgentResult {
  case profiles_sources.load_profiles_from_sources(cfg) {
    Error(err) ->
      AgentFailure(["failed to load profiles: " <> string.inspect(err)])

    Ok(profiles) -> {
      let id = types_core.profile_id(profile_id)

      case dict.get(profiles, id) {
        Error(_) -> AgentFailure(["profile not found: " <> profile_id])
        Ok(profile) -> {
          let reports = cli_http.resolve_param_status(profile, cfg, envoy_get)

          let header = ["profile: " <> profile_id, "creation params:"]

          let lines = case reports {
            [] -> list.append(header, ["- (none)"])
            _ ->
              list.append(
                header,
                reports |> list.map(cli_http.render_param_report),
              )
          }

          AgentSuccess(lines)
        }
      }
    }
  }
}

fn execute_agent_capability(
  cfg: types_config.SaarConfig,
  profile_id: String,
  capability: String,
) -> AgentResult {
  case profiles_sources.load_profiles_from_sources(cfg) {
    Error(err) ->
      AgentFailure(["failed to load profiles: " <> string.inspect(err)])

    Ok(profiles) -> {
      let id = types_core.profile_id(profile_id)

      case dict.get(profiles, id) {
        Error(_) -> AgentFailure(["profile not found: " <> profile_id])
        Ok(profile) -> {
          case cli_http.capability_schema_lines(profile, capability) {
            Ok(schema_lines) ->
              AgentSuccess([
                "capability: " <> capability,
                "input_schema:",
                ..schema_lines
              ])

            Error(_) -> AgentFailure(["capability not found: " <> capability])
          }
        }
      }
    }
  }
}

fn background_args(
  port: Int,
  resolved_config_path: String,
  cli_config: Option(String),
) -> List(String) {
  let base = ["serve", "--port", int.to_string(port)]

  case cli_config {
    None -> base
    Some(_) -> list.append(base, ["--config", resolved_config_path])
  }
}

fn shutdown_timeout_ms(cfg: types_config.SaarConfig) -> Int {
  let types_config.SaarConfig(timeouts: timeouts, ..) = cfg
  let types_config.SaarTimeouts(shutdown_timeout_ms: ms, ..) = timeouts
  ms
}

fn apply_port_override(
  cfg: types_config.SaarConfig,
  port: Option(Int),
) -> types_config.SaarConfig {
  case port {
    None -> cfg
    Some(p) -> types_config.SaarConfig(..cfg, server_port: p)
  }
}

fn unimplemented(name: String) -> RunPlan {
  RunPlan(exit_operational, [], ["command not implemented: " <> name], NoAction)
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
