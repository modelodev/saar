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
import sad/types/agent as types_agent
import sad/types/resolved_params.{type ResolvedParams}

/// Unified lifecycle state for an agent instance.
pub type AgentState(resource) {
  Created(params: ResolvedParams)
  Provisioning(params: ResolvedParams)
  ReadyTransient(params: ResolvedParams)
  ReadyContinuous(params: ResolvedParams, resource: resource)
  Stopped(params: ResolvedParams)
  Failed(reason: types_agent.FailureReason)
}

/// Returns the Created state.
pub fn agent_created(params: ResolvedParams) -> AgentState(resource) {
  Created(params)
}

/// Returns the Provisioning state.
pub fn agent_provisioning(params: ResolvedParams) -> AgentState(resource) {
  Provisioning(params)
}

/// Returns the ReadyTransient state.
pub fn agent_ready_transient(params: ResolvedParams) -> AgentState(resource) {
  ReadyTransient(params)
}

/// Returns the ReadyContinuous state.
pub fn agent_ready_continuous(
  params: ResolvedParams,
  resource: resource,
) -> AgentState(resource) {
  ReadyContinuous(params, resource)
}

/// Returns the Stopped state.
pub fn agent_stopped(params: ResolvedParams) -> AgentState(resource) {
  Stopped(params)
}

/// Returns the Failed state.
pub fn agent_failed(reason: types_agent.FailureReason) -> AgentState(resource) {
  Failed(reason)
}

/// Returns True when the state is Created.
pub fn is_created(state: AgentState(resource)) -> Bool {
  case state {
    Created(_) -> True
    _ -> False
  }
}

/// Returns True when the state is Provisioning.
pub fn is_provisioning(state: AgentState(resource)) -> Bool {
  case state {
    Provisioning(_) -> True
    _ -> False
  }
}

/// Returns True when the state is ready.
pub fn is_ready(state: AgentState(resource)) -> Bool {
  case state {
    ReadyTransient(_) -> True
    ReadyContinuous(_, _) -> True
    _ -> False
  }
}

/// Returns True when the state is ReadyTransient.
pub fn is_ready_transient(state: AgentState(resource)) -> Bool {
  case state {
    ReadyTransient(_) -> True
    _ -> False
  }
}

/// Returns True when the state is ReadyContinuous.
pub fn is_ready_continuous(state: AgentState(resource)) -> Bool {
  case state {
    ReadyContinuous(_, _) -> True
    _ -> False
  }
}

/// Returns True when the state is Stopped.
pub fn is_stopped(state: AgentState(resource)) -> Bool {
  case state {
    Stopped(_) -> True
    _ -> False
  }
}

/// Returns True when the state is Failed.
pub fn is_failed(state: AgentState(resource)) -> Bool {
  case state {
    Failed(_) -> True
    _ -> False
  }
}

/// Returns the failure reason if present.
pub fn get_failure_reason(
  state: AgentState(resource),
) -> option.Option(types_agent.FailureReason) {
  case state {
    Failed(reason) -> option.Some(reason)
    _ -> option.None
  }
}

/// Returns the continuous resource if present.
pub fn get_resource(state: AgentState(resource)) -> option.Option(resource) {
  case state {
    ReadyContinuous(_, resource) -> option.Some(resource)
    _ -> option.None
  }
}

/// Returns the parameters for states that carry them.
pub fn get_params(state: AgentState(resource)) -> option.Option(ResolvedParams) {
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
pub fn can_interact(state: AgentState(resource)) -> InteractGate {
  case state {
    ReadyTransient(params) -> Allow(params)
    ReadyContinuous(params, _) -> Allow(params)
    _ -> RejectNotReady
  }
}

/// Decision returned when stopping an instance.
pub type StopDecision(resource) {
  StopDecision(
    next_state: AgentState(resource),
    resource_to_stop: option.Option(resource),
  )
}

/// Applies a StopInstance transition and returns any resource to stop.
pub fn on_stop_instance(state: AgentState(resource)) -> StopDecision(resource) {
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
pub fn on_start_instance(state: AgentState(resource)) -> AgentState(resource) {
  case state {
    Created(params) -> Provisioning(params)
    Stopped(params) -> Provisioning(params)
    _ -> state
  }
}

/// Applies a provisioning outcome to produce the next state.
pub fn on_provisioning_done(
  outcome: Result(
    #(AgentState(resource), option.Option(Int)),
    types_agent.FailureReason,
  ),
) -> #(AgentState(resource), option.Option(Int)) {
  case outcome {
    Ok(#(state, port)) -> #(state, port)
    Error(reason) -> #(Failed(reason), option.None)
  }
}

/// Returns the Failed state for a server death.
pub fn on_server_died() -> AgentState(resource) {
  Failed(types_agent.ServerDied)
}
