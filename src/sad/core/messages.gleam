////
//// Mission: define internal OTP message protocols shared across core actors.
////
//// Responsibilities:
//// - Provide the SSOT for internal message ADTs (`RegistryMsg`, `ProfilesMsg`, ...).
//// - Keep these types separate from domain/wire types (no HTTP concerns here).
////
//// Non-responsibilities:
//// - Implementing any actor logic.
//// - Providing HTTP-facing request/response types.
//// - Defining the artifact registry protocol (see
////   `sad/core/artifact_registry_protocol`).
////
//// Relationships:
//// - Used by core actors under `sad/core/*`.
//// - References domain primitives from `sad/types/*` and the public agent handle
////   from `sad/core/agent`.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Down, type Subject}
import gleam/option.{type Option}
import gleam/result
import gleam/string
import sad/core/agent.{type AgentRef}
import sad/core/artifact_registry_protocol
import sad/port_pool.{type PortPoolError}
import sad/types/agent as types_agent
import sad/types/config.{type SadConfig}
import sad/types/core as types_core
import sad/types/profile.{type Profile}
import sad/types/resolved_params.{type ResolvedParams}

/// Composite key used to identify an instance.
///
/// Note: in v0 `InstanceId` is globally unique, but `ProfileId` is still carried
/// for compatibility and profile-scoped list queries.
pub type InstanceKey {
  InstanceKey(
    profile_id: types_core.ProfileId,
    instance_id: types_core.InstanceId,
  )
}

/// Errors returned when parsing an `InstanceKey`.
pub type InstanceKeyError {
  InvalidFormat
  InvalidInstanceId(types_core.InstanceIdError)
}

/// Renders an `InstanceKey` to a stable string representation.
///
/// Format: `<profile_id>:<instance_id>`.
pub fn instance_key_to_string(key: InstanceKey) -> String {
  let InstanceKey(profile_id, instance_id) = key
  types_core.profile_id_to_string(profile_id)
  <> ":"
  <> types_core.instance_id_to_string(instance_id)
}

/// Parses an `InstanceKey` from `instance_key_to_string`.
pub fn instance_key_from_string(
  raw: String,
) -> Result(InstanceKey, InstanceKeyError) {
  case string.split(raw, ":") {
    [profile_raw, instance_raw] -> {
      use instance_id <- result.try(
        types_core.instance_id(instance_raw)
        |> result.map_error(InvalidInstanceId),
      )

      Ok(InstanceKey(types_core.profile_id(profile_raw), instance_id))
    }

    _ -> Error(InvalidFormat)
  }
}

/// Errors produced by `RegistryMsg.Register`.
pub type RegistryError {
  AlreadyExists
  RegistryFull
}

/// Message protocol for the RegistryActor.
pub type RegistryMsg {
  Register(
    status: types_agent.AgentStatusView,
    agent: AgentRef,
    reply_to: Subject(Result(Nil, RegistryError)),
  )
  Unregister(InstanceKey)
  UnregisterByInstanceId(types_core.InstanceId)
  Lookup(InstanceKey, Subject(Option(AgentRef)))
  LookupByInstanceId(types_core.InstanceId, Subject(Option(AgentRef)))
  LookupStatusByInstanceId(
    types_core.InstanceId,
    Subject(Option(types_agent.AgentStatusView)),
  )
  ListByProfile(types_core.ProfileId, Subject(List(types_core.InstanceId)))
  ListAll(Subject(List(types_agent.InstanceSummary)))
  UpdateStatus(types_core.InstanceId, types_agent.AgentStatusView)
  AgentDown(Down)
}

/// Arguments used to create an agent instance.
pub type StartArgs {
  StartArgs(
    profile: Profile,
    instance_id: types_core.InstanceId,
    params: ResolvedParams,
    workspace: String,
    config: SadConfig,
    artifact_registry: Subject(artifact_registry_protocol.ArtifactRegistryMsg),
  )
}

/// Message protocol for the AgentManagerActor.
///
/// Public callers should only send `Cmd` values.
pub type AgentManagerMsg {
  Cmd(AgentManagerCmd)
  Internal(AgentManagerInternal)
}

/// External commands accepted by the AgentManagerActor.
pub type AgentManagerCmd {
  /// Creates and starts an agent from a `profile_id`.
  ///
  /// This is the gateway-friendly entry point used by `/sys/agents`.
  CreateAgent(
    types_core.ProfileId,
    types_core.InstanceId,
    Dict(String, types_core.Value),
    Subject(Result(AgentRef, StartError)),
  )
  StartAgent(StartArgs, Subject(Result(AgentRef, StartError)))
  StopAgent(types_core.InstanceId, Subject(Result(Nil, StopError)))
  StartExistingAgent(types_core.InstanceId, Subject(Result(Nil, Nil)))
  DeleteAgent(types_core.InstanceId, Subject(Result(Nil, DeleteError)))
  ListAgents(Subject(List(types_agent.InstanceSummary)))
}

/// Internal events handled by the AgentManagerActor.
pub type AgentManagerInternal {
  DeleteWorkerDone(types_core.InstanceId, Result(Nil, DeleteError))
  DeleteWorkerDown(Down)
}

pub type StartError {
  InitFailed(String)
  RegistrationFailed(RegistryError)
  ProfileNotFound(types_core.ProfileId)
  ParamResolutionFailed(String)
  StartChildFailed(String)
}

pub type StopError {
  AgentNotFound
  StopTimeout
}

pub type DeleteError {
  DeleteTimeout
  CleanupFailed(String)
  DeleteWorkerCrashed
}

/// Message protocol for the ProfilesActor.
pub type ProfilesMsg {
  SetProfiles(Dict(types_core.ProfileId, Profile), Subject(Int))
  GetProfile(types_core.ProfileId, Subject(Option(Profile)))
  ListProfiles(Subject(List(types_core.ProfileId)))
}

/// Message protocol for the PortPoolActor.
pub type PortPoolMsg {
  Allocate(types_core.InstanceId, Subject(Result(Int, PortPoolError)))
  AllocateChecked(
    host: String,
    instance_id: types_core.InstanceId,
    reply_to: Subject(Result(Int, PortPoolError)),
  )
  Release(types_core.InstanceId, Subject(Nil))
}
