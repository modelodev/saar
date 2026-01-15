//// Gateway graceful shutdown coordinator.
////
//// Mission: coordinate graceful shutdown for the SAD HTTP gateway.
////
//// Responsibilities:
//// - Track drain mode and in-flight request count.
//// - Reject new requests with a stable 503 Problem Details payload.
//// - React to SIGTERM and perform a best-effort shutdown flow.
////
//// Non-responsibilities:
//// - Implementing HTTP routing (owned by `sad/gateway/http_server`).
//// - Persisting state across restarts.
////
//// Relationships:
//// - Started under `sad/core/root_supervisor`.
//// - Consulted by `sad/gateway/http_server` on each request.
//// - Uses `sad/core/shutdown_all` to terminate agents.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import sad/core/messages
import sad/core/shutdown_all
import sad/daemon_paths
import sad/ffi
import sad/otp/safe_call
import sad/types/config as types_config

pub type Msg {
  /// Internal: configured at startup so the shutdown worker can force-stop.
  SetRootSupervisorPid(process.Pid)

  /// Enters the request handler, returning whether it is allowed.
  EnterRequest(process.Subject(Bool))

  /// Marks the request handler as finished.
  LeaveRequest

  /// Returns the current in-flight request count.
  GetInFlight(process.Subject(Int))

  /// Starts the shutdown flow.
  BeginShutdown
}

type State {
  State(
    draining: Bool,
    inflight: Int,
    shutdown_timeout_ms: Int,
    pidfile_path: String,
    registry: process.Subject(messages.RegistryMsg),
    root_supervisor_pid: Option(process.Pid),
    selector: process.Selector(Msg),
    self: process.Subject(Msg),
  )
}

/// Starts the shutdown coordinator actor.
pub fn start(
  name: process.Name(Msg),
  cfg: types_config.SadConfig,
  registry: process.Subject(messages.RegistryMsg),
) -> actor.StartResult(process.Subject(Msg)) {
  let init = fn(self) {
    let types_config.SadConfig(timeouts: timeouts, ..) = cfg
    let types_config.SadTimeouts(shutdown_timeout_ms: shutdown_timeout_ms, ..) =
      timeouts

    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_record(atom.create("sad_sigterm"), 0, fn(_dyn) {
        BeginShutdown
      })

    State(
      draining: False,
      inflight: 0,
      shutdown_timeout_ms: shutdown_timeout_ms,
      pidfile_path: daemon_paths.resolve_pidfile_path(),
      registry: registry,
      root_supervisor_pid: None,
      selector: selector,
      self: self,
    )
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  }

  actor.new_with_initialiser(5000, init)
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

/// Attempts to enter a request handler.
///
/// If the shutdown actor is unreachable, this defaults to allowing the request.
pub fn enter_request(subject: process.Subject(Msg), timeout_ms: Int) -> Bool {
  safe_call.call_within(subject, timeout_ms, fn(reply_to) {
    EnterRequest(reply_to)
  })
  |> result.unwrap(True)
}

/// Marks the current request handler as completed.
pub fn leave_request(subject: process.Subject(Msg)) -> Nil {
  process.send(subject, LeaveRequest)
  Nil
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    SetRootSupervisorPid(pid) ->
      actor.continue(State(..state, root_supervisor_pid: Some(pid)))

    EnterRequest(reply_to) -> {
      case state.draining {
        True -> {
          process.send(reply_to, False)
          actor.continue(state)
        }

        False -> {
          process.send(reply_to, True)
          actor.continue(State(..state, inflight: state.inflight + 1))
        }
      }
    }

    LeaveRequest ->
      actor.continue(State(..state, inflight: int.max(0, state.inflight - 1)))

    GetInFlight(reply_to) -> {
      process.send(reply_to, state.inflight)
      actor.continue(state)
    }

    BeginShutdown -> handle_begin_shutdown(state)
  }
}

fn handle_begin_shutdown(state: State) -> actor.Next(State, Msg) {
  case state.draining {
    True -> actor.continue(state)

    False -> {
      let next_state = State(..state, draining: True)

      let _ =
        process.spawn(fn() {
          run_shutdown_worker(
            next_state.self,
            next_state.registry,
            next_state.root_supervisor_pid,
            next_state.shutdown_timeout_ms,
            next_state.pidfile_path,
          )
        })

      actor.continue(next_state)
    }
  }
}

fn run_shutdown_worker(
  shutdown: process.Subject(Msg),
  registry: process.Subject(messages.RegistryMsg),
  root_supervisor_pid: Option(process.Pid),
  shutdown_timeout_ms: Int,
  pidfile_path: String,
) -> Nil {
  // Drain new requests first.
  shutdown_all.send_terminate_to_all(registry, 250)

  let deadline_ms = ffi.now_ms() + int.max(1, shutdown_timeout_ms)

  wait_for_shutdown(deadline_ms, shutdown, registry, root_supervisor_pid)

  let _ = init_stop()
  Nil
}

fn wait_for_shutdown(
  deadline_ms: Int,
  shutdown: process.Subject(Msg),
  registry: process.Subject(messages.RegistryMsg),
  root_supervisor_pid: Option(process.Pid),
) -> Nil {
  let inflight = current_inflight(shutdown)

  case inflight == 0 {
    True -> Nil

    False -> {
      process.sleep(50)
      wait_for_shutdown(deadline_ms, shutdown, registry, root_supervisor_pid)
    }
  }
}

fn current_inflight(shutdown: process.Subject(Msg)) -> Int {
  safe_call.call_within(shutdown, 100, fn(reply_to) { GetInFlight(reply_to) })
  |> result.unwrap(0)
}

@external(erlang, "init", "stop")
fn init_stop() -> Dynamic
