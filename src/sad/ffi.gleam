import gleam/erlang/port.{type Port}

pub type PortMessage {
  PortDataEol(String)
  PortDataNoeol(String)
  PortExit(Int)
}

pub fn now_ms() -> Int {
  now_ms_ffi()
}

@external(erlang, "sad_ffi", "now_ms")
fn now_ms_ffi() -> Int

pub fn open_port(
  command: String,
  args: List(String),
  env: List(#(String, String)),
  cd: String,
  max_runner_event_bytes: Int,
) -> Result(Port, String) {
  open_port_ffi(command, args, env, cd, max_runner_event_bytes)
}

@external(erlang, "sad_ffi", "open_port")
fn open_port_ffi(
  command: String,
  args: List(String),
  env: List(#(String, String)),
  cd: String,
  max_runner_event_bytes: Int,
) -> Result(Port, String)

pub fn port_send(port: Port, data: String) -> Nil {
  port_send_ffi(port, data)
}

@external(erlang, "sad_ffi", "port_send")
fn port_send_ffi(port: Port, data: String) -> Nil

pub fn port_close(port: Port) -> Nil {
  port_close_ffi(port)
}

@external(erlang, "sad_ffi", "port_close")
fn port_close_ffi(port: Port) -> Nil

pub fn port_receive(port: Port, timeout_ms: Int) -> Result(PortMessage, Nil) {
  port_receive_ffi(port, timeout_ms)
}

@external(erlang, "sad_ffi", "port_receive")
fn port_receive_ffi(port: Port, timeout_ms: Int) -> Result(PortMessage, Nil)
