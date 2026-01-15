//// Daemon-related path resolution.
////
//// Mission: resolve default locations for daemon pid/log files.
////
//// Responsibilities:
//// - Resolve `SAD_PID_FILE` and `SAD_LOG_FILE` with sane defaults.
//// - Expand `~` using the `HOME` environment variable.
////
//// Non-responsibilities:
//// - Creating directories or writing files.
//// - Reading pidfiles or managing processes.
////
//// Relationships:
//// - Consumed by CLI/server bootstrap code and `sad/daemon_control`.

import envoy
import gleam/option.{type Option, None, Some}
import gleam/string

pub fn resolve_pidfile_path() -> String {
  resolve_path("SAD_PID_FILE", "~/.sad/sad.pid")
}

pub fn resolve_logfile_path() -> String {
  resolve_path("SAD_LOG_FILE", "~/.sad/sad.log")
}

fn resolve_path(env_key: String, default: String) -> String {
  case envoy.get(env_key) {
    Ok(value) -> expand_home(value)
    Error(_) -> expand_home(default)
  }
}

fn expand_home(path: String) -> String {
  case string.starts_with(path, "~/") {
    False -> path
    True ->
      case home_dir() {
        None -> path
        Some(home) -> home <> "/" <> string.slice(path, 2, string.length(path))
      }
  }
}

fn home_dir() -> Option(String) {
  case envoy.get("HOME") {
    Ok(home) -> Some(home)
    Error(_) -> None
  }
}
