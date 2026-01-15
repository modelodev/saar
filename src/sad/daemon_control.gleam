//// Daemon process control built on pidfiles.
////
//// Mission: provide the high-level operations required by `sad serve` daemon
//// flags (-b/-k/--status).
////
//// Responsibilities:
//// - Read and validate a pidfile.
//// - Check process liveness and clean stale pidfiles.
//// - Kill the daemon process (SIGTERM -> SIGKILL) and remove the pidfile.
//// - Render status output strings.
////
//// Non-responsibilities:
//// - Spawning the actual SAD server process.
//// - Choosing defaults for pid/log file locations.
////
//// Relationships:
//// - Uses `sad/ffi/daemon` for OS-level process control.
//// - Used by CLI/main code.

import gleam/int
import gleam/result
import gleam/string
import sad/ffi/daemon
import simplifile

pub type Status {
  Running(Int)
  NotRunning
}

pub type KillError {
  NoServer
  KillFailed(daemon.DaemonError)
}

pub fn status(pidfile_path: String) -> Status {
  case read_pidfile(pidfile_path) {
    Error(_) -> NotRunning
    Ok(pid) ->
      case daemon.process_alive(pid) {
        True -> Running(pid)
        False -> {
          let _ = simplifile.delete(file_or_dir_at: pidfile_path)
          NotRunning
        }
      }
  }
}

pub fn status_message(status: Status, port: Int) -> String {
  case status {
    Running(pid) ->
      "SAD running on port "
      <> int.to_string(port)
      <> " (PID "
      <> int.to_string(pid)
      <> ")"

    NotRunning -> "SAD not running"
  }
}

/// Exit code for `serve --status`.
///
/// - Running -> 0
/// - Not running -> 1
pub fn status_exit_code(status: Status) -> Int {
  case status {
    Running(_) -> 0
    NotRunning -> 1
  }
}

/// Exit code for `serve -k/--kill`.
///
/// - Ok -> 0
/// - No server -> 1
/// - Operational error -> 2
pub fn kill_exit_code(result: Result(Nil, KillError)) -> Int {
  case result {
    Ok(_) -> 0
    Error(NoServer) -> 1
    Error(_) -> 2
  }
}

pub fn kill(pidfile_path: String, timeout_ms: Int) -> Result(Nil, KillError) {
  use pid <- result.try(
    read_pidfile(pidfile_path)
    |> result.map_error(fn(_) { NoServer }),
  )

  case daemon.kill_process(pid, timeout_ms) {
    Ok(_) -> {
      let _ = simplifile.delete(file_or_dir_at: pidfile_path)
      Ok(Nil)
    }

    Error(daemon.NotRunning) -> {
      let _ = simplifile.delete(file_or_dir_at: pidfile_path)
      Error(NoServer)
    }

    Error(err) -> Error(KillFailed(err))
  }
}

fn read_pidfile(pidfile_path: String) -> Result(Int, Nil) {
  use content <- result.try(
    simplifile.read(pidfile_path)
    |> result.map_error(fn(_) { Nil }),
  )

  case int.parse(string.trim(content)) {
    Ok(pid) if pid > 0 -> Ok(pid)
    _ -> {
      let _ = simplifile.delete(file_or_dir_at: pidfile_path)
      Error(Nil)
    }
  }
}
