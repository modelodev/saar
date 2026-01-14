////
//// Mission: implement the AgentActor and expose a safe, typed public API.
////
//// Responsibilities:
//// - Own the per-instance agent FSM (`AgentState`) and concurrency guard (`ActorMode`).
//// - Expose public commands (`status`, `info`, `interact`, `attach_logs`, `stop_instance`, `start_instance`, `terminate`).
//// - Maintain a bounded, byte-counted log ring buffer with takeover subscription.
////
//// Non-responsibilities:
//// - Resolving parameters (the actor receives `ResolvedParams` already resolved).
//// - Performing gateway IO (HTTP/SSE) or exposing internal message constructors.
////
//// Relationships:
//// - `sad/core/registry` stores and monitors `AgentRef` via `pid`.
//// - Internal event injection uses the `internal_*` functions below.

import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/string
import sad/bridge/interaction
import sad/bridge/port_owner
import sad/core/artifact_registry_protocol
import sad/ffi
import sad/otp/safe_call
import sad/streams/sink
import sad/types/agent as types_agent
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/input as types_input
import sad/types/log as types_log
import sad/types/output as types_output
import sad/types/profile as types_profile
import sad/types/resolved_params.{type ResolvedParams}

/// Opaque resource associated with a continuous agent.
///
/// In v0 this is a dedicated port owner process so stop/delete can reliably
/// close the underlying wrapper port.
pub opaque type AgentResource {
  ContinuousServer(owner: port_owner.PortOwnerRef)
}

pub fn port_owner_resource(owner: port_owner.PortOwnerRef) -> AgentResource {
  ContinuousServer(owner)
}

/// Unified internal agent state.
///
/// This ADT makes illegal states unrepresentable.
pub type AgentState {
  Created(params: ResolvedParams)
  Provisioning(params: ResolvedParams)
  ReadyTransient(params: ResolvedParams)
  ReadyContinuous(params: ResolvedParams, resource: AgentResource)
  Stopped(params: ResolvedParams)
  Failed(reason: String)
}

pub fn agent_created(params: ResolvedParams) -> AgentState {
  Created(params)
}

pub fn agent_provisioning(params: ResolvedParams) -> AgentState {
  Provisioning(params)
}

pub fn agent_ready_transient(params: ResolvedParams) -> AgentState {
  ReadyTransient(params)
}

pub fn agent_ready_continuous(
  params: ResolvedParams,
  resource: AgentResource,
) -> AgentState {
  ReadyContinuous(params, resource)
}

pub fn agent_stopped(params: ResolvedParams) -> AgentState {
  Stopped(params)
}

pub fn agent_failed(reason: String) -> AgentState {
  Failed(reason)
}

pub fn is_created(state: AgentState) -> Bool {
  case state {
    Created(_) -> True
    _ -> False
  }
}

pub fn is_provisioning(state: AgentState) -> Bool {
  case state {
    Provisioning(_) -> True
    _ -> False
  }
}

pub fn is_ready(state: AgentState) -> Bool {
  case state {
    ReadyTransient(_) -> True
    ReadyContinuous(_, _) -> True
    _ -> False
  }
}

pub fn is_ready_transient(state: AgentState) -> Bool {
  case state {
    ReadyTransient(_) -> True
    _ -> False
  }
}

pub fn is_ready_continuous(state: AgentState) -> Bool {
  case state {
    ReadyContinuous(_, _) -> True
    _ -> False
  }
}

pub fn is_stopped(state: AgentState) -> Bool {
  case state {
    Stopped(_) -> True
    _ -> False
  }
}

pub fn is_failed(state: AgentState) -> Bool {
  case state {
    Failed(_) -> True
    _ -> False
  }
}

pub fn get_failure_reason(state: AgentState) -> option.Option(String) {
  case state {
    Failed(reason) -> option.Some(reason)
    _ -> option.None
  }
}

pub fn get_resource(state: AgentState) -> option.Option(AgentResource) {
  case state {
    ReadyContinuous(_, resource) -> option.Some(resource)
    _ -> option.None
  }
}

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

/// Publicly safe request representation used by the AgentActor.
///
/// This value is passed to the bridge/worker layer; it must not include secrets.
pub type AgentRequest {
  AgentRequest(
    profile_id: types_core.ProfileId,
    instance_id: types_core.InstanceId,
    capability: String,
    inputs: types_input.InputPayload,
    context: types_input.RequestContext,
  )
}

/// A reply target for an in-flight interaction.
///
/// When a `StreamSink` is present, the bridge is responsible for pushing chunks.
pub type ReplyTarget {
  ReplyTo(
    process.Subject(
      Result(types_output.InteractionResult, types_output.InteractionError),
    ),
  )
  StreamTo(
    sink.StreamSink,
    process.Subject(
      Result(types_output.InteractionResult, types_output.InteractionError),
    ),
  )
}

/// Interaction metadata stored while the actor is Busy.
pub type InFlight {
  InFlight(
    trace_id: types_core.TraceId,
    started_at_ms: Int,
    capability_name: String,
    worker_ref: process.Pid,
    reply_to_or_sink: ReplyTarget,
  )
}

/// Actor concurrency mode.
///
/// This ADT makes it impossible to represent "Busy" without an in-flight record.
pub type ActorMode {
  Idle
  Busy(in_flight: InFlight)
}

/// Bounded log buffer with drop-oldest semantics.
///
/// The `lines` list is stored in chronological order: oldest -> newest.
pub type LogBuffer {
  LogBuffer(lines: List(types_log.LogEvent), total_bytes: Int)
}

pub fn empty_log_buffer() -> LogBuffer {
  LogBuffer(lines: [], total_bytes: 0)
}

/// Adds a log event to the ring buffer, dropping oldest-first.
///
/// The capacity is enforced by `byte_size(utf8(line))` and ignores metadata.
pub fn add_log_event(
  buffer: LogBuffer,
  event: types_log.LogEvent,
  max_bytes: Int,
) -> LogBuffer {
  let max_bytes = int.max(max_bytes, 0)

  case max_bytes <= 0 {
    True -> empty_log_buffer()

    False -> {
      let LogBuffer(lines: lines, total_bytes: total_bytes) = buffer

      let #(event, event_bytes) = clamp_log_event(event, max_bytes)

      let lines = list.append(lines, [event])
      let total_bytes = total_bytes + event_bytes

      drop_oldest(LogBuffer(lines: lines, total_bytes: total_bytes), max_bytes)
    }
  }
}

fn clamp_log_event(
  event: types_log.LogEvent,
  max_bytes: Int,
) -> #(types_log.LogEvent, Int) {
  let types_log.LogEvent(trace_id: trace_id, instance_id: instance_id, ..) =
    event

  let event_bytes = log_event_bytes(event)

  case event_bytes > max_bytes {
    True -> {
      let synthetic =
        types_log.log_event(
          types_log.SystemLog,
          "[log dropped: too large]",
          trace_id,
          instance_id,
        )

      #(synthetic, log_event_bytes(synthetic))
    }

    False -> #(event, event_bytes)
  }
}

fn drop_oldest(buffer: LogBuffer, max_bytes: Int) -> LogBuffer {
  let LogBuffer(lines: lines, total_bytes: total_bytes) = buffer

  case total_bytes <= max_bytes {
    True -> buffer

    False ->
      case lines {
        [] -> empty_log_buffer()

        [oldest, ..rest] -> {
          let total_bytes = total_bytes - log_event_bytes(oldest)
          drop_oldest(
            LogBuffer(lines: rest, total_bytes: total_bytes),
            max_bytes,
          )
        }
      }
  }
}

fn log_event_bytes(event: types_log.LogEvent) -> Int {
  let types_log.LogEvent(line: line, ..) = event
  string.byte_size(line)
}

/// Why an instance is being stopped.
pub type StopReason {
  UserRequested
  Deleted
  SupervisorCleanup
  NodeShuttingDown
  IdleTimeout
}

/// Internal state snapshot required to restart an agent.
///
/// This type is internal to SAD and may contain sensitive data (resolved params).
pub type StartSnapshot {
  StartSnapshot(
    profile: types_profile.Profile,
    instance_id: types_core.InstanceId,
    params: ResolvedParams,
    workspace: String,
    config: types_config.SadConfig,
  )
}

/// Internal message protocol of the AgentActor.
///
/// This protocol is intentionally not constructible outside this module.
/// Callers must use the functions in this module.
pub opaque type AgentMsg {
  Interact(
    req: AgentRequest,
    stream_sink: option.Option(sink.StreamSink),
    reply_to: process.Subject(
      Result(types_output.InteractionResult, types_output.InteractionError),
    ),
  )
  GetStatus(process.Subject(types_agent.AgentStatusView))
  GetInfo(process.Subject(types_agent.AgentInfoView))
  GetStartSnapshot(process.Subject(StartSnapshot))
  AttachLogs(process.Subject(types_log.LogEvent))
  StartInstance
  StopInstance(StopReason)
  Terminate(StopReason)
  ProvisioningDone(Result(#(AgentState, option.Option(Int)), String))
  InteractionDone(
    Result(types_output.InteractionResult, types_output.InteractionError),
  )
  IngestLog(types_log.LogEvent)
  WorkerDown(process.Down)
  ServerDied(Int)
  HardTimeout(types_core.TraceId)
}

/// Public handle for interacting with the AgentActor.
pub opaque type AgentRef {
  AgentRef(subject: process.Subject(AgentMsg), pid: process.Pid)
}

pub fn pid(agent: AgentRef) -> process.Pid {
  let AgentRef(pid: pid, ..) = agent
  pid
}

fn subject(agent: AgentRef) -> process.Subject(AgentMsg) {
  let AgentRef(subject: subject, ..) = agent
  subject
}

pub type AgentDeps {
  AgentDeps(
    start_interaction: fn(
      AgentRef,
      AgentRequest,
      Int,
      Bool,
      option.Option(sink.StreamSink),
    ) ->
      process.Pid,
    cancel_interaction: fn(process.Pid) -> Nil,
    stop_server: fn(AgentResource) -> Nil,
  )
}

pub fn default_deps() -> AgentDeps {
  AgentDeps(
    start_interaction: fn(_agent, _req, _timeout_ms, _streaming, _sink) {
      process.spawn(fn() { process.sleep(60_000) })
    },
    cancel_interaction: fn(pid) { process.kill(pid) },
    stop_server: fn(resource) {
      let ContinuousServer(owner: owner) = resource
      port_owner.stop_async(owner)
    },
  )
}

type AgentRuntimeState {
  AgentRuntimeState(
    self_ref: AgentRef,
    profile: types_profile.Profile,
    instance_id: types_core.InstanceId,
    lifecycle: types_enums.Lifecycle,
    workspace: String,
    state: AgentState,
    mode: ActorMode,
    log_buffer: LogBuffer,
    log_subscriber: option.Option(process.Subject(types_log.LogEvent)),
    config: types_config.SadConfig,
    artifact_registry: process.Subject(
      artifact_registry_protocol.ArtifactRegistryMsg,
    ),
    deps: AgentDeps,
    selector: process.Selector(AgentMsg),
    assigned_port: option.Option(Int),
    worker_monitor: option.Option(process.Monitor),
    hard_timeout_pid: option.Option(process.Pid),
  )
}

/// Starts an AgentActor.
///
/// `deps` is injected so the actor can stay pure at the boundary.
pub fn start_link(
  profile: types_profile.Profile,
  instance_id: types_core.InstanceId,
  params: ResolvedParams,
  workspace: String,
  config: types_config.SadConfig,
  artifact_registry: process.Subject(
    artifact_registry_protocol.ArtifactRegistryMsg,
  ),
  deps: AgentDeps,
  init_timeout_ms: Int,
) -> actor.StartResult(AgentRef) {
  actor.new_with_initialiser(init_timeout_ms, fn(self) {
    let selector =
      process.new_selector()
      |> process.select(self)

    let self_ref = AgentRef(subject: self, pid: process.self())

    let state =
      AgentRuntimeState(
        self_ref: self_ref,
        profile: profile,
        instance_id: instance_id,
        lifecycle: profile.meta.lifecycle,
        workspace: workspace,
        state: agent_created(params),
        mode: Idle,
        log_buffer: empty_log_buffer(),
        log_subscriber: option.None,
        config: config,
        artifact_registry: artifact_registry,
        deps: deps,
        selector: selector,
        assigned_port: option.None,
        worker_monitor: option.None,
        hard_timeout_pid: option.None,
      )

    Ok(
      actor.initialised(state)
      |> actor.selecting(selector)
      |> actor.returning(self_ref),
    )
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  state: AgentRuntimeState,
  msg: AgentMsg,
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  case msg {
    GetStatus(reply_to) -> {
      process.send(reply_to, to_status_view(state))
      actor.continue(state)
    }

    GetInfo(reply_to) -> {
      process.send(reply_to, to_info_view(state))
      actor.continue(state)
    }

    GetStartSnapshot(reply_to) -> {
      process.send(reply_to, to_start_snapshot(state))
      actor.continue(state)
    }

    AttachLogs(subscriber) -> handle_attach_logs(state, subscriber)

    IngestLog(event) -> handle_ingest_log(state, event)

    ProvisioningDone(outcome) -> handle_provisioning_done(state, outcome)

    Interact(req, stream_sink, reply_to) ->
      handle_interact(state, req, stream_sink, reply_to)

    InteractionDone(result) -> handle_interaction_done(state, result)

    WorkerDown(down) -> handle_worker_down(state, down)

    HardTimeout(trace_id) -> handle_hard_timeout(state, trace_id)

    StopInstance(reason) -> handle_stop_instance(state, reason)

    StartInstance -> handle_start_instance(state)

    ServerDied(exit_code) -> handle_server_died(state, exit_code)

    Terminate(reason) -> handle_terminate(state, reason)
  }
}

fn to_status_view(state: AgentRuntimeState) -> types_agent.AgentStatusView {
  let phase = case state.state {
    Created(_) -> types_agent.Created
    Provisioning(_) -> types_agent.Provisioning
    ReadyTransient(_) -> types_agent.ReadyTransient
    ReadyContinuous(_, _) -> types_agent.ReadyContinuous
    Stopped(_) -> types_agent.Stopped
    Failed(_) -> types_agent.Failed
  }

  let mode = case state.mode {
    Idle -> types_agent.RunIdle
    Busy(_) -> types_agent.RunBusy
  }

  types_agent.AgentStatusView(
    profile_id: state.profile.meta.id,
    instance_id: state.instance_id,
    lifecycle: state.lifecycle,
    phase: phase,
    mode: mode,
    assigned_port: state.assigned_port,
    failure_reason: get_failure_reason(state.state),
  )
}

fn to_info_view(state: AgentRuntimeState) -> types_agent.AgentInfoView {
  types_agent.AgentInfoView(
    meta: state.profile.meta,
    runner: state.profile.runner,
    interface: state.profile.interface,
    status: to_status_view(state),
  )
}

fn to_start_snapshot(state: AgentRuntimeState) -> StartSnapshot {
  let params = get_params(state.state) |> option.unwrap(dict.new())

  StartSnapshot(
    profile: state.profile,
    instance_id: state.instance_id,
    params: params,
    workspace: state.workspace,
    config: state.config,
  )
}

fn handle_attach_logs(
  state: AgentRuntimeState,
  subscriber: process.Subject(types_log.LogEvent),
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  state.log_buffer.lines
  |> list.each(fn(event) { process.send(subscriber, event) })

  actor.continue(
    AgentRuntimeState(..state, log_subscriber: option.Some(subscriber)),
  )
}

fn handle_ingest_log(
  state: AgentRuntimeState,
  event: types_log.LogEvent,
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  let max_bytes = log_buffer_limit_bytes(state.config)
  let buffer = add_log_event(state.log_buffer, event, max_bytes)

  case state.log_subscriber {
    option.Some(sub) -> process.send(sub, event)
    option.None -> Nil
  }

  actor.continue(AgentRuntimeState(..state, log_buffer: buffer))
}

fn log_buffer_limit_bytes(cfg: types_config.SadConfig) -> Int {
  let types_config.SadConfig(limits: limits, ..) = cfg
  let types_config.SadLimits(log_buffer_bytes: log_buffer_bytes, ..) = limits
  log_buffer_bytes
}

fn handle_provisioning_done(
  state: AgentRuntimeState,
  outcome: Result(#(AgentState, option.Option(Int)), String),
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  let #(next_state, assigned_port) = case outcome {
    Ok(#(state, port)) -> #(state, port)
    Error(reason) -> #(agent_failed(reason), option.None)
  }

  actor.continue(
    AgentRuntimeState(..state, state: next_state, assigned_port: assigned_port),
  )
}

fn handle_interact(
  state: AgentRuntimeState,
  req: AgentRequest,
  stream_sink: option.Option(sink.StreamSink),
  reply_to: process.Subject(
    Result(types_output.InteractionResult, types_output.InteractionError),
  ),
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  let AgentRequest(context: context, ..) = req

  case state.mode {
    Busy(_) -> {
      let err =
        types_output.sad_error(
          context.trace_id,
          types_enums.AgentError,
          "interact_while_busy",
        )
      process.send(reply_to, Error(err))
      actor.continue(state)
    }

    Idle ->
      case is_ready(state.state) {
        False -> {
          let err =
            types_output.sad_error(
              context.trace_id,
              types_enums.InfraError,
              "not_ready",
            )
          process.send(reply_to, Error(err))
          actor.continue(state)
        }

        True -> start_interaction(state, req, stream_sink, reply_to)
      }
  }
}

fn start_interaction(
  state: AgentRuntimeState,
  req: AgentRequest,
  stream_sink: option.Option(sink.StreamSink),
  reply_to: process.Subject(
    Result(types_output.InteractionResult, types_output.InteractionError),
  ),
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  let AgentRequest(context: context, capability: capability, ..) = req

  let streaming =
    option.is_some(stream_sink)
    && is_streaming_capability(state.profile.interface, capability)

  let timeout_ms =
    resolve_call_timeout_for(state.config, state.profile.interface, capability)

  let params = get_params(state.state) |> option.unwrap(dict.new())

  let worker_pid =
    process.spawn(fn() {
      let AgentRequest(
        profile_id: profile_id,
        instance_id: instance_id,
        capability: capability_name,
        inputs: inputs,
        context: ctx,
      ) = req

      let out =
        interaction.run(
          state.profile,
          profile_id,
          instance_id,
          capability_name,
          inputs,
          ctx,
          params,
          state.workspace,
          state.config,
          state.artifact_registry,
          state.assigned_port,
          streaming,
          stream_sink,
        )

      internal_interaction_done(state.self_ref, out)
    })

  let monitor = process.monitor(worker_pid)
  let selector =
    state.selector
    |> process.select_specific_monitor(monitor, fn(down) { WorkerDown(down) })

  let started_at_ms = ffi.now_ms()

  let target = case stream_sink {
    option.Some(s) -> StreamTo(s, reply_to)
    option.None -> ReplyTo(reply_to)
  }

  let in_flight =
    InFlight(
      trace_id: context.trace_id,
      started_at_ms: started_at_ms,
      capability_name: capability,
      worker_ref: worker_pid,
      reply_to_or_sink: target,
    )

  let timeout_pid =
    spawn_hard_timeout(subject(state.self_ref), context.trace_id, timeout_ms)

  let next =
    AgentRuntimeState(
      ..state,
      mode: Busy(in_flight),
      selector: selector,
      worker_monitor: option.Some(monitor),
      hard_timeout_pid: option.Some(timeout_pid),
    )

  actor.continue(next)
  |> actor.with_selector(selector)
}

fn spawn_hard_timeout(
  inbox: process.Subject(AgentMsg),
  trace_id: types_core.TraceId,
  timeout_ms: Int,
) -> process.Pid {
  let timeout_ms = int.max(timeout_ms, 1)
  process.spawn(fn() {
    process.sleep(timeout_ms)
    process.send(inbox, HardTimeout(trace_id))
  })
}

/// Resolves the effective hard timeout for a capability.
///
/// Uses `capability.limits.call_timeout_ms` when present; otherwise falls back to
/// `config.timeouts.call_timeout_ms`.
pub fn resolve_call_timeout_for(
  cfg: types_config.SadConfig,
  interface: types_profile.Interface,
  capability_name: String,
) -> Int {
  let types_config.SadConfig(timeouts: timeouts, ..) = cfg
  let types_config.SadTimeouts(call_timeout_ms: default_timeout_ms, ..) =
    timeouts

  let maybe_limits = case interface {
    types_profile.HttpInterface(_, _, _, caps) ->
      case dict.get(caps, capability_name) {
        Ok(cap) -> cap.limits
        Error(_) -> option.None
      }

    types_profile.RunnerInterface(caps) ->
      case dict.get(caps, capability_name) {
        Ok(cap) -> cap.limits
        Error(_) -> option.None
      }
  }

  case maybe_limits {
    option.None -> default_timeout_ms

    option.Some(types_profile.CapabilityLimits(call_timeout_ms: maybe)) ->
      case maybe {
        option.Some(ms) -> ms
        option.None -> default_timeout_ms
      }
  }
}

fn is_streaming_capability(
  interface: types_profile.Interface,
  capability_name: String,
) -> Bool {
  let maybe_streaming = case interface {
    types_profile.HttpInterface(_, _, _, caps) ->
      case dict.get(caps, capability_name) {
        Ok(cap) -> option.Some(cap.streaming)
        Error(_) -> option.None
      }

    types_profile.RunnerInterface(caps) ->
      case dict.get(caps, capability_name) {
        Ok(cap) -> option.Some(cap.streaming)
        Error(_) -> option.None
      }
  }

  case maybe_streaming {
    option.Some(streaming) -> streaming
    option.None -> False
  }
}

fn handle_interaction_done(
  state: AgentRuntimeState,
  result: Result(types_output.InteractionResult, types_output.InteractionError),
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  case state.mode {
    Idle -> actor.continue(state)

    Busy(in_flight) -> {
      send_in_flight_reply(in_flight, result)
      actor.continue(clear_in_flight(state))
    }
  }
}

fn handle_worker_down(
  state: AgentRuntimeState,
  _down: process.Down,
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  case state.mode {
    Idle -> actor.continue(state)

    Busy(in_flight) -> {
      let InFlight(trace_id: trace_id, ..) = in_flight
      let err =
        types_output.sad_error(trace_id, types_enums.InfraError, "worker_down")
      send_in_flight_reply(in_flight, Error(err))
      actor.continue(clear_in_flight(state))
    }
  }
}

fn handle_hard_timeout(
  state: AgentRuntimeState,
  trace_id: types_core.TraceId,
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  case state.mode {
    Idle -> actor.continue(state)

    Busy(in_flight) -> {
      let InFlight(trace_id: in_flight_trace, worker_ref: worker_ref, ..) =
        in_flight

      case in_flight_trace == trace_id {
        False -> actor.continue(state)

        True -> {
          let AgentDeps(cancel_interaction: cancel_interaction, ..) = state.deps
          cancel_interaction(worker_ref)

          let err =
            types_output.sad_error(trace_id, types_enums.InfraError, "timeout")
          send_in_flight_reply(in_flight, Error(err))
          actor.continue(clear_in_flight(state))
        }
      }
    }
  }
}

fn clear_in_flight(state: AgentRuntimeState) -> AgentRuntimeState {
  let selector = clear_worker_monitor(state)

  case state.hard_timeout_pid {
    option.Some(pid) -> process.kill(pid)
    option.None -> Nil
  }

  AgentRuntimeState(
    ..state,
    mode: Idle,
    selector: selector,
    worker_monitor: option.None,
    hard_timeout_pid: option.None,
  )
}

fn clear_worker_monitor(state: AgentRuntimeState) -> process.Selector(AgentMsg) {
  case state.worker_monitor {
    option.Some(monitor) -> {
      process.demonitor_process(monitor)
      state.selector
      |> process.deselect_specific_monitor(monitor)
    }

    option.None -> state.selector
  }
}

fn send_in_flight_reply(
  in_flight: InFlight,
  result: Result(types_output.InteractionResult, types_output.InteractionError),
) -> Nil {
  let InFlight(reply_to_or_sink: target, ..) = in_flight
  case target {
    ReplyTo(reply_to) -> process.send(reply_to, result)
    StreamTo(_sink, reply_to) -> process.send(reply_to, result)
  }
}

fn handle_stop_instance(
  state: AgentRuntimeState,
  _reason: StopReason,
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  let state = cancel_if_busy(state, "cancelled")

  let #(params, maybe_resource) = case state.state {
    ReadyContinuous(params, resource) -> #(params, option.Some(resource))
    _ -> #(get_params(state.state) |> option.unwrap(dict.new()), option.None)
  }

  case maybe_resource {
    option.Some(resource) -> {
      let AgentDeps(stop_server: stop_server, ..) = state.deps
      stop_server(resource)
    }
    option.None -> Nil
  }

  actor.continue(
    AgentRuntimeState(
      ..state,
      state: agent_stopped(params),
      assigned_port: option.None,
    ),
  )
}

fn cancel_if_busy(state: AgentRuntimeState, code: String) -> AgentRuntimeState {
  case state.mode {
    Idle -> state

    Busy(in_flight) -> {
      let InFlight(trace_id: trace_id, worker_ref: worker_ref, ..) = in_flight

      let AgentDeps(cancel_interaction: cancel_interaction, ..) = state.deps
      cancel_interaction(worker_ref)

      let err = types_output.sad_error(trace_id, types_enums.AgentError, code)
      send_in_flight_reply(in_flight, Error(err))

      clear_in_flight(state)
    }
  }
}

fn handle_start_instance(
  state: AgentRuntimeState,
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  let next_state = case state.state {
    Created(params) -> agent_provisioning(params)
    Stopped(params) -> agent_provisioning(params)
    _ -> state.state
  }

  actor.continue(AgentRuntimeState(..state, state: next_state))
}

fn handle_server_died(
  state: AgentRuntimeState,
  exit_code: Int,
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  let state = cancel_if_busy(state, "cancelled")
  actor.continue(
    AgentRuntimeState(
      ..state,
      state: agent_failed("server_died:" <> int.to_string(exit_code)),
    ),
  )
}

fn handle_terminate(
  state: AgentRuntimeState,
  _reason: StopReason,
) -> actor.Next(AgentRuntimeState, AgentMsg) {
  let state = cancel_if_busy(state, "cancelled")

  case state.state {
    ReadyContinuous(_, resource) -> {
      let AgentDeps(stop_server: stop_server, ..) = state.deps
      stop_server(resource)
    }

    _ -> Nil
  }

  process.kill(process.self())
  actor.continue(state)
}

/// Returns the configured status timeout.
///
/// This is a small helper so callers can stay consistent.
pub fn status_timeout_ms(cfg: types_config.SadConfig) -> Int {
  let types_config.SadConfig(timeouts: timeouts, ..) = cfg
  let types_config.SadTimeouts(status_timeout_ms: status_timeout_ms, ..) =
    timeouts
  status_timeout_ms
}

/// Returns a status view using a safe call.
///
/// Callers must provide an explicit timeout.
pub fn status(
  agent: AgentRef,
  timeout_ms: Int,
) -> Result(types_agent.AgentStatusView, safe_call.CallError) {
  safe_call.call_within(subject(agent), timeout_ms, fn(reply_to) {
    GetStatus(reply_to)
  })
}

/// Returns a full info view using a safe call.
///
/// Callers must provide an explicit timeout.
pub fn info(
  agent: AgentRef,
  timeout_ms: Int,
) -> Result(types_agent.AgentInfoView, safe_call.CallError) {
  safe_call.call_within(subject(agent), timeout_ms, fn(reply_to) {
    GetInfo(reply_to)
  })
}

/// Requests a log subscription takeover.
///
/// The subscriber receives a replay (oldest -> newest) and then live events.
pub fn attach_logs(
  agent: AgentRef,
  subscriber: process.Subject(types_log.LogEvent),
) -> Nil {
  process.send(subject(agent), AttachLogs(subscriber))
}

/// Executes a single interaction.
///
/// - If the actor is Busy, the call is rejected with `AgentError` and message
///   `interact_while_busy`.
/// - Call failures are mapped into `InfraError` using the request trace id.
pub fn interact(
  agent: AgentRef,
  req: AgentRequest,
  stream_sink: option.Option(sink.StreamSink),
  timeout_ms: Int,
) -> Result(types_output.InteractionResult, types_output.InteractionError) {
  let AgentRequest(context: context, ..) = req

  safe_call.call_within(subject(agent), timeout_ms, fn(reply_to) {
    Interact(req, stream_sink, reply_to)
  })
  |> unwrap_or_disconnected(context.trace_id)
}

fn unwrap_or_disconnected(
  out: Result(
    Result(types_output.InteractionResult, types_output.InteractionError),
    safe_call.CallError,
  ),
  trace_id: types_core.TraceId,
) -> Result(types_output.InteractionResult, types_output.InteractionError) {
  case out {
    Ok(reply) -> reply

    Error(safe_call.Disconnected) ->
      Error(types_output.sad_error(
        trace_id,
        types_enums.InfraError,
        "disconnected",
      ))

    Error(safe_call.TimedOut) ->
      Error(types_output.sad_error(trace_id, types_enums.InfraError, "timeout"))
  }
}

/// Requests the instance to stop (idempotent).
pub fn stop_instance(agent: AgentRef, reason: StopReason) -> Nil {
  process.send(subject(agent), StopInstance(reason))
}

/// Requests the instance to start again.
pub fn start_instance(agent: AgentRef) -> Nil {
  process.send(subject(agent), StartInstance)
}

/// Requests the actor to terminate (delete/shutdown).
pub fn terminate(agent: AgentRef, reason: StopReason) -> Nil {
  process.send(subject(agent), Terminate(reason))
}

/// Internal-only: injects the provisioning outcome.
///
/// This is intended for core modules (not the gateway).
pub fn internal_provisioning_done(
  agent: AgentRef,
  outcome: Result(#(AgentState, option.Option(Int)), String),
) -> Nil {
  process.send(subject(agent), ProvisioningDone(outcome))
}

/// Internal-only: ingests a runner log line.
///
/// This is intended for core modules (not the gateway).
pub fn internal_ingest_log(agent: AgentRef, event: types_log.LogEvent) -> Nil {
  process.send(subject(agent), IngestLog(event))
}

/// Internal-only: signals that an interaction is done.
///
/// This is intended for core modules (not the gateway).
pub fn internal_interaction_done(
  agent: AgentRef,
  result: Result(types_output.InteractionResult, types_output.InteractionError),
) -> Nil {
  process.send(subject(agent), InteractionDone(result))
}

/// Internal-only: returns a snapshot required to restart the instance.
///
/// This is intended for core modules (not the gateway).
pub fn internal_start_snapshot(
  agent: AgentRef,
  timeout_ms: Int,
) -> Result(StartSnapshot, safe_call.CallError) {
  safe_call.call_within(subject(agent), timeout_ms, fn(reply_to) {
    GetStartSnapshot(reply_to)
  })
}

/// Internal-only: signals that the continuous server died.
///
/// This is intended for core modules (not the gateway).
pub fn internal_server_died(agent: AgentRef, exit_code: Int) -> Nil {
  process.send(subject(agent), ServerDied(exit_code))
}
