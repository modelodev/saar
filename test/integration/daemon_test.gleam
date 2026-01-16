import gleam/int
import gleam/string
import gleeunit
import gleeunit/should
import saar/daemon_control
import saar/ffi/daemon
import simplifile

pub fn main() {
  gleeunit.main()
}

pub fn serve_background_forks_process() {
  let root = "./build/test-workspaces/daemon-background"
  let pidfile = root <> "/saar.pid"
  let logfile = root <> "/saar.log"
  let assert Ok(_) = simplifile.create_directory_all(root)

  let pid =
    daemon.daemonize("/bin/sleep", ["5"], pidfile, logfile)
    |> assert_ok_pid

  should.equal(daemon.process_alive(pid), True)

  // pidfile is written with the PID.
  let raw = simplifile.read(pidfile) |> assert_ok_string
  should.equal(string.trim(raw) |> int.parse |> is_ok_pid(pid), True)

  daemon.kill_process(pid, 500) |> assert_ok_nil
  should.equal(daemon.process_alive(pid), False)
}

pub fn serve_kill_stops_running() {
  let root = "./build/test-workspaces/daemon-kill"
  let pidfile = root <> "/saar.pid"
  let logfile = root <> "/saar.log"
  let assert Ok(_) = simplifile.create_directory_all(root)

  let pid =
    daemon.daemonize("/bin/sleep", ["10"], pidfile, logfile)
    |> assert_ok_pid

  should.equal(daemon.process_alive(pid), True)

  let kill_result = daemon_control.kill(pidfile, 500)
  should.equal(daemon_control.kill_exit_code(kill_result), 0)

  case kill_result {
    Ok(_) -> Nil
    Error(_) -> panic as "Expected kill ok"
  }

  // kill cleans the pidfile
  case simplifile.read(pidfile) {
    Error(simplifile.Enoent) -> Nil
    _ -> panic as "Expected pidfile deleted"
  }

  should.equal(daemon.process_alive(pid), False)
}

pub fn serve_kill_no_server() {
  let root = "./build/test-workspaces/daemon-kill-no-server"
  let pidfile = root <> "/saar.pid"
  let assert Ok(_) = simplifile.create_directory_all(root)

  let kill_result = daemon_control.kill(pidfile, 50)
  should.equal(daemon_control.kill_exit_code(kill_result), 0)

  case kill_result {
    Error(daemon_control.NoServer) -> Nil
    _ -> panic as "Expected NoServer"
  }
}

pub fn serve_status_running() {
  let root = "./build/test-workspaces/daemon-status-running"
  let pidfile = root <> "/saar.pid"
  let logfile = root <> "/saar.log"
  let assert Ok(_) = simplifile.create_directory_all(root)

  let pid =
    daemon.daemonize("/bin/sleep", ["5"], pidfile, logfile)
    |> assert_ok_pid

  let status = daemon_control.status(pidfile)
  should.equal(daemon_control.status_exit_code(status), 0)

  case status {
    daemon_control.Running(found_pid) -> should.equal(found_pid, pid)
    daemon_control.NotRunning -> panic as "Expected running status"
  }

  should.equal(
    daemon_control.status_message(status, 8080),
    "SAAR running on port 8080 (PID " <> int.to_string(pid) <> ")",
  )

  daemon.kill_process(pid, 500) |> assert_ok_nil
}

pub fn serve_status_not_running() {
  let root = "./build/test-workspaces/daemon-status-not-running"
  let pidfile = root <> "/saar.pid"
  let logfile = root <> "/saar.log"
  let assert Ok(_) = simplifile.create_directory_all(root)

  let pid =
    daemon.daemonize("/bin/sleep", ["5"], pidfile, logfile)
    |> assert_ok_pid

  daemon.kill_process(pid, 500) |> assert_ok_nil

  let status = daemon_control.status(pidfile)
  should.equal(daemon_control.status_exit_code(status), 1)

  case status {
    daemon_control.NotRunning -> Nil
    _ -> panic as "Expected not running status"
  }

  // Stale pidfile is cleaned.
  case simplifile.read(pidfile) {
    Error(simplifile.Enoent) -> Nil
    _ -> panic as "Expected pidfile deleted"
  }

  should.equal(daemon_control.status_message(status, 8080), "SAAR not running")
}

pub fn serve_background_forks_process_test() {
  serve_background_forks_process()
}

pub fn serve_kill_stops_running_test() {
  serve_kill_stops_running()
}

pub fn serve_kill_no_server_test() {
  serve_kill_no_server()
}

pub fn serve_status_running_test() {
  serve_status_running()
}

pub fn serve_status_not_running_test() {
  serve_status_not_running()
}

fn assert_ok_pid(result: Result(Int, daemon.DaemonError)) -> Int {
  case result {
    Ok(pid) -> pid
    Error(_) -> panic as "Expected Ok(pid)"
  }
}

fn assert_ok_nil(result: Result(Nil, daemon.DaemonError)) -> Nil {
  case result {
    Ok(Nil) -> Nil
    Error(_) -> panic as "Expected Ok"
  }
}

fn assert_ok_string(result: Result(String, simplifile.FileError)) -> String {
  case result {
    Ok(content) -> content
    Error(_) -> panic as "Expected file read ok"
  }
}

fn is_ok_pid(parsed: Result(Int, Nil), expected: Int) -> Bool {
  case parsed {
    Ok(value) -> value == expected
    Error(_) -> False
  }
}
