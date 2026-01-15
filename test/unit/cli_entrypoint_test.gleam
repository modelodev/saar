import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import sad
import sad/daemon_control
import simplifile

pub fn main() {
  gleeunit.main()
}

pub fn main_help_exit_0() {
  let plan =
    sad.plan(
      argv: ["--help"],
      program: "sad",
      get_env: env_none,
      read_file: read_file_stub,
      status: fn(_) { daemon_control.NotRunning },
      kill: fn(_, _) { Error(daemon_control.NoServer) },
    )

  should.equal(sad.exit_code(plan), sad.exit_ok)

  let out = sad.stdout_lines(plan)
  should.equal(list.any(out, fn(line) { string_contains(line, "serve") }), True)
}

pub fn main_version_reads_gleam_toml() {
  let plan =
    sad.plan(
      argv: ["--version"],
      program: "sad",
      get_env: env_none,
      read_file: read_file_stub,
      status: fn(_) { daemon_control.NotRunning },
      kill: fn(_, _) { Error(daemon_control.NoServer) },
    )

  should.equal(sad.exit_code(plan), sad.exit_ok)
  should.equal(string.join(sad.stdout_lines(plan), "\n"), "9.9.9")
}

pub fn main_unknown_command_exit_1() {
  let plan =
    sad.plan(
      argv: ["wat"],
      program: "sad",
      get_env: env_none,
      read_file: read_file_stub,
      status: fn(_) { daemon_control.NotRunning },
      kill: fn(_, _) { Error(daemon_control.NoServer) },
    )

  should.equal(sad.exit_code(plan), sad.exit_usage)
  should.equal(sad.stderr_lines(plan) != [], True)
}

pub fn main_serve_status_not_running_exit_1() {
  let plan =
    sad.plan(
      argv: ["serve", "--status"],
      program: "sad",
      get_env: env_none,
      read_file: read_file_stub,
      status: fn(_) { daemon_control.NotRunning },
      kill: fn(_, _) { Error(daemon_control.NoServer) },
    )

  should.equal(sad.exit_code(plan), 1)
  should.equal(string.join(sad.stdout_lines(plan), "\n"), "SAD not running")
}

pub fn main_serve_kill_no_server_exit_1() {
  let plan =
    sad.plan(
      argv: ["serve", "-k"],
      program: "sad",
      get_env: env_none,
      read_file: read_file_stub,
      status: fn(_) { daemon_control.NotRunning },
      kill: fn(_, _) { Error(daemon_control.NoServer) },
    )

  should.equal(sad.exit_code(plan), 1)
}

pub fn main_unimplemented_command_exit_2() {
  let plan =
    sad.plan(
      argv: ["validate", "./profiles"],
      program: "sad",
      get_env: env_none,
      read_file: read_file_stub,
      status: fn(_) { daemon_control.NotRunning },
      kill: fn(_, _) { Error(daemon_control.NoServer) },
    )

  should.equal(sad.exit_code(plan), sad.exit_operational)
}

pub fn main_serve_prints_effective_config() {
  let plan =
    sad.plan(
      argv: ["serve", "--port", "9090", "--config", "./config.toml"],
      program: "sad",
      get_env: env_none,
      read_file: read_file_stub,
      status: fn(_) { daemon_control.NotRunning },
      kill: fn(_, _) { Error(daemon_control.NoServer) },
    )

  let out = string.join(sad.stdout_lines(plan), "\n")

  should.equal(string_contains(out, "host="), True)
  should.equal(string_contains(out, "port=9090"), True)
  should.equal(string_contains(out, "config_path=./config.toml"), True)
}

pub fn main_serve_background_plan_exit_0() {
  let plan =
    sad.plan(
      argv: ["serve", "--port", "9090", "--config", "./config.toml", "-b"],
      program: "sad",
      get_env: env_none,
      read_file: read_file_stub,
      status: fn(_) { daemon_control.NotRunning },
      kill: fn(_, _) { Error(daemon_control.NoServer) },
    )

  should.equal(sad.exit_code(plan), sad.exit_ok)

  let out = string.join(sad.stdout_lines(plan), "\n")
  should.equal(string_contains(out, "port=9090"), True)
}

fn env_none(_key: String) -> Result(String, Nil) {
  Error(Nil)
}

fn read_file_stub(path: String) -> Result(String, simplifile.FileError) {
  case path {
    "./gleam.toml" -> Ok("name = \"sad\"\nversion = \"9.9.9\"\n")

    "./config.toml" ->
      Ok(
        "[auth]\napi_key = \"test\"\n[server]\nhost = \"127.0.0.1\"\nport = 8080\n",
      )

    _ -> Error(simplifile.Enoent)
  }
}

fn string_contains(haystack: String, needle: String) -> Bool {
  case string.split_once(haystack, on: needle) {
    Ok(_) -> True
    Error(_) -> False
  }
}
