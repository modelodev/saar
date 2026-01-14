import agent_helpers
import gleam/dict
import gleam/erlang/process
import gleam/option
import gleam/otp/actor
import gleeunit
import gleeunit/should
import sad/core/agent
import sad/otp/safe_call
import sad/types/agent as types_agent
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/enums as types_enums
import sad/types/input as types_input
import sad/types/log as types_log
import sad/types/output as types_output
import sad/types/profile as types_profile

pub fn main() {
  gleeunit.main()
}

pub fn status_view_uses_phase_and_mode() {
  let config = types_config.default_sad_config()
  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-status")

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      "./workspaces/test",
      config,
      process.new_subject(),
      agent.default_deps(),
      1000,
    )

  let assert Ok(types_agent.AgentStatusView(phase: phase, mode: mode, ..)) =
    agent.status(agent_ref, 1000)

  phase |> should.equal(types_agent.Created)
  mode |> should.equal(types_agent.RunIdle)
}

pub fn run_mode_matches_actor_mode() {
  let started = process.new_subject()
  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())

  let config =
    types_config.default_sad_config()
    |> agent_helpers.with_call_timeout_ms(5000)

  let assert Ok(instance_id) = types_core.instance_id("inst-mode")

  let deps =
    agent.AgentDeps(
      start_interaction: fn(_agent_ref, _req, _timeout_ms, _streaming, _sink) {
        process.send(started, Nil)
        process.spawn(fn() { process.sleep(60_000) })
      },
      cancel_interaction: fn(pid) { process.kill(pid) },
      stop_server: fn(_resource) { Nil },
    )

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      "./workspaces/test",
      config,
      process.new_subject(),
      deps,
      1000,
    )

  let req = test_request(profile.meta.id, instance_id, "cap")

  let done = process.new_subject()

  let _ =
    process.spawn(fn() {
      let out = agent.interact(agent_ref, req, option.None, 1000)
      process.send(done, out)
    })

  let assert Ok(_) = process.receive(started, 1000)

  let assert Ok(types_agent.AgentStatusView(mode: mode, ..)) =
    agent.status(agent_ref, 1000)

  mode |> should.equal(types_agent.RunBusy)

  agent.stop_instance(agent_ref, agent.UserRequested)
  let assert Ok(_) = process.receive(done, 1000)
}

pub fn interact_while_busy_rejected() {
  let started = process.new_subject()
  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())

  let config =
    types_config.default_sad_config()
    |> agent_helpers.with_call_timeout_ms(5000)

  let assert Ok(instance_id) = types_core.instance_id("inst-busy")

  let deps =
    agent.AgentDeps(
      start_interaction: fn(_agent_ref, _req, _timeout_ms, _streaming, _sink) {
        process.send(started, Nil)
        process.spawn(fn() { process.sleep(60_000) })
      },
      cancel_interaction: fn(pid) { process.kill(pid) },
      stop_server: fn(_resource) { Nil },
    )

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      "./workspaces/test",
      config,
      process.new_subject(),
      deps,
      1000,
    )

  let req1 = test_request(profile.meta.id, instance_id, "cap")
  let req2 = test_request(profile.meta.id, instance_id, "cap")

  let done = process.new_subject()
  let _ =
    process.spawn(fn() {
      let out = agent.interact(agent_ref, req1, option.None, 1000)
      process.send(done, out)
    })

  let assert Ok(_) = process.receive(started, 1000)

  let out2 = agent.interact(agent_ref, req2, option.None, 1000)

  case out2 {
    Ok(_) -> panic as "expected busy rejection"

    Error(types_output.InteractionError(kind: kind, message: message, ..)) -> {
      kind |> should.equal(types_enums.AgentError)
      message |> should.equal("interact_while_busy")
    }
  }

  let ok = test_ok_result(req1.context.trace_id)
  agent.internal_interaction_done(agent_ref, Ok(ok))

  let assert Ok(Ok(_)) = process.receive(done, 1000)
}

pub fn logs_ring_buffer_capacity() {
  let assert Ok(instance_id) = types_core.instance_id("inst-logs")
  let trace_id = types_core.trace_id("t")

  let b0 = agent.empty_log_buffer()
  let e1 =
    types_log.log_event(
      types_log.StdErr,
      "abc",
      option.Some(trace_id),
      instance_id,
    )

  let b1 = agent.add_log_event(b0, e1, 3)
  b1.total_bytes |> should.equal(3)
  b1.lines |> should.equal([e1])
}

pub fn logs_ring_buffer_drops_oldest() {
  let assert Ok(instance_id) = types_core.instance_id("inst-logs-oldest")
  let trace_id = types_core.trace_id("t")

  let e1 =
    types_log.log_event(
      types_log.StdErr,
      "aaa",
      option.Some(trace_id),
      instance_id,
    )
  let e2 =
    types_log.log_event(
      types_log.StdErr,
      "bbb",
      option.Some(trace_id),
      instance_id,
    )
  let e3 =
    types_log.log_event(
      types_log.StdErr,
      "ccc",
      option.Some(trace_id),
      instance_id,
    )

  let b0 = agent.empty_log_buffer()
  let b1 = agent.add_log_event(b0, e1, 6)
  let b2 = agent.add_log_event(b1, e2, 6)
  let b3 = agent.add_log_event(b2, e3, 6)

  b3.lines |> should.equal([e2, e3])
}

pub fn logs_ring_buffer_inserts_oversize_marker() {
  let assert Ok(instance_id) = types_core.instance_id("inst-logs-oversize")
  let trace_id = types_core.trace_id("t")

  let e1 =
    types_log.log_event(
      types_log.StdErr,
      "this message is too big",
      option.Some(trace_id),
      instance_id,
    )

  let b1 = agent.add_log_event(agent.empty_log_buffer(), e1, 4)
  let assert [types_log.LogEvent(line: line, ..)] = b1.lines
  line |> should.equal("[log dropped: too large]")
}

pub fn logs_attach_sends_history() {
  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-attach")

  let config =
    types_config.default_sad_config()
    |> agent_helpers.with_log_buffer_bytes(1024)

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      "./workspaces/test",
      config,
      process.new_subject(),
      agent.default_deps(),
      1000,
    )

  let trace_id = types_core.trace_id("t")
  let e1 =
    types_log.log_event(
      types_log.StdErr,
      "one",
      option.Some(trace_id),
      instance_id,
    )
  let e2 =
    types_log.log_event(
      types_log.StdErr,
      "two",
      option.Some(trace_id),
      instance_id,
    )

  agent.internal_ingest_log(agent_ref, e1)
  agent.internal_ingest_log(agent_ref, e2)

  let subscriber = process.new_subject()
  agent.attach_logs(agent_ref, subscriber)

  let assert Ok(r1) = process.receive(subscriber, 1000)
  let assert Ok(r2) = process.receive(subscriber, 1000)

  [r1, r2] |> should.equal([e1, e2])
}

pub fn logs_attach_preserves_metadata() {
  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-meta")

  let config =
    types_config.default_sad_config()
    |> agent_helpers.with_log_buffer_bytes(1024)

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      "./workspaces/test",
      config,
      process.new_subject(),
      agent.default_deps(),
      1000,
    )

  let trace_id = types_core.trace_id("trace-1")
  let e1 =
    types_log.log_event(
      types_log.AppLog,
      "hello",
      option.Some(trace_id),
      instance_id,
    )
  agent.internal_ingest_log(agent_ref, e1)

  let subscriber = process.new_subject()
  agent.attach_logs(agent_ref, subscriber)

  let assert Ok(types_log.LogEvent(
    trace_id: got_trace,
    instance_id: got_instance,
    source: got_source,
    line: got_line,
    ..,
  )) = process.receive(subscriber, 1000)

  got_trace |> should.equal(option.Some(trace_id))
  got_instance |> should.equal(instance_id)
  got_source |> should.equal(types_log.AppLog)
  got_line |> should.equal("hello")
}

pub fn attach_logs_takeover() {
  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-takeover")

  let config =
    types_config.default_sad_config()
    |> agent_helpers.with_log_buffer_bytes(1024)

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      "./workspaces/test",
      config,
      process.new_subject(),
      agent.default_deps(),
      1000,
    )

  let sub1 = process.new_subject()
  let sub2 = process.new_subject()

  agent.attach_logs(agent_ref, sub1)

  let e1 =
    types_log.log_event(types_log.StdErr, "one", option.None, instance_id)
  agent.internal_ingest_log(agent_ref, e1)
  let assert Ok(_) = process.receive(sub1, 1000)

  agent.attach_logs(agent_ref, sub2)

  let e2 =
    types_log.log_event(types_log.StdErr, "two", option.None, instance_id)
  agent.internal_ingest_log(agent_ref, e2)

  let assert Ok(_) = process.receive(sub2, 1000)
  process.receive(sub1, 20) |> should.equal(Error(Nil))
}

pub fn attach_logs_receives_events() {
  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-live")

  let config =
    types_config.default_sad_config()
    |> agent_helpers.with_log_buffer_bytes(1024)

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      "./workspaces/test",
      config,
      process.new_subject(),
      agent.default_deps(),
      1000,
    )

  let subscriber = process.new_subject()
  agent.attach_logs(agent_ref, subscriber)

  let e1 =
    types_log.log_event(types_log.StdErr, "one", option.None, instance_id)
  agent.internal_ingest_log(agent_ref, e1)

  let assert Ok(received) = process.receive(subscriber, 1000)
  received |> should.equal(e1)
}

pub fn interact_delegates_to_actor() {
  let started = process.new_subject()
  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-delegate")

  let config =
    types_config.default_sad_config()
    |> agent_helpers.with_call_timeout_ms(5000)

  let deps =
    agent.AgentDeps(
      start_interaction: fn(_agent_ref, _req, _timeout_ms, _streaming, _sink) {
        process.send(started, "started")
        process.spawn(fn() { process.sleep(60_000) })
      },
      cancel_interaction: fn(pid) { process.kill(pid) },
      stop_server: fn(_resource) { Nil },
    )

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      "./workspaces/test",
      config,
      process.new_subject(),
      deps,
      1000,
    )

  let req = test_request(profile.meta.id, instance_id, "cap")

  let done = process.new_subject()
  let _ =
    process.spawn(fn() {
      let out = agent.interact(agent_ref, req, option.None, 1000)
      process.send(done, out)
    })

  let assert Ok("started") = process.receive(started, 1000)

  agent.internal_interaction_done(
    agent_ref,
    Ok(test_ok_result(req.context.trace_id)),
  )
  let assert Ok(Ok(_)) = process.receive(done, 1000)
}

pub fn interact_respects_timeout() {
  let profile =
    agent_helpers.test_profile(
      types_enums.Transient,
      dict.from_list([
        #(
          "cap",
          types_profile.RunnerCapability(
            input_schema: option.None,
            description: option.None,
            streaming: False,
            limits: option.Some(
              types_profile.CapabilityLimits(call_timeout_ms: option.Some(10)),
            ),
          ),
        ),
      ]),
    )

  let config =
    types_config.default_sad_config()
    |> agent_helpers.with_call_timeout_ms(5000)

  let assert Ok(instance_id) = types_core.instance_id("inst-timeout")

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      "./workspaces/test",
      config,
      process.new_subject(),
      agent.default_deps(),
      1000,
    )

  let req = test_request(profile.meta.id, instance_id, "cap")

  let out = agent.interact(agent_ref, req, option.None, 500)

  case out {
    Ok(_) -> panic as "expected timeout"

    Error(types_output.InteractionError(kind: kind, message: message, ..)) -> {
      kind |> should.equal(types_enums.InfraError)
      message |> should.equal("timeout")
    }
  }

  let assert Ok(_) = agent.status(agent_ref, 1000)
}

pub fn killing_worker_does_not_crash_actor() {
  let started = process.new_subject()
  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-worker")

  let config =
    types_config.default_sad_config()
    |> agent_helpers.with_call_timeout_ms(5000)

  let deps =
    agent.AgentDeps(
      start_interaction: fn(_agent_ref, _req, _timeout_ms, _streaming, _sink) {
        let pid = process.spawn(fn() { process.sleep(60_000) })
        process.send(started, pid)
        pid
      },
      cancel_interaction: fn(pid) { process.kill(pid) },
      stop_server: fn(_resource) { Nil },
    )

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      "./workspaces/test",
      config,
      process.new_subject(),
      deps,
      1000,
    )

  let req = test_request(profile.meta.id, instance_id, "cap")

  let done = process.new_subject()
  let _ =
    process.spawn(fn() {
      let out = agent.interact(agent_ref, req, option.None, 1000)
      process.send(done, out)
    })

  let assert Ok(worker_pid) = process.receive(started, 1000)
  process.kill(worker_pid)

  let assert Ok(Error(types_output.InteractionError(
    message: message,
    kind: kind,
    ..,
  ))) = process.receive(done, 1000)

  kind |> should.equal(types_enums.InfraError)
  message |> should.equal("worker_down")

  let assert Ok(_) = agent.status(agent_ref, 1000)
}

pub fn timeout_does_not_crash_actor() {
  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-hard")

  let config =
    types_config.default_sad_config()
    |> agent_helpers.with_call_timeout_ms(20)

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      "./workspaces/test",
      config,
      process.new_subject(),
      agent.default_deps(),
      1000,
    )

  let req = test_request(profile.meta.id, instance_id, "cap")

  let out = agent.interact(agent_ref, req, option.None, 500)

  case out {
    Ok(_) -> panic as "expected timeout"
    Error(types_output.InteractionError(message: message, ..)) ->
      message |> should.equal("timeout")
  }

  let assert Ok(_) = agent.status(agent_ref, 1000)
}

pub fn hard_timeout_not_extended_by_output() {
  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-output")

  let config =
    types_config.default_sad_config()
    |> agent_helpers.with_call_timeout_ms(30)
    |> agent_helpers.with_log_buffer_bytes(1024)

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      "./workspaces/test",
      config,
      process.new_subject(),
      agent.default_deps(),
      1000,
    )

  let req = test_request(profile.meta.id, instance_id, "cap")

  let done = process.new_subject()
  let _ =
    process.spawn(fn() {
      let out = agent.interact(agent_ref, req, option.None, 500)
      process.send(done, out)
    })

  let trace_id = req.context.trace_id
  let e =
    types_log.log_event(
      types_log.StdErr,
      "spam",
      option.Some(trace_id),
      instance_id,
    )

  // Keep emitting logs while the hard timeout is counting down.
  agent.internal_ingest_log(agent_ref, e)
  agent.internal_ingest_log(agent_ref, e)
  agent.internal_ingest_log(agent_ref, e)

  let assert Ok(Error(types_output.InteractionError(message: message, ..))) =
    process.receive(done, 1000)

  message |> should.equal("timeout")
}

pub fn stop_instance_idempotent() {
  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-stop")

  let config = types_config.default_sad_config()

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      "./workspaces/test",
      config,
      process.new_subject(),
      agent.default_deps(),
      1000,
    )

  agent.stop_instance(agent_ref, agent.UserRequested)
  agent.stop_instance(agent_ref, agent.UserRequested)

  let assert Ok(types_agent.AgentStatusView(phase: phase, ..)) =
    agent.status(agent_ref, 1000)

  phase |> should.equal(types_agent.Stopped)
}

pub fn stop_instance_user_requested() {
  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-stop-user")

  let config = types_config.default_sad_config()

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      "./workspaces/test",
      config,
      process.new_subject(),
      agent.default_deps(),
      1000,
    )

  agent.stop_instance(agent_ref, agent.UserRequested)

  let assert Ok(types_agent.AgentStatusView(phase: phase, ..)) =
    agent.status(agent_ref, 1000)

  phase |> should.equal(types_agent.Stopped)
}

pub fn stop_instance_idle_timeout() {
  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-stop-idle")

  let config = types_config.default_sad_config()

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      "./workspaces/test",
      config,
      process.new_subject(),
      agent.default_deps(),
      1000,
    )

  agent.stop_instance(agent_ref, agent.IdleTimeout)

  let assert Ok(types_agent.AgentStatusView(phase: phase, ..)) =
    agent.status(agent_ref, 1000)

  phase |> should.equal(types_agent.Stopped)
}

pub fn stop_expected_uses_actor_stop() {
  // StopInstance keeps the actor alive (it does not kill the process).
  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-stop-expected")

  let config = types_config.default_sad_config()

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      "./workspaces/test",
      config,
      process.new_subject(),
      agent.default_deps(),
      1000,
    )

  agent.stop_instance(agent_ref, agent.UserRequested)

  let assert Ok(_) = agent.status(agent_ref, 1000)
}

pub fn terminate_node_shutting_down() {
  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("inst-term")

  let config = types_config.default_sad_config()

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      "./workspaces/test",
      config,
      process.new_subject(),
      agent.default_deps(),
      1000,
    )

  agent.terminate(agent_ref, agent.NodeShuttingDown)
  process.sleep(20)

  agent.status(agent_ref, 50)
  |> should.equal(Error(safe_call.Disconnected))
}

pub fn no_cancel_endpoint() {
  // Cancelling is only done via StopInstance/Terminate; killing the caller
  // should not cancel the in-flight operation.
  let started = process.new_subject()
  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())

  let config =
    types_config.default_sad_config()
    |> agent_helpers.with_call_timeout_ms(5000)

  let assert Ok(instance_id) = types_core.instance_id("inst-no-cancel")

  let deps =
    agent.AgentDeps(
      start_interaction: fn(_agent_ref, _req, _timeout_ms, _streaming, _sink) {
        process.send(started, Nil)
        process.spawn(fn() { process.sleep(60_000) })
      },
      cancel_interaction: fn(pid) { process.kill(pid) },
      stop_server: fn(_resource) { Nil },
    )

  let assert Ok(actor.Started(data: agent_ref, ..)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      "./workspaces/test",
      config,
      process.new_subject(),
      deps,
      1000,
    )

  let req = test_request(profile.meta.id, instance_id, "cap")

  let caller_pid =
    process.spawn(fn() {
      let _ = agent.interact(agent_ref, req, option.None, 1000)
      Nil
    })

  let assert Ok(_) = process.receive(started, 1000)
  process.kill(caller_pid)
  process.sleep(20)

  let out = agent.interact(agent_ref, req, option.None, 1000)

  case out {
    Ok(_) -> panic as "expected still busy"
    Error(types_output.InteractionError(message: message, ..)) ->
      message |> should.equal("interact_while_busy")
  }

  agent.stop_instance(agent_ref, agent.UserRequested)
}

fn test_request(
  profile_id: types_core.ProfileId,
  instance_id: types_core.InstanceId,
  capability: String,
) -> agent.AgentRequest {
  let trace_id = types_core.trace_id("trace")

  let context =
    types_input.RequestContext(trace_id: trace_id, extra: dict.new())
  let payload = types_input.PayloadChat(messages: [], extra_params: dict.new())

  agent.AgentRequest(
    profile_id: profile_id,
    instance_id: instance_id,
    capability: capability,
    inputs: payload,
    context: context,
  )
}

fn test_ok_result(
  trace_id: types_core.TraceId,
) -> types_output.InteractionResult {
  let data =
    types_output.ResponseData(content: option.Some("ok"), metadata: dict.new())
  types_output.InteractionResult(data: data, artifacts: [], trace_id: trace_id)
}
