////
//// Mission: define the pure agent lifecycle state and transitions.
////
//// Responsibilities:
//// - Represent the lifecycle state for an agent instance.
//// - Provide pure transition helpers for start/stop/provisioning outcomes.
//// - Gate interactions based on readiness.
////
//// Non-responsibilities:
//// - Spawning processes, timers, or sending messages.
//// - Managing monitors, selectors, or side effects.
////
//// Relationships:
//// - Used by `sad/core/agent` to drive effectful orchestration.

import gleam/dict
import gleam/option
import sad/bridge/port_owner
import sad/types/agent as types_agent
import sad/types/resolved_params.{type ResolvedParams}

/// Opaque resource associated with a continuous agent.
pub opaque type AgentResource {
  ContinuousServer(owner: port_owner.PortOwnerRef)
}

/// Builds an `AgentResource` from a port owner.
pub fn port_owner_resource(owner: port_owner.PortOwnerRef) -> AgentResource {
  ContinuousServer(owner)
}

/// Returns the port owner reference from a resource.
pub fn port_owner_ref(resource: AgentResource) -> port_owner.PortOwnerRef {
  let ContinuousServer(owner: owner) = resource
  owner
}

/// Unified lifecycle state for an agent instance.
pub type AgentState {
  Created(params: ResolvedParams)
  Provisioning(params: ResolvedParams)
  ReadyTransient(params: ResolvedParams)
  ReadyContinuous(params: ResolvedParams, resource: AgentResource)
  Stopped(params: ResolvedParams)
  Failed(reason: types_agent.FailureReason)
}

/// Returns the Created state.
pub fn agent_created(params: ResolvedParams) -> AgentState {
  Created(params)
}

/// Returns the Provisioning state.
pub fn agent_provisioning(params: ResolvedParams) -> AgentState {
  Provisioning(params)
}

/// Returns the ReadyTransient state.
pub fn agent_ready_transient(params: ResolvedParams) -> AgentState {
  ReadyTransient(params)
}

/// Returns the ReadyContinuous state.
pub fn agent_ready_continuous(
  params: ResolvedParams,
  resource: AgentResource,
) -> AgentState {
  ReadyContinuous(params, resource)
}

/// Returns the Stopped state.
pub fn agent_stopped(params: ResolvedParams) -> AgentState {
  Stopped(params)
}

/// Returns the Failed state.
pub fn agent_failed(reason: types_agent.FailureReason) -> AgentState {
  Failed(reason)
}

/// Returns True when the state is Created.
pub fn is_created(state: AgentState) -> Bool {
  case state {
    Created(_) -> True
    _ -> False
  }
}

/// Returns True when the state is Provisioning.
pub fn is_provisioning(state: AgentState) -> Bool {
  case state {
    Provisioning(_) -> True
    _ -> False
  }
}

/// Returns True when the state is ready.
pub fn is_ready(state: AgentState) -> Bool {
  case state {
    ReadyTransient(_) -> True
    ReadyContinuous(_, _) -> True
    _ -> False
  }
}

/// Returns True when the state is ReadyTransient.
pub fn is_ready_transient(state: AgentState) -> Bool {
  case state {
    ReadyTransient(_) -> True
    _ -> False
  }
}

/// Returns True when the state is ReadyContinuous.
pub fn is_ready_continuous(state: AgentState) -> Bool {
  case state {
    ReadyContinuous(_, _) -> True
    _ -> False
  }
}

/// Returns True when the state is Stopped.
pub fn is_stopped(state: AgentState) -> Bool {
  case state {
    Stopped(_) -> True
    _ -> False
  }
}

/// Returns True when the state is Failed.
pub fn is_failed(state: AgentState) -> Bool {
  case state {
    Failed(_) -> True
    _ -> False
  }
}

/// Returns the failure reason if present.
pub fn get_failure_reason(
  state: AgentState,
) -> option.Option(types_agent.FailureReason) {
  case state {
    Failed(reason) -> option.Some(reason)
    _ -> option.None
  }
}

/// Returns the continuous resource if present.
pub fn get_resource(state: AgentState) -> option.Option(AgentResource) {
  case state {
    ReadyContinuous(_, resource) -> option.Some(resource)
    _ -> option.None
  }
}

/// Returns the parameters for states that carry them.
pub fn get_params(state: AgentState) -> option.Option(ResolvedParams) {
  case state {
    Created(params)
    | Provisioning(params)
    | ReadyTransient(params)
    | Stopped(params) -> option.Some(params)

    ReadyContinuous(params, _) -> option.Some(params)

    Failed(_) -> option.None
  }
}

/// Decision returned when gating an interaction.
pub type InteractGate {
  Allow(params: ResolvedParams)
  RejectNotReady
}

/// Determines whether the agent can interact.
pub fn can_interact(state: AgentState) -> InteractGate {
  case state {
    ReadyTransient(params) -> Allow(params)
    ReadyContinuous(params, _) -> Allow(params)
    _ -> RejectNotReady
  }
}

/// Decision returned when stopping an instance.
pub type StopDecision {
  StopDecision(
    next_state: AgentState,
    resource_to_stop: option.Option(AgentResource),
  )
}

/// Applies a StopInstance transition and returns any resource to stop.
pub fn on_stop_instance(state: AgentState) -> StopDecision {
  case state {
    ReadyContinuous(params, resource) ->
      StopDecision(
        next_state: Stopped(params),
        resource_to_stop: option.Some(resource),
      )

    _ -> {
      let params = get_params(state) |> option.unwrap(dict.new())
      StopDecision(next_state: Stopped(params), resource_to_stop: option.None)
    }
  }
}

/// Applies a StartInstance transition.
pub fn on_start_instance(state: AgentState) -> AgentState {
  case state {
    Created(params) -> Provisioning(params)
    Stopped(params) -> Provisioning(params)
    _ -> state
  }
}

/// Applies a provisioning outcome to produce the next state.
pub fn on_provisioning_done(
  outcome: Result(#(AgentState, option.Option(Int)), types_agent.FailureReason),
) -> #(AgentState, option.Option(Int)) {
  case outcome {
    Ok(#(state, port)) -> #(state, port)
    Error(reason) -> #(Failed(reason), option.None)
  }
}

/// Returns the Failed state for a server death.
pub fn on_server_died() -> AgentState {
  Failed(types_agent.ServerDied)
}
