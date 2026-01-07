fn daemonize() -> Nil {
  // 1. Fork (via FFI a os:fork o similar)
  // 2. Parent exits
  // 3. Child continues
  // 4. Redirect stdout/stderr to log file
  // 5. Close stdin
  ffi.daemonize(
    pid_file: get_pid_file_path(),
    log_file: get_log_file_path(),
  )
}

fn kill_running_server() -> Nil {
  case read_pid_file() {
    Ok(pid) -> {
      // Nota: esta señal es para detener *SAD* (no runners).
      // Implementación: puede ser FFI mínima (kill) o delegar a un comando externo `kill`.
      ffi.kill(pid, signal.SIGTERM)
      wait_for_exit(pid, timeout_ms: 10_000)
      delete_pid_file()
      io.println("SAD stopped")
    }
    Error(_) -> {
      io.println("SAD not running")
    }
  }
}

fn show_status() -> Nil {
  case read_pid_file() {
    Ok(pid) -> {
      case ffi.process_alive(pid) {
        True -> io.println("SAD running (PID " <> int.to_string(pid) <> ")")
        False -> {
          delete_pid_file()  // Stale PID file
          io.println("SAD not running")
        }
      }
    }
    Error(_) -> io.println("SAD not running")
  }
}

fn get_pid_file_path() -> String {
  os.get_env("SAD_PID_FILE")
  |> result.unwrap(home_dir() <> "/.sad/sad.pid")
}
