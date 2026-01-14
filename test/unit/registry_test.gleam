import agent_helpers
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import gleeunit
import gleeunit/should
import sad/core/agent
import sad/otp/safe_call
import sad/core/messages
import sad/core/registry
import sad/types/agent as types_agent
import sad/types/core as types_core
import sad/types/enums as types_enums

pub fn main() {
  gleeunit.main()
}

pub fn register_new_instance() {
  let registry = start_registry()

  let profile_id = types_core.profile_id("p1")
  let assert Ok(instance_id) = types_core.instance_id("inst-1")

  let #(agent_ref, pid) = start_test_agent_ref()

  let status = status_view(profile_id, instance_id)

  register(registry, status, agent_ref)
  |> should.equal(Ok(Nil))

  let assert Ok(option.Some(found)) =
    lookup_by_ids(registry, profile_id, instance_id, 1000)

  let found_pid = agent.pid(found)
  found_pid |> should.equal(pid)
}

pub fn register_duplicate_fails() {
  let registry = start_registry()

  let profile_id = types_core.profile_id("p1")
  let assert Ok(instance_id) = types_core.instance_id("inst-dup")

  let #(agent1, _) = start_test_agent_ref()
  let #(agent2, _) = start_test_agent_ref()

  let status = status_view(profile_id, instance_id)

  let assert Ok(_) = register(registry, status, agent1)

  register(registry, status, agent2)
  |> should.equal(Error(safe_call.ActorError(messages.AlreadyExists)))
}

pub fn register_duplicate_instance_id_fails() {
  let registry = start_registry()

  let profile1 = types_core.profile_id("p1")
  let profile2 = types_core.profile_id("p2")
  let assert Ok(instance_id) = types_core.instance_id("inst-global")

  let #(agent1, _) = start_test_agent_ref()
  let #(agent2, _) = start_test_agent_ref()

  let assert Ok(_) =
    register(registry, status_view(profile1, instance_id), agent1)

  register(registry, status_view(profile2, instance_id), agent2)
  |> should.equal(Error(safe_call.ActorError(messages.AlreadyExists)))
}

pub fn register_is_atomic_for_uniqueness() {
  let registry = start_registry()

  let profile_id = types_core.profile_id("p1")
  let assert Ok(instance_id) = types_core.instance_id("inst-atomic")
  let status = status_view(profile_id, instance_id)

  let #(agent1, _) = start_test_agent_ref()
  let #(agent2, _) = start_test_agent_ref()

  let results = process.new_subject()

  let _ =
    process.spawn(fn() {
      let result = register(registry, status, agent1)
      process.send(results, result)
    })

  let _ =
    process.spawn(fn() {
      let result = register(registry, status, agent2)
      process.send(results, result)
    })

  let assert Ok(r1) = process.receive(results, 1000)
  let assert Ok(r2) = process.receive(results, 1000)

  let ok_count =
    [r1, r2]
    |> list.filter(fn(r) { r == Ok(Nil) })
    |> list.length

  ok_count |> should.equal(1)
}

pub fn unregister_removes() {
  let registry = start_registry()

  let profile_id = types_core.profile_id("p1")
  let assert Ok(instance_id) = types_core.instance_id("inst-unreg")
  let #(agent_ref, _) = start_test_agent_ref()

  let status = status_view(profile_id, instance_id)
  let assert Ok(_) = register(registry, status, agent_ref)

  let key = messages.InstanceKey(profile_id, instance_id)
  unregister(registry, key)

  lookup(registry, key, 1000)
  |> should.equal(Ok(option.None))
}

pub fn list_by_profile_filters() {
  let registry = start_registry()

  let p1 = types_core.profile_id("p1")
  let p2 = types_core.profile_id("p2")

  let assert Ok(i1) = types_core.instance_id("inst-a")
  let assert Ok(i2) = types_core.instance_id("inst-b")

  let #(a1, _) = start_test_agent_ref()
  let #(a2, _) = start_test_agent_ref()

  let assert Ok(_) = register(registry, status_view(p1, i1), a1)
  let assert Ok(_) = register(registry, status_view(p2, i2), a2)

  let assert Ok(found) = list_by_profile(registry, p1, 1000)

  found
  |> list.map(types_core.instance_id_to_string)
  |> should.equal([types_core.instance_id_to_string(i1)])
}

pub fn lookup_by_ids_uses_key() {
  let registry = start_registry()

  let profile_id = types_core.profile_id("p1")
  let assert Ok(instance_id) = types_core.instance_id("inst-key")

  let #(agent_ref, _) = start_test_agent_ref()
  let status = status_view(profile_id, instance_id)
  let assert Ok(_) = register(registry, status, agent_ref)

  let key = messages.InstanceKey(profile_id, instance_id)

  let a = lookup(registry, key, 1000)
  let b = lookup_by_ids(registry, profile_id, instance_id, 1000)

  a |> should.equal(b)
}

pub fn lookup_by_instance_id_returns_ref() {
  let registry = start_registry()

  let profile_id = types_core.profile_id("p1")
  let assert Ok(instance_id) = types_core.instance_id("inst-direct")

  let #(agent_ref, pid) = start_test_agent_ref()
  let assert Ok(_) =
    register(registry, status_view(profile_id, instance_id), agent_ref)

  let assert Ok(option.Some(found)) =
    lookup_by_instance_id(registry, instance_id, 1000)

  let found_pid = agent.pid(found)
  found_pid |> should.equal(pid)
}

pub fn agent_down_removes_entry() {
  let registry = start_registry()

  let profile_id = types_core.profile_id("p1")
  let assert Ok(instance_id) = types_core.instance_id("inst-down")

  let #(agent_ref, pid) = start_test_agent_ref()
  let assert Ok(_) =
    register(registry, status_view(profile_id, instance_id), agent_ref)

  process.kill(pid)

  wait_lookup_by_instance_id_none(registry, instance_id, 50)
}

pub fn agent_down_removes_instance_id_index() {
  let registry = start_registry()

  let profile_id = types_core.profile_id("p1")
  let assert Ok(instance_id) = types_core.instance_id("inst-down-reuse")

  let status = status_view(profile_id, instance_id)

  let #(agent_ref, pid) = start_test_agent_ref()
  let assert Ok(_) = register(registry, status, agent_ref)

  process.kill(pid)

  wait_lookup_by_instance_id_none(registry, instance_id, 50)

  // Once the old entry is removed, re-registering must succeed.
  let #(agent_ref2, _) = start_test_agent_ref()
  register(registry, status, agent_ref2) |> should.equal(Ok(Nil))
}

pub fn monitor_established_on_register() {
  let registry = start_registry()

  let profile_id = types_core.profile_id("p1")
  let assert Ok(instance_id) = types_core.instance_id("inst-monitor")

  let #(agent_ref, pid) = start_test_agent_ref()
  let assert Ok(_) =
    register(registry, status_view(profile_id, instance_id), agent_ref)

  process.kill(pid)

  let key = messages.InstanceKey(profile_id, instance_id)
  wait_lookup_none(registry, key, 50)
}

fn wait_lookup_by_instance_id_none(
  registry: process.Subject(messages.RegistryMsg),
  instance_id: types_core.InstanceId,
  attempts: Int,
) -> Nil {
  case attempts {
    0 -> panic as "Timed out waiting for instance_id index removal"

    _ ->
      case lookup_by_instance_id(registry, instance_id, 1000) {
        Ok(option.None) -> Nil

        _ -> {
          process.sleep(10)
          wait_lookup_by_instance_id_none(registry, instance_id, attempts - 1)
        }
      }
  }
}

fn wait_lookup_none(
  registry: process.Subject(messages.RegistryMsg),
  key: messages.InstanceKey,
  attempts: Int,
) -> Nil {
  case attempts {
    0 -> panic as "Timed out waiting for registry removal"

    _ ->
      case lookup(registry, key, 1000) {
        Ok(option.None) -> Nil

        _ -> {
          process.sleep(10)
          wait_lookup_none(registry, key, attempts - 1)
        }
      }
  }
}

fn register(
  registry: process.Subject(messages.RegistryMsg),
  status: types_agent.AgentStatusView,
  agent_ref: agent.AgentRef,
) -> Result(Nil, safe_call.ApiCallError(messages.RegistryError)) {
  safe_call.call_unwrap_result(registry, 1000, fn(reply_to) {
    messages.Register(status, agent_ref, reply_to)
  })
}

fn lookup(
  registry: process.Subject(messages.RegistryMsg),
  key: messages.InstanceKey,
  timeout_ms: Int,
) -> Result(option.Option(agent.AgentRef), safe_call.CallError) {
  safe_call.call(registry, timeout_ms, fn(reply_to) {
    messages.Lookup(key, reply_to)
  })
}

fn lookup_by_ids(
  registry: process.Subject(messages.RegistryMsg),
  profile_id: types_core.ProfileId,
  instance_id: types_core.InstanceId,
  timeout_ms: Int,
) -> Result(option.Option(agent.AgentRef), safe_call.CallError) {
  lookup(registry, messages.InstanceKey(profile_id, instance_id), timeout_ms)
}

fn lookup_by_instance_id(
  registry: process.Subject(messages.RegistryMsg),
  instance_id: types_core.InstanceId,
  timeout_ms: Int,
) -> Result(option.Option(agent.AgentRef), safe_call.CallError) {
  safe_call.call(registry, timeout_ms, fn(reply_to) {
    messages.LookupByInstanceId(instance_id, reply_to)
  })
}

fn list_by_profile(
  registry: process.Subject(messages.RegistryMsg),
  profile_id: types_core.ProfileId,
  timeout_ms: Int,
) -> Result(List(types_core.InstanceId), safe_call.CallError) {
  safe_call.call(registry, timeout_ms, fn(reply_to) {
    messages.ListByProfile(profile_id, reply_to)
  })
}

fn unregister(
  registry: process.Subject(messages.RegistryMsg),
  key: messages.InstanceKey,
) -> Nil {
  process.send(registry, messages.Unregister(key))
}

fn start_registry() -> process.Subject(messages.RegistryMsg) {
  let name = process.new_name("test_registry")
  let assert Ok(actor.Started(data: subject, ..)) = registry.start(name)
  subject
}

fn start_test_agent_ref() -> #(agent.AgentRef, process.Pid) {
  let profile = agent_helpers.test_profile(types_enums.Transient, dict.new())
  let assert Ok(instance_id) = types_core.instance_id("test-agent")

  let assert Ok(actor.Started(data: agent_ref, pid: pid)) =
    agent.start_link(
      profile,
      instance_id,
      dict.new(),
      agent_helpers.workspace_root(),
      agent_helpers.default_config(),
      process.new_subject(),
      agent.default_deps(),
      1000,
    )

  #(agent_ref, pid)
}

fn status_view(
  profile_id: types_core.ProfileId,
  instance_id: types_core.InstanceId,
) -> types_agent.AgentStatusView {
  types_agent.AgentStatusView(
    profile_id: profile_id,
    instance_id: instance_id,
    lifecycle: types_enums.Transient,
    phase: types_agent.Created,
    mode: types_agent.RunIdle,
    assigned_port: option.None,
  )
}
