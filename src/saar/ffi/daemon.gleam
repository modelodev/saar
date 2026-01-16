//// Daemonization helpers (Erlang FFI).
////
//// Mission: provide a small, typed boundary for background process management
//// required by `saar serve -b/-k/--status`.
////
//// Responsibilities:
//// - Spawn an OS process detached from the current BEAM VM.
//// - Send SIGTERM/SIGKILL to an OS process.
//// - Check liveness of an OS process by PID.
////
//// Non-responsibilities:
//// - Resolving default pid/log file paths (handled by `saar/daemon_paths`).
//// - Implementing server startup logic (handled by CLI / main).
////
//// Relationships:
//// - Implemented in Erlang as `saar_daemon` in `src/saar/ffi/saar_daemon.erl`.

import gleam/result

pub type DaemonError {
  SpawnFailed(reason: String)
  KillFailed(reason: String)
  NotRunning
}

/// Spawns `command` as a detached background process.
///
/// Writes the child PID to `pidfile_path` and redirects stdout/stderr to
/// `logfile_path`.
pub fn daemonize(
  command: String,
  args: List(String),
  pidfile_path: String,
  logfile_path: String,
) -> Result(Int, DaemonError) {
  daemonize_ffi(command, args, pidfile_path, logfile_path)
  |> result.map_error(SpawnFailed)
}

/// Sends SIGTERM and escalates to SIGKILL after `timeout_ms`.
pub fn kill_process(pid: Int, timeout_ms: Int) -> Result(Nil, DaemonError) {
  case kill_process_ffi(pid, timeout_ms) {
    Ok(Nil) -> Ok(Nil)
    Error("not_running") -> Error(NotRunning)
    Error(reason) -> Error(KillFailed(reason))
  }
}

/// Checks whether an OS process is alive.
pub fn process_alive(pid: Int) -> Bool {
  process_alive_ffi(pid)
}

@external(erlang, "saar_daemon", "daemonize")
fn daemonize_ffi(
  command: String,
  args: List(String),
  pidfile_path: String,
  logfile_path: String,
) -> Result(Int, String)

@external(erlang, "saar_daemon", "kill_process")
fn kill_process_ffi(pid: Int, timeout_ms: Int) -> Result(Nil, String)

@external(erlang, "saar_daemon", "process_alive")
fn process_alive_ffi(pid: Int) -> Bool
