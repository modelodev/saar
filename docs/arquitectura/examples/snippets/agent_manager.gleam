// Extracted reference snippet (v0)
// Source: arquitectura/actores.md:1305
// Purpose: documentation-only; may not compile as-is.

import gleam/dict
import gleam/dict.{type Dict}
import gleam/erlang/process.{
  type Down, type Monitor, type Name, type Pid, type Selector, type Subject,
}
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import saar/app_state.{type AppState}
import saar/bridge/bridge.{type Bridge, default_bridge}
import saar/core/agent
import saar/core/artifact_registry_api
import saar/core/messages.{
  type AgentManagerMsg, type AgentMsg, type ArtifactRegistryMsg,
  type DeleteError, type InstanceId, type RegistryMsg, type StartArgs,
  type StartError, type StopError, DeleteAgent, DeleteWorkerDone,
  DeleteWorkerDown, ListAgents, StartAgent, StopAgent,
}
import saar/core/registry_api
import saar/types.{
  type AgentPhase, type AgentRunMode, type AgentStatusView, type SaarConfig,
  Provisioning, RunIdle, Stopped,
}
import saar/workspace

/// Estado interno del AgentManagerActor.
/// Gestiona instancias; los perfiles cargados viven en `ProfilesActor`.
/// 
/// NOTA: El manager NO hace IO de negocio (cargar perfiles/params).
/// La única IO permitida en v0 es cleanup determinista en `DeleteAgent`
/// (workspace + purge de artefactos), y debe ejecutarse en un worker corto para no
/// bloquear el mailbox del manager.
/// 
/// IMPORTANTE: NO mantiene tracking local de children.
/// El Registry es el SSOT único para instancias activas.
///
/// Esto es seguro en v0 porque el `RootSupervisor` usa `RestForOne` y arranca
/// `RegistryActor` antes que el subtree dependiente, y `AgentManagerActor` antes que `AgentFactorySupervisor`:
/// - Si el Registry crashea y pierde estado, el subtree dependiente se termina/reinicia (evita “agentes fantasma”).
/// - Si el manager crashea entre `start_child` y `registry.register`, RestForOne tumba el factory y no puede quedar
///   un agente vivo pero no registrado.
type State {
  State(
    config: SaarConfig,
    registry: Subject(RegistryMsg),
    /// Registro de artefactos (para purge en DeleteAgent)
    artifact_registry: Subject(ArtifactRegistryMsg),
    /// Bridge inyectable para crear workers de IO (ports/HTTP).
    bridge: Bridge,
    /// Supervisor dinámico para crear agentes (children) bajo demanda.
    agent_factory: factory_supervisor.Supervisor(StartArgs, agent.AgentRef),
    /// Selector para monitorear workers internos (delete).
    selector: Selector(AgentManagerMsg),
    /// Deletes en progreso (instance_id -> monitor + reply_to).
    delete_in_flight: Dict(InstanceId, DeleteInFlight),
  )
}

type DeleteInFlight {
  DeleteInFlight(
    reply_to: Subject(Result(Nil, DeleteError)),
    monitor: Monitor,
    worker_pid: Pid,
  )
}

/// Dependencias del sistema usadas por AgentManagerActor.
/// Permite tests sin depender de nombres globales.
pub type ManagerDeps {
  ManagerDeps(
    registry: Subject(RegistryMsg),
    artifact_registry: Subject(ArtifactRegistryMsg),
    bridge: Bridge,
    agent_factory: factory_supervisor.Supervisor(StartArgs, agent.AgentRef),
  )
}

/// Arranca el AgentManagerActor.
/// El manager NO hace IO de disco.
/// Arranca el AgentManagerActor bajo el árbol OTP.
/// Recibe `app_state` ya construido en `main` (config + perfiles cargados).
pub fn start(
  app_state: AppState,
  deps: ManagerDeps,
  name: Name(AgentManagerMsg),
) -> actor.StartResult(Subject(AgentManagerMsg)) {
  // Extraer dependencias puras desde app_state (sin IO aquí)
  let config = app_state.config
  let init = fn(self) {
    let ManagerDeps(registry, artifact_registry, bridge, agent_factory) = deps

    let selector = process.new_selector()
    let state =
      State(
        config: config,
        registry: registry,
        artifact_registry: artifact_registry,
        bridge: bridge,
        agent_factory: agent_factory,
        selector: selector,
        delete_in_flight: dict.new(),
      )

    actor.initialised(state)
    |> actor.with_selector(selector)
    |> actor.returning(self)
  }

  let builder =
    actor.new_with_initialiser(5000, init)
    |> actor.named(name)
    |> actor.on_message(handle_message)

  // Importante: al usar `process.spawn` internamente, `actor.start` arranca linkado.
  actor.start(builder)
}

fn handle_message(
  state: State,
  msg: AgentManagerMsg,
) -> actor.Next(State, AgentManagerMsg) {
  case msg {
    // Gestión de instancias
    StartAgent(args, reply_to) -> handle_start_agent(state, args, reply_to)
    StopAgent(instance_id, reply_to) ->
      handle_stop_agent(state, instance_id, reply_to)
    DeleteAgent(instance_id, reply_to) ->
      handle_delete_agent(state, instance_id, reply_to)
    DeleteWorkerDone(instance_id, result) ->
      handle_delete_worker_done(state, instance_id, result)
    DeleteWorkerDown(down) -> handle_delete_worker_down(state, down)
    ListAgents(reply_to) -> {
      // Delegar al Registry (SSOT de instancias activas)
      let agents =
        registry_api.list_all(state.registry, state.config.registry_timeout_ms)
      process.send(reply_to, agents)
      actor.continue(state)
    }
  }
}

fn handle_start_agent(
  state: State,
  args: StartArgs,
  reply_to: Subject(Result(agent.AgentRef, StartError)),
) -> actor.Next(State, AgentManagerMsg) {
  // Nota de concurrencia (importante):
  // `AgentManagerActor` es un actor: procesa 1 mensaje a la vez. Por tanto, un `ListAgents`
  // no puede “colarse” entre “crear actor” y “registrar”: quedará en el mailbox y se
  // procesará después de completar este handler.
  //
  // Aun así, evitamos el TOCTOU de `lookup → start → register` y delegamos la unicidad
  // al `RegistryActor` usando `register` como operación atómica.

  // 1) Crear el actor bajo `AgentFactorySupervisor` (init rápido; provisioning ocurre asíncrono en el actor)
  // Garantía: si cae el subtree (`RestForOne`) no quedan agentes huérfanos fuera del árbol OTP.
  case factory_supervisor.start_child(state.agent_factory, args) {
    Error(start_error) -> {
      process.send(reply_to, Error(StartChildFailed(start_error)))
      actor.continue(state)
    }
    Ok(actor.Started(_pid, agent_ref)) ->
      register_agent_or_rollback(state, args, agent_ref, reply_to)
  }
}

fn register_agent_or_rollback(
  state: State,
  args: StartArgs,
  agent_ref: agent.AgentRef,
  reply_to: Subject(Result(agent.AgentRef, StartError)),
) -> actor.Next(State, AgentManagerMsg) {
  let StartArgs(profile, instance_id, _params, _workspace, _config) = args
  let status =
    AgentStatusView(
      profile_id: profile.meta.id,
      instance_id: instance_id,
      lifecycle: profile.meta.lifecycle,
      phase: Provisioning,
      mode: RunIdle,
      assigned_port: None,
      failure_reason: None,
    )
  case
    registry_api.register(
      state.registry,
      status,
      agent_ref,
      state.config.registry_timeout_ms,
    )
  {
    Ok(_) -> {
      process.send(reply_to, Ok(agent_ref))
      actor.continue(state)
    }
    Error(registry_error) -> {
      // Rollback best-effort: terminar el actor recién creado.
      agent.terminate(agent_ref, SupervisorCleanup)
      process.send(reply_to, Error(RegistrationFailed(registry_error)))
      actor.continue(state)
    }
  }
}

fn handle_stop_agent(
  state: State,
  instance_id: InstanceId,
  reply_to: Subject(Result(Nil, StopError)),
) -> actor.Next(State, AgentManagerMsg) {
  // Stop es idempotente y NO limpia workspace/artefactos; delete encadena cleanup.
  // Consultar Registry (SSOT) para obtener el agente
  case
    registry_api.lookup_by_instance_id(
      state.registry,
      instance_id,
      state.config.registry_timeout_ms,
    )
  {
    Error(_) -> {
      process.send(reply_to, Error(StopTimeout))
      actor.continue(state)
    }
    Ok(found) ->
      case found {
        None -> {
          process.send(reply_to, Error(AgentNotFound))
          actor.continue(state)
        }
        Some(agent_ref) -> {
          // 1. Detener la instancia (la instancia permanece registrada en estado Stopped)
          agent.stop_instance(agent_ref, UserRequested)
          process.send(reply_to, Ok(Nil))
          actor.continue(state)
        }
      }
  }
}

fn handle_delete_agent(
  state: State,
  instance_id: InstanceId,
  reply_to: Subject(Result(Nil, DeleteError)),
) -> actor.Next(State, AgentManagerMsg) {
  // Delete es idempotente solo para "no existe": si no existe, responder Ok(Nil).
  // Si existe y el cleanup falla, devolver `DeleteError` y NO dejar el sistema en un estado medio-borrado.
  // Secuencia: stop (si existe) → esperar Stopped → cleanup workspace → purge artefactos → unregister → terminate.
  // Nota: release de port ocurre dentro de StopInstance (idempotente).
  case
    registry_api.lookup_by_instance_id(
      state.registry,
      instance_id,
      state.config.registry_timeout_ms,
    )
  {
    Error(_) -> {
      process.send(reply_to, Error(DeleteTimeout))
      actor.continue(state)
    }
    Ok(found) ->
      case found {
        None -> {
          process.send(reply_to, Ok(Nil))
          actor.continue(state)
        }
        Some(agent_ref) -> {
          let self = process.self()
          // Delete no debe bloquear el mailbox: hacer cleanup en un worker corto (IO).
          // Worker BEAM de IO: usar unlinked para que fallos externos no tumben al supervisor.
          let worker_pid =
            process.spawn_unlinked(fn() {
              // 1) StopInstance: pasa a estado Stopped sin limpiar.
              agent.stop_instance(agent_ref, UserRequested)

              // 1.1) Esperar confirmación de estado Stopped (timeout duro).
              let stop_result =
                wait_for_stopped(
                  agent_ref,
                  state.config.shutdown_timeout_ms,
                  state.config.status_timeout_ms,
                )

              case stop_result {
                Error(e) ->
                  process.send(self, DeleteWorkerDone(instance_id, Error(e)))
                Ok(_) -> {
                  // 2) Cleanup de filesystem (IO). Si falla, devolver error explícito y mantener la instancia.
                  let result = case
                    workspace.cleanup(
                      state.config.workspaces_directory,
                      instance_id,
                    )
                  {
                    Ok(_) -> {
                      // 3) Purge de artefactos (SSOT en BEAM).
                      let _ =
                        artifact_registry_api.purge_by_instance(
                          state.artifact_registry,
                          instance_id,
                          state.config.registry_timeout_ms,
                        )

                      // 4) Unregister de la instancia (ya no existe).
                      registry_api.unregister_by_instance_id(
                        state.registry,
                        instance_id,
                      )

                      // 5) Terminar el proceso BEAM del agente (delete = instancia desaparece).
                      agent.terminate(agent_ref, Deleted)

                      Ok(Nil)
                    }
                    Error(e) -> {
                      // Rollback de seguridad (v0): aunque el filesystem no se pueda limpiar,
                      // dejamos de servir artefactos (los ArtifactIds dejan de resolverse).
                      let _ =
                        artifact_registry_api.purge_by_instance(
                          state.artifact_registry,
                          instance_id,
                          state.config.registry_timeout_ms,
                        )
                      Error(CleanupFailed(e))
                    }
                  }

                  process.send(self, DeleteWorkerDone(instance_id, result))
                }
              }
            })

          let monitor = process.monitor(worker_pid)
          let new_selector =
            state.selector
            |> process.select_specific_monitor(monitor, DeleteWorkerDown)
          let new_state =
            State(
              ..state,
              selector: new_selector,
              delete_in_flight: dict.insert(
                state.delete_in_flight,
                instance_id,
                DeleteInFlight(reply_to, monitor, worker_pid),
              ),
            )

          actor.continue(new_state)
          |> actor.with_selector(new_selector)
        }
      }
  }
}

fn handle_delete_worker_done(
  state: State,
  instance_id: InstanceId,
  result: Result(Nil, DeleteError),
) -> actor.Next(State, AgentManagerMsg) {
  case dict.get(state.delete_in_flight, instance_id) {
    None -> actor.continue(state)
    Some(DeleteInFlight(reply_to, monitor, _pid)) -> {
      process.demonitor_process(monitor)
      let new_selector =
        state.selector
        |> process.deselect_specific_monitor(monitor)
      let new_state =
        State(
          ..state,
          selector: new_selector,
          delete_in_flight: dict.delete(state.delete_in_flight, instance_id),
        )
      process.send(reply_to, result)
      actor.continue(new_state)
      |> actor.with_selector(new_selector)
    }
  }
}

fn handle_delete_worker_down(
  state: State,
  down: Down,
) -> actor.Next(State, AgentManagerMsg) {
  case down {
    process.ProcessDown(pid: down_pid, ..) ->
      case find_delete_in_flight_by_pid(state.delete_in_flight, down_pid) {
        None -> actor.continue(state)
        Some(#(instance_id, DeleteInFlight(reply_to, monitor, _pid))) -> {
          process.demonitor_process(monitor)
          let new_selector =
            state.selector
            |> process.deselect_specific_monitor(monitor)
          let new_state =
            State(
              ..state,
              selector: new_selector,
              delete_in_flight: dict.delete(state.delete_in_flight, instance_id),
            )
          process.send(reply_to, Error(DeleteWorkerCrashed))
          actor.continue(new_state)
          |> actor.with_selector(new_selector)
        }
      }
  }
}

fn find_delete_in_flight_by_pid(
  delete_in_flight: Dict(InstanceId, DeleteInFlight),
  pid: Pid,
) -> Option(#(InstanceId, DeleteInFlight)) {
  delete_in_flight
  |> dict.to_list
  |> list.find(fn(entry) {
    let #(_instance_id, DeleteInFlight(_reply_to, _monitor, worker_pid)) = entry
    worker_pid == pid
  })
}

fn wait_for_stopped(
  agent_ref: agent.AgentRef,
  timeout_ms: Int,
  status_timeout_ms: Int,
) -> Result(Nil, DeleteError) {
  wait_for_stopped_loop(agent_ref, timeout_ms, status_timeout_ms)
}

fn wait_for_stopped_loop(
  agent_ref: agent.AgentRef,
  remaining_ms: Int,
  status_timeout_ms: Int,
) -> Result(Nil, DeleteError) {
  case remaining_ms <= 0 {
    True -> Error(DeleteTimeout)
    False ->
      case agent.status(agent_ref, status_timeout_ms) {
        Error(_) -> Error(DeleteTimeout)
        Ok(status) ->
          case status.phase {
            Stopped -> Ok(Nil)
            _ -> {
              let sleep_ms = case remaining_ms < 100 {
                True -> remaining_ms
                False -> 100
              }
              process.sleep(sleep_ms)
              wait_for_stopped_loop(
                agent_ref,
                remaining_ms - sleep_ms,
                status_timeout_ms,
              )
            }
          }
      }
  }
}
