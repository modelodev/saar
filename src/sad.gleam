//// SAD CLI entrypoint.
////
//// Mission: provide the `sad` executable entrypoint and map CLI arguments to
//// runtime operations.
////
//// Responsibilities:
//// - Read OS argv.
//// - Delegate parsing to `sad/cli`.
//// - Execute `serve` in foreground/background and daemon operations.
//// - Print user-facing output and exit with the correct code.
////
//// Non-responsibilities:
//// - Implementing HTTP handlers or OTP business logic.
//// - Duplicating CLI parsing rules (owned by `sad/cli`).
////
//// Relationships:
//// - Uses `sad/core/root_supervisor` to start the OTP tree.
//// - Uses `sad/daemon_control` + `sad/daemon_paths` + `sad/ffi/daemon` for
////   daemon-related operations.

import argv
import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sad/app_state
import sad/cli
import sad/config_loader
import sad/core/root_supervisor
import sad/core/supervisor_names
import sad/daemon_control
import sad/daemon_paths
import sad/ffi/daemon
import sad/profiles_sources
import sad/types/config as types_config
import simplifile
import tom

pub opaque type RunPlan {
  RunPlan(
    exit_code: Int,
    stdout: List(String),
    stderr: List(String),
    action: Action,
  )
}

type Action {
  NoAction
  ServeForeground(ForegroundPlan)
  ServeBackground(BackgroundPlan)
}

type ForegroundPlan {
  ForegroundPlan(config: types_config.SadConfig, config_path: String)
}

type BackgroundPlan {
  BackgroundPlan(
    program: String,
    args: List(String),
    pidfile: String,
    logfile: String,
    timeout_ms: Int,
  )
}

pub const exit_ok = 0

pub const exit_usage = 1

pub const exit_operational = 2

pub const exit_validation = 3

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

    Ok(cli.Validate(_)) -> unimplemented("validate")
    Ok(cli.DryRun(_)) -> unimplemented("dry-run")
    Ok(cli.RunnerTest(_)) -> unimplemented("runner-test")

    Error(_) -> RunPlan(exit_usage, [], ["usage error"], NoAction)
  }
}

pub fn exit_code(plan: RunPlan) -> Int {
  let RunPlan(exit_code: code, ..) = plan
  code
}

pub fn stdout_lines(plan: RunPlan) -> List(String) {
  let RunPlan(stdout: out, ..) = plan
  out
}

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
  }
}

fn serve_foreground(cfg: types_config.SadConfig, _config_path: String) -> Nil {
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
        app_state.AppState(config: cfg, initial_profiles: initial_profiles)

      case root_supervisor.start(state, names) {
        Ok(_) -> sleep_forever()
        Error(_) -> {
          io.println_error("failed to start supervisor")
          halt(exit_operational)
        }
      }
    }
  }
}

fn server_port(cfg: types_config.SadConfig) -> Int {
  let types_config.SadConfig(server_port: port, ..) = cfg
  port
}

fn server_host(cfg: types_config.SadConfig) -> String {
  let types_config.SadConfig(server_host: host, ..) = cfg
  host
}

fn serve_background(plan: BackgroundPlan) -> Result(Int, Nil) {
  let BackgroundPlan(
    program: program,
    args: args,
    pidfile: pidfile,
    logfile: logfile,
    timeout_ms: _timeout_ms,
  ) = plan

  case daemon.daemonize(program, args, pidfile, logfile) {
    Ok(_pid) -> Ok(exit_ok)
    Error(_) -> Error(Nil)
  }
}

fn sleep_forever() -> Nil {
  process.sleep(60_000)
  sleep_forever()
}

fn help_text() -> List(String) {
  [
    "sad serve [--port <port>] [--config <path>] [-b|--background] [-k|--kill] [--status]",
    "sad validate <path> [--config <path>]",
    "sad dry-run --profile <id> --input <path> --capability <cap> [--config <path>]",
    "sad runner-test <profile_path> [--input <path>] [--config <path>]",
    "sad runner-test --contract <path> [--input <path>] [--config <path>]",
    "sad --help",
    "sad --version",
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

  let cfg = case loaded_cfg {
    Ok(cfg0) -> apply_port_override(cfg0, cli_port)
    Error(_) -> apply_port_override(types_config.default_sad_config(), cli_port)
  }

  let host = server_host(cfg)
  let port = server_port(cfg)

  let banner =
    "effective_config host="
    <> host
    <> " port="
    <> int.to_string(port)
    <> " config_path="
    <> resolved_config_path

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
        Error(_) -> RunPlan(code, [], ["failed to kill"], NoAction)
      }
    }

    cli.Background -> {
      let pidfile = daemon_paths.resolve_pidfile_path()
      let logfile = daemon_paths.resolve_logfile_path()
      let timeout_ms = shutdown_timeout_ms(cfg)
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
          timeout_ms: timeout_ms,
        )),
      )
    }

    cli.Foreground ->
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

fn shutdown_timeout_ms(cfg: types_config.SadConfig) -> Int {
  let types_config.SadConfig(timeouts: timeouts, ..) = cfg
  let types_config.SadTimeouts(shutdown_timeout_ms: ms, ..) = timeouts
  ms
}

fn apply_port_override(
  cfg: types_config.SadConfig,
  port: Option(Int),
) -> types_config.SadConfig {
  case port {
    None -> cfg
    Some(p) -> types_config.SadConfig(..cfg, server_port: p)
  }
}

fn unimplemented(name: String) -> RunPlan {
  RunPlan(exit_operational, [], ["command not implemented: " <> name], NoAction)
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
