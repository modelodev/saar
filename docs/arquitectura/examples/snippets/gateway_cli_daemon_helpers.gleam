fn daemonize() -> Nil {
  // 1. Fork (via FFI a os:fork o similar)
  // 2. Parent exits
  // 3. Child continues
  // 4. Redirect stdout/stderr to log file
  // 5. Close stdin
  ffi.daemonize(pid_file: get_pid_file_path(), log_file: get_log_file_path())
}

fn kill_running_server() -> Nil {
  case read_pid_file() {
    Ok(pid) -> {
      // Nota: esta señal es para detener *SAAR* (no runners).
      // Implementación: puede ser FFI mínima (kill) o delegar a un comando externo `kill`.
      ffi.kill(pid, signal.SIGTERM)
      wait_for_exit(pid, timeout_ms: 10_000)
      delete_pid_file()
      io.println("SAAR stopped")
    }
    Error(_) -> {
      io.println("SAAR not running")
    }
  }
}

fn show_status() -> Nil {
  case read_pid_file() {
    Ok(pid) -> {
      case ffi.process_alive(pid) {
        True -> io.println("SAAR running (PID " <> int.to_string(pid) <> ")")
        False -> {
          delete_pid_file()
          // Stale PID file
          io.println("SAAR not running")
        }
      }
    }
    Error(_) -> io.println("SAAR not running")
  }
}

fn get_pid_file_path() -> String {
  os.get_env("SAAR_PID_FILE")
  |> result.unwrap(home_dir() <> "/.saar/saar.pid")
}
