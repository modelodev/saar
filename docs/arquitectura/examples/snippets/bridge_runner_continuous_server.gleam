/// Arranca servidor continuous.
/// Los params ya vienen resueltos en input.
pub fn start_server(
  runner: Runner,
  input: SadInput,
  host: String,
  port: Int,
  workspace: String,
  instance_id: InstanceId,
  agent: AgentRef,
) -> Result(AgentResource, String) {
  let control_line =
    json.object([
      #("t", json.string("input")),
      #("payload", sad_input_to_json(input)),
    ])
    |> json.to_string

  // host/port provienen del port pool (ManagedPort): SAD reserva un puerto libre
  // (rango configurable) y lo inyecta en env vars del runner.
  // Configurar env con host/port
  let env = build_server_env(runner, host, port)

  // Abrir port para el servidor
  let port_handle =
    open_server_port(runner, workspace, env, control_line <> "\n")
  let resource = process_resource(port_handle)

  // Spawn proceso para capturar logs del servidor (eventos JSONL por stdout) con instance_id
  process.spawn_unlinked(fn() { server_log_loop(resource, agent, instance_id) })

  Ok(resource)
}

type ServerEvt {
  FromPort(PortEvent)
}

fn server_log_loop(
  resource: AgentResource,
  agent: AgentRef,
  instance_id: InstanceId,
) -> Nil {
  let port = agent_resource_port(resource)

  let selector =
    process.new_selector()
    |> port.select(port, fn(ev) { FromPort(ev) })

  case process.selector_receive_forever(selector) {
    FromPort(PortStdout(line)) -> {
      // En servidores continuous, el runner puede emitir eventos `t="log"` por STDOUT (JSONL).
      // Otros eventos se ignoran.
      case decode_runner_event(line) {
        Ok(RunnerEventLog(msg)) -> {
          let event = log_event(RunnerOut, msg, None, instance_id)
          agent.internal_ingest_log(agent, event)
        }
        _ -> Nil
      }
      server_log_loop(resource, agent, instance_id)
    }

    FromPort(PortExit(code)) -> {
      let msg = "Server exited with code " <> int.to_string(code)
      let event = log_event(SystemLog, msg, None, instance_id)
      agent.internal_ingest_log(agent, event)
      agent.internal_server_died(agent, code)
    }

    FromPort(_) -> server_log_loop(resource, agent, instance_id)
  }
}

/// Detiene servidor continuous.
/// Con wrapper: basta con cerrar stdin del port; el wrapper envía SIGTERM y luego SIGKILL si aplica.
pub fn stop_server(resource: AgentResource) -> Nil {
  let port = agent_resource_port(resource)
  port.close_stdin(port)
  port.close(port)
}
