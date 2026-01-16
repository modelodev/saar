pub fn main() {
  let args = parse_args(process.get_args())

  case args.command {
    Serve(serve_args) -> handle_serve(serve_args)
    Validate(path) -> handle_validate(path)
    // ...
  }
}

fn handle_serve(args: ServeArgs) {
  // Kill mode
  case args.kill {
    True -> {
      kill_running_server()
      process.exit(0)
    }
    False -> Nil
  }

  // Status mode
  case args.status {
    True -> {
      show_status()
      process.exit(0)
    }
    False -> Nil
  }

  // Background mode
  case args.background {
    True -> {
      daemonize()
      // Fork, write PID, redirect logs
    }
    False -> Nil
  }

  // Normal startup
  let config = load_config_or_exit()
  let profiles = load_profiles_or_warn(config)
  // Arranca el árbol OTP completo (incluye HttpServer).
  let assert Ok(_sup_ref) = saar_supervisor.start(config, profiles)

  // Write PID file
  write_pid_file()

  process.sleep_forever()
}
