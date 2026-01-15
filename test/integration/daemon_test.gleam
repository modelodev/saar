import gleam/int
import gleam/string
import gleeunit
import gleeunit/should
import sad/ffi/daemon
import simplifile

pub fn main() {
  gleeunit.main()
}

pub fn serve_background_forks_process() {
  let root = "./build/test-workspaces/daemon-background"
  let pidfile = root <> "/sad.pid"
  let logfile = root <> "/sad.log"
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
  let pidfile = root <> "/sad.pid"
  let logfile = root <> "/sad.log"
  let assert Ok(_) = simplifile.create_directory_all(root)

  let pid =
    daemon.daemonize("/bin/sleep", ["10"], pidfile, logfile)
    |> assert_ok_pid

  should.equal(daemon.process_alive(pid), True)
  daemon.kill_process(pid, 500) |> assert_ok_nil
  should.equal(daemon.process_alive(pid), False)
}

pub fn serve_kill_no_server() {
  case daemon.kill_process(999_999, 50) {
    Error(daemon.NotRunning) -> Nil
    _ -> panic as "Expected NotRunning"
  }
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
