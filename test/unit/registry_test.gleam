import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import gleeunit
import gleeunit/should
import sad/core/agent
import sad/core/messages
import sad/core/registry
import sad/core/registry_api
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

  registry_api.register(registry, status, agent_ref, 1000)
  |> should.equal(Ok(Nil))

  let assert Ok(option.Some(found)) =
    registry_api.lookup_by_ids(registry, profile_id, instance_id, 1000)

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

  let assert Ok(_) = registry_api.register(registry, status, agent1, 1000)

  registry_api.register(registry, status, agent2, 1000)
  |> should.equal(Error(registry_api.ActorError(messages.AlreadyExists)))
}

pub fn register_duplicate_instance_id_fails() {
  let registry = start_registry()

  let profile1 = types_core.profile_id("p1")
  let profile2 = types_core.profile_id("p2")
  let assert Ok(instance_id) = types_core.instance_id("inst-global")

  let #(agent1, _) = start_test_agent_ref()
  let #(agent2, _) = start_test_agent_ref()

  let assert Ok(_) =
    registry_api.register(
      registry,
      status_view(profile1, instance_id),
      agent1,
      1000,
    )

  registry_api.register(
    registry,
    status_view(profile2, instance_id),
    agent2,
    1000,
  )
  |> should.equal(Error(registry_api.ActorError(messages.AlreadyExists)))
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
      let result = registry_api.register(registry, status, agent1, 1000)
      process.send(results, result)
    })

  let _ =
    process.spawn(fn() {
      let result = registry_api.register(registry, status, agent2, 1000)
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
  let assert Ok(_) = registry_api.register(registry, status, agent_ref, 1000)

  let key = messages.InstanceKey(profile_id, instance_id)
  registry_api.unregister(registry, key)

  registry_api.lookup(registry, key, 1000)
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

  let assert Ok(_) =
    registry_api.register(registry, status_view(p1, i1), a1, 1000)
  let assert Ok(_) =
    registry_api.register(registry, status_view(p2, i2), a2, 1000)

  let assert Ok(found) = registry_api.list_by_profile(registry, p1, 1000)

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
  let assert Ok(_) = registry_api.register(registry, status, agent_ref, 1000)

  let key = messages.InstanceKey(profile_id, instance_id)

  let a = registry_api.lookup(registry, key, 1000)
  let b = registry_api.lookup_by_ids(registry, profile_id, instance_id, 1000)

  a |> should.equal(b)
}

pub fn lookup_by_instance_id_returns_ref() {
  let registry = start_registry()

  let profile_id = types_core.profile_id("p1")
  let assert Ok(instance_id) = types_core.instance_id("inst-direct")

  let #(agent_ref, pid) = start_test_agent_ref()
  let assert Ok(_) =
    registry_api.register(
      registry,
      status_view(profile_id, instance_id),
      agent_ref,
      1000,
    )

  let assert Ok(option.Some(found)) =
    registry_api.lookup_by_instance_id(registry, instance_id, 1000)

  let found_pid = agent.pid(found)
  found_pid |> should.equal(pid)
}

pub fn agent_down_removes_entry() {
  let registry = start_registry()

  let profile_id = types_core.profile_id("p1")
  let assert Ok(instance_id) = types_core.instance_id("inst-down")

  let #(agent_ref, pid) = start_test_agent_ref()
  let assert Ok(_) =
    registry_api.register(
      registry,
      status_view(profile_id, instance_id),
      agent_ref,
      1000,
    )

  process.kill(pid)
  process.sleep(20)

  registry_api.lookup_by_instance_id(registry, instance_id, 1000)
  |> should.equal(Ok(option.None))
}

pub fn agent_down_removes_instance_id_index() {
  agent_down_removes_entry()
}

pub fn monitor_established_on_register() {
  agent_down_removes_entry()
}

fn start_registry() -> process.Subject(messages.RegistryMsg) {
  let name = process.new_name("test_registry")
  let assert Ok(actor.Started(data: subject, ..)) = registry.start(name)
  subject
}

fn start_test_agent_ref() -> #(agent.AgentRef, process.Pid) {
  let pid = process.spawn_unlinked(fn() { process.sleep(10_000) })
  #(agent.unsafe_from_pid(pid), pid)
}

fn status_view(
  profile_id: types_core.ProfileId,
  instance_id: types_core.InstanceId,
) -> types_agent.AgentStatusView {
  types_agent.AgentStatusView(
    profile_id: profile_id,
    instance_id: instance_id,
    lifecycle: types_enums.Transient,
    phase: types_agent.Provisioning,
    mode: types_agent.RunIdle,
    assigned_port: option.None,
    failure_reason: option.None,
  )
}
