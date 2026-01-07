// Extracted reference snippet (v0)
// Source: arquitectura/actores.md:1305
// Purpose: documentation-only; may not compile as-is.

import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/erlang/process.{type Name, type Subject} as process
import sad/core/agent
import sad/core/registry_api
import sad/core/artifact_registry_api
import sad/workspace
import sad/core/messages.{
  type AgentMsg, type RegistryMsg, type ArtifactRegistryMsg,
  type InstanceKey, InstanceKey,
  type AgentManagerMsg, StartAgent, StopAgent, DeleteAgent, ListAgents,
  type StartArgs, type StartError, type StopError, type DeleteError,
}
import sad/types.{type SadConfig}
import sad/app_state.{type AppState}
import sad/bridge/bridge.{type Bridge, default_bridge}

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
    config: SadConfig,
    registry: Subject(RegistryMsg),
    /// Registro de artefactos (para purge en DeleteAgent)
    artifact_registry: Subject(ArtifactRegistryMsg),
    /// Bridge inyectable para crear workers de IO (ports/HTTP).
    bridge: Bridge,
    /// Supervisor dinámico para crear agentes (children) bajo demanda.
    agent_factory: factory_supervisor.Supervisor(StartArgs, agent.AgentRef),
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

    let state = State(
      config: config,
      registry: registry,
      artifact_registry: artifact_registry,
      bridge: bridge,
      agent_factory: agent_factory,
    )
    
    actor.initialised(state)
    |> actor.returning(self)
  }
  
  let builder = actor.new_with_initialiser(5000, init)
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
    StopAgent(key, reply_to) -> handle_stop_agent(state, key, reply_to)
    DeleteAgent(key, reply_to) -> handle_delete_agent(state, key, reply_to)
    ListAgents(reply_to) -> {
      // Delegar al Registry (SSOT de instancias activas)
      let agents = registry_api.list_all(state.registry, state.config.registry_timeout_ms)
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
  let key = InstanceKey(args.profile.meta.id, args.instance_id)
  
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
      register_agent_or_rollback(state, key, agent_ref, reply_to)
  }
}

fn register_agent_or_rollback(
  state: State,
  key: InstanceKey,
  agent_ref: agent.AgentRef,
  reply_to: Subject(Result(agent.AgentRef, StartError)),
) -> actor.Next(State, AgentManagerMsg) {
  case registry_api.register(state.registry, key, agent_ref, state.config.registry_timeout_ms) {
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
  key: InstanceKey,
  reply_to: Subject(Result(Nil, StopError)),
) -> actor.Next(State, AgentManagerMsg) {
  // Stop es idempotente y NO limpia workspace/artefactos; delete encadena cleanup.
  // Consultar Registry (SSOT) para obtener el agente
  let assert Ok(found) =
    registry_api.lookup(state.registry, key, state.config.registry_timeout_ms)

  case found {
    None -> {
      process.send(reply_to, Error(AgentNotFound))
      actor.continue(state)
    }
    Some(agent) -> {
      // 1. Detener la instancia (la instancia permanece registrada en estado Stopped)
      agent.stop_instance(agent, UserRequested)
      process.send(reply_to, Ok(Nil))
      actor.continue(state)
    }
  }
}

fn handle_delete_agent(
  state: State,
  key: InstanceKey,
  reply_to: Subject(Result(Nil, DeleteError)),
) -> actor.Next(State, AgentManagerMsg) {
  // Delete es idempotente solo para "no existe": si no existe, responder Ok(Nil).
  // Si existe y el cleanup falla, devolver `DeleteError` y NO dejar el sistema en un estado medio-borrado.
  // Secuencia: stop (si existe) → cleanup workspace → purge artefactos → release port → unregister → terminate.
  let assert Ok(found) =
    registry_api.lookup(state.registry, key, state.config.registry_timeout_ms)

  case found {
    None -> {
      process.send(reply_to, Ok(Nil))
      actor.continue(state)
    }
    Some(agent_ref) -> {
      let InstanceKey(_profile_id, instance_id) = key
      // Delete no debe bloquear el mailbox: hacer cleanup en un worker corto (IO).
      // Worker BEAM de IO: usar unlinked para que fallos externos no tumben al supervisor.
      process.spawn_unlinked(fn() {
        // 1) StopInstance: pasa a estado Stopped sin limpiar.
        agent.stop_instance(agent_ref, UserRequested)

        // 2) Cleanup de filesystem (IO). Si falla, devolver error explícito y mantener la instancia.
        case workspace.cleanup(state.config.workspaces_directory, instance_id) {
          Ok(_) -> {
            // 3) Purge de artefactos (SSOT en BEAM).
            artifact_registry_api.purge_by_instance(state.artifact_registry, instance_id)

            // 4) Release del puerto reservado (solo aplica a continuous con managed_port).
            // 5) Unregister de la instancia (ya no existe).
            registry_api.unregister(state.registry, key)

            // 6) Terminar el proceso BEAM del agente (delete = instancia desaparece).
            agent.terminate(agent_ref, Deleted)

            process.send(reply_to, Ok(Nil))
          }
          Error(e) -> {
            // Rollback de seguridad (v0): aunque el filesystem no se pueda limpiar,
            // dejamos de servir artefactos (los ArtifactIds dejan de resolverse).
            artifact_registry_api.purge_by_instance(state.artifact_registry, instance_id)
            process.send(reply_to, Error(CleanupFailed(e)))
          }
        }
      })

      actor.continue(state)
    }
  }
}
