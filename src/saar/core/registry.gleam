////
//// Mission: keep the SSOT of active agent instances in memory.
////
//// Responsibilities:
//// - Enforce global uniqueness of `InstanceId`.
//// - Provide lookup and listing of `AgentRef`s.
//// - Monitor agents and automatically remove entries when they go down.
////
//// Non-responsibilities:
//// - Persisting or rehydrating state across restarts.
//// - Performing any IO or talking to HTTP.
////
//// Relationships:
//// - Message protocol lives in `saar/core/messages.RegistryMsg`.
//// - Boundary callers should use `saar/otp/safe_call` with `saar/core/messages.RegistryMsg`.

import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import saar/core/agent
import saar/core/messages
import saar/ffi
import saar/types/agent as types_agent
import saar/types/core as types_core

pub fn start(
  name: process.Name(messages.RegistryMsg),
) -> actor.StartResult(process.Subject(messages.RegistryMsg)) {
  let init = fn(self) {
    let selector =
      process.new_selector()
      |> process.select(self)

    actor.initialised(State(
      by_instance: dict.new(),
      by_pid: dict.new(),
      selector: selector,
    ))
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  }

  actor.new_with_initialiser(5000, init)
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

type State {
  State(
    by_instance: dict.Dict(types_core.InstanceId, RegistryEntry),
    by_pid: dict.Dict(process.Pid, types_core.InstanceId),
    selector: process.Selector(messages.RegistryMsg),
  )
}

type RegistryEntry {
  RegistryEntry(
    instance_id: types_core.InstanceId,
    profile_id: types_core.ProfileId,
    summary: types_agent.InstanceSummary,
    agent: agent.AgentRef,
    pid: process.Pid,
    monitor: process.Monitor,
  )
}

fn handle_message(
  state: State,
  msg: messages.RegistryMsg,
) -> actor.Next(State, messages.RegistryMsg) {
  case msg {
    messages.Register(status, agent_ref, reply_to) ->
      handle_register(state, status, agent_ref, reply_to)

    messages.Unregister(key) -> handle_unregister(state, key)

    messages.UnregisterByInstanceId(instance_id) ->
      handle_unregister_by_instance_id(state, instance_id)

    messages.Lookup(key, reply_to) -> {
      process.send(reply_to, lookup_by_key(state, key))
      actor.continue(state)
    }

    messages.LookupByInstanceId(instance_id, reply_to) -> {
      process.send(reply_to, lookup_by_instance_id(state, instance_id))
      actor.continue(state)
    }

    messages.LookupStatusByInstanceId(instance_id, reply_to) -> {
      process.send(reply_to, lookup_status_by_instance_id(state, instance_id))
      actor.continue(state)
    }

    messages.ListByProfile(profile_id, reply_to) -> {
      process.send(reply_to, list_by_profile(state, profile_id))
      actor.continue(state)
    }

    messages.ListAll(reply_to) -> {
      process.send(reply_to, list_all(state))
      actor.continue(state)
    }

    messages.UpdateStatus(instance_id, status) ->
      handle_update_status(state, instance_id, status)

    messages.AgentDown(down) -> handle_agent_down(state, down)
  }
}

fn handle_register(
  state: State,
  status: types_agent.AgentStatusView,
  agent_ref: agent.AgentRef,
  reply_to: process.Subject(Result(Nil, messages.RegistryError)),
) -> actor.Next(State, messages.RegistryMsg) {
  let #(profile_id, instance_id) = status_ids(status)

  case dict.has_key(state.by_instance, instance_id) {
    True -> {
      process.send(reply_to, Error(messages.AlreadyExists))
      actor.continue(state)
    }

    False -> {
      let pid = agent.pid(agent_ref)
      let monitor = process.monitor(pid)

      let selector =
        state.selector
        |> process.select_specific_monitor(monitor, messages.AgentDown)

      let now = ffi.now_ms()
      let summary =
        types_agent.InstanceSummary(
          status: status,
          registered_at: now,
          status_updated_at: now,
        )

      let entry =
        RegistryEntry(
          instance_id: instance_id,
          profile_id: profile_id,
          summary: summary,
          agent: agent_ref,
          pid: pid,
          monitor: monitor,
        )

      let next_state =
        State(
          by_instance: dict.insert(state.by_instance, instance_id, entry),
          by_pid: dict.insert(state.by_pid, pid, instance_id),
          selector: selector,
        )

      process.send(reply_to, Ok(Nil))

      actor.continue(next_state)
      |> actor.with_selector(selector)
    }
  }
}

fn handle_unregister(
  state: State,
  key: messages.InstanceKey,
) -> actor.Next(State, messages.RegistryMsg) {
  let messages.InstanceKey(profile_id, instance_id) = key

  case dict.get(state.by_instance, instance_id) {
    Error(_) -> actor.continue(state)

    Ok(RegistryEntry(profile_id: stored_profile, ..)) ->
      case stored_profile == profile_id {
        True -> remove_entry(state, instance_id)
        False -> actor.continue(state)
      }
  }
}

fn handle_unregister_by_instance_id(
  state: State,
  instance_id: types_core.InstanceId,
) -> actor.Next(State, messages.RegistryMsg) {
  remove_entry(state, instance_id)
}

fn handle_update_status(
  state: State,
  instance_id: types_core.InstanceId,
  status: types_agent.AgentStatusView,
) -> actor.Next(State, messages.RegistryMsg) {
  case dict.get(state.by_instance, instance_id) {
    Error(_) -> actor.continue(state)

    Ok(RegistryEntry(summary: summary, ..) as entry) -> {
      let types_agent.InstanceSummary(registered_at: registered_at, ..) =
        summary

      let updated =
        types_agent.InstanceSummary(
          status: status,
          registered_at: registered_at,
          status_updated_at: ffi.now_ms(),
        )

      let next_entry = RegistryEntry(..entry, summary: updated)
      let next_by_instance =
        dict.insert(state.by_instance, instance_id, next_entry)
      actor.continue(State(..state, by_instance: next_by_instance))
    }
  }
}

fn handle_agent_down(
  state: State,
  down: process.Down,
) -> actor.Next(State, messages.RegistryMsg) {
  let down_pid = case down {
    process.ProcessDown(pid: pid, ..) -> pid
    _ -> process.self()
  }

  case dict.get(state.by_pid, down_pid) {
    Error(_) -> actor.continue(state)

    Ok(instance_id) -> keep_entry_on_down(state, instance_id, down_pid, down)
  }
}

fn keep_entry_on_down(
  state: State,
  instance_id: types_core.InstanceId,
  down_pid: process.Pid,
  down: process.Down,
) -> actor.Next(State, messages.RegistryMsg) {
  case dict.get(state.by_instance, instance_id) {
    Error(_) -> {
      let next_by_pid = dict.delete(state.by_pid, down_pid)
      actor.continue(State(..state, by_pid: next_by_pid))
    }

    Ok(RegistryEntry(summary: summary, monitor: monitor, ..) as entry) -> {
      process.demonitor_process(monitor)

      let selector =
        state.selector
        |> process.deselect_specific_monitor(monitor)

      let updated_status = status_after_down(summary.status, down)

      let updated_summary =
        types_agent.InstanceSummary(
          ..summary,
          status: updated_status,
          status_updated_at: ffi.now_ms(),
        )

      let next_entry = RegistryEntry(..entry, summary: updated_summary)

      let next_state =
        State(
          by_instance: dict.insert(state.by_instance, instance_id, next_entry),
          by_pid: dict.delete(state.by_pid, down_pid),
          selector: selector,
        )

      actor.continue(next_state)
      |> actor.with_selector(selector)
    }
  }
}

fn status_after_down(
  status: types_agent.AgentStatusView,
  down: process.Down,
) -> types_agent.AgentStatusView {
  let stopped_status =
    types_agent.AgentStatusView(
      ..status,
      phase: types_agent.Stopped,
      mode: types_agent.RunIdle,
      assigned_port: None,
    )

  let failed_status =
    types_agent.AgentStatusView(
      ..status,
      phase: types_agent.Failed(types_agent.AgentDown),
      mode: types_agent.RunIdle,
      assigned_port: None,
    )

  case down {
    process.ProcessDown(_ref, _pid, process.Killed) -> stopped_status
    _ -> failed_status
  }
}

fn remove_entry(
  state: State,
  instance_id: types_core.InstanceId,
) -> actor.Next(State, messages.RegistryMsg) {
  case dict.get(state.by_instance, instance_id) {
    Error(_) -> actor.continue(state)

    Ok(RegistryEntry(pid: pid, monitor: monitor, ..)) -> {
      process.demonitor_process(monitor)

      let selector =
        state.selector
        |> process.deselect_specific_monitor(monitor)

      let next_state =
        State(
          by_instance: dict.delete(state.by_instance, instance_id),
          by_pid: dict.delete(state.by_pid, pid),
          selector: selector,
        )

      actor.continue(next_state)
      |> actor.with_selector(selector)
    }
  }
}

fn lookup_by_key(
  state: State,
  key: messages.InstanceKey,
) -> Option(agent.AgentRef) {
  let messages.InstanceKey(profile_id, instance_id) = key

  case dict.get(state.by_instance, instance_id) {
    Error(_) -> None

    Ok(RegistryEntry(profile_id: stored_profile, agent: agent_ref, ..)) ->
      case stored_profile == profile_id {
        True -> Some(agent_ref)
        False -> None
      }
  }
}

fn lookup_by_instance_id(
  state: State,
  instance_id: types_core.InstanceId,
) -> Option(agent.AgentRef) {
  case dict.get(state.by_instance, instance_id) {
    Error(_) -> None
    Ok(RegistryEntry(agent: agent_ref, ..)) -> Some(agent_ref)
  }
}

fn lookup_status_by_instance_id(
  state: State,
  instance_id: types_core.InstanceId,
) -> Option(types_agent.AgentStatusView) {
  case dict.get(state.by_instance, instance_id) {
    Error(_) -> None

    Ok(RegistryEntry(summary: summary, ..)) -> {
      let types_agent.InstanceSummary(status: status, ..) = summary
      Some(status)
    }
  }
}

fn list_by_profile(
  state: State,
  profile_id: types_core.ProfileId,
) -> List(types_core.InstanceId) {
  state.by_instance
  |> dict.values
  |> list.filter(fn(entry) {
    let RegistryEntry(profile_id: stored_profile, ..) = entry
    stored_profile == profile_id
  })
  |> list.map(fn(entry) {
    let RegistryEntry(instance_id: instance_id, ..) = entry
    instance_id
  })
  |> list.sort(fn(a, b) {
    string.compare(
      types_core.instance_id_to_string(a),
      types_core.instance_id_to_string(b),
    )
  })
}

fn list_all(state: State) -> List(types_agent.InstanceSummary) {
  state.by_instance
  |> dict.values
  |> list.sort(fn(a, b) {
    let RegistryEntry(instance_id: ia, ..) = a
    let RegistryEntry(instance_id: ib, ..) = b
    string.compare(
      types_core.instance_id_to_string(ia),
      types_core.instance_id_to_string(ib),
    )
  })
  |> list.map(fn(entry) {
    let RegistryEntry(summary: summary, ..) = entry
    summary
  })
}

fn status_ids(
  status: types_agent.AgentStatusView,
) -> #(types_core.ProfileId, types_core.InstanceId) {
  let types_agent.AgentStatusView(
    profile_id: profile_id,
    instance_id: instance_id,
    ..,
  ) = status

  #(profile_id, instance_id)
}
