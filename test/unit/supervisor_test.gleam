import gleam/dict
import gleam/erlang/process
import gleam/otp/actor
import gleeunit
import gleeunit/should
import sad/app_state
import sad/core/root_supervisor
import sad/core/supervisor_names
import sad/types/config as types_config

pub fn main() {
  gleeunit.main()
}

pub fn start_initializes_supervisors() {
  let #(ref, names, _pid) = start_root(types_config.default_sad_config())

  let supervisor_names.RootNames(
    registry_name,
    artifact_registry_name,
    port_pool_name,
    profiles_name,
    agent_manager_name,
    agent_factory_name,
  ) = names

  let assert Ok(_) = process.subject_owner(process.named_subject(registry_name))
  let assert Ok(_) =
    process.subject_owner(process.named_subject(artifact_registry_name))
  let assert Ok(_) =
    process.subject_owner(process.named_subject(port_pool_name))
  let assert Ok(_) = process.subject_owner(process.named_subject(profiles_name))
  let assert Ok(_) =
    process.subject_owner(process.named_subject(agent_manager_name))

  let assert Ok(_) =
    process.subject_owner(process.named_subject(agent_factory_name))

  // Accessors return named subjects.
  let assert Ok(registry_returned_name) =
    process.subject_name(root_supervisor.registry(ref))
  registry_returned_name |> should.equal(registry_name)
}

pub fn deps_discovered_by_name_not_passed_by_hand() {
  let #(ref, names, _pid) = start_root(types_config.default_sad_config())

  let supervisor_names.RootNames(
    registry_name,
    artifact_registry_name,
    port_pool_name,
    profiles_name,
    agent_manager_name,
    _agent_factory_name,
  ) = names

  process.subject_name(root_supervisor.registry(ref))
  |> should.equal(Ok(registry_name))

  process.subject_name(root_supervisor.artifact_registry(ref))
  |> should.equal(Ok(artifact_registry_name))

  process.subject_name(root_supervisor.port_pool(ref))
  |> should.equal(Ok(port_pool_name))

  process.subject_name(root_supervisor.profiles(ref))
  |> should.equal(Ok(profiles_name))

  process.subject_name(root_supervisor.agent_manager(ref))
  |> should.equal(Ok(agent_manager_name))
}

pub fn root_supervisor_start_fail_fast() {
  let cfg0 = types_config.default_sad_config()
  let types_config.SadConfig(runner: runner0, ..) = cfg0
  let types_config.RunnerSystemConfig(..) = runner0

  // Invalid range: min > max.
  let bad_runner =
    types_config.RunnerSystemConfig(
      ..runner0,
      port_range_min: 10,
      port_range_max: 0,
    )

  let cfg = types_config.SadConfig(..cfg0, runner: bad_runner)

  let names = supervisor_names.new_names()
  let state = app_state.AppState(config: cfg, initial_profiles: dict.new())

  case root_supervisor.start(state, names) {
    Ok(_) -> panic as "Expected root supervisor start to fail"
    Error(_) -> Nil
  }
}

pub fn root_supervisor_rest_for_one_order() {
  let cfg = types_config.default_sad_config()
  let names = supervisor_names.new_names()
  let state = app_state.AppState(config: cfg, initial_profiles: dict.new())

  let assert Ok(actor.Started(data: _ref, ..)) =
    root_supervisor.start(state, names)

  let supervisor_names.RootNames(
    registry_name,
    artifact_registry_name,
    _port_pool_name,
    profiles_name,
    _agent_manager_name,
    _agent_factory_name,
  ) = names

  let registry_subject = process.named_subject(registry_name)
  let artifact_subject = process.named_subject(artifact_registry_name)
  let profiles_subject = process.named_subject(profiles_name)

  let assert Ok(registry_pid_before) = process.subject_owner(registry_subject)
  let assert Ok(profiles_pid_before) = process.subject_owner(profiles_subject)

  // Crash the second child; Registry (first) must remain, later children restart.
  let assert Ok(artifact_pid_before) = process.subject_owner(artifact_subject)
  process.kill(artifact_pid_before)
  process.sleep(50)

  let assert Ok(registry_pid_after) = process.subject_owner(registry_subject)
  let assert Ok(profiles_pid_after) = process.subject_owner(profiles_subject)

  registry_pid_after |> should.equal(registry_pid_before)
  profiles_pid_after |> should.not_equal(profiles_pid_before)
}

pub fn root_supervisor_restart_tolerance() {
  let cfg = types_config.default_sad_config()
  let names = supervisor_names.new_names()
  let state = app_state.AppState(config: cfg, initial_profiles: dict.new())

  let assert Ok(actor.Started(pid: sup_pid, ..)) =
    root_supervisor.start(state, names)

  let supervisor_names.RootNames(
    _registry_name,
    _artifact_registry_name,
    _port_pool_name,
    _profiles_name,
    agent_manager_name,
    _agent_factory_name,
  ) = names

  let monitor = process.monitor(sup_pid)

  // Each crash of AgentManager (RestForOne) restarts itself plus later children.
  crash_named_process(agent_manager_name, 3)

  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })

  let assert Ok(process.ProcessDown(..)) =
    process.selector_receive(selector, 2000)
  Nil
}

fn start_root(
  config: types_config.SadConfig,
) -> #(root_supervisor.SupervisorRef, supervisor_names.RootNames, process.Pid) {
  let names = supervisor_names.new_names()
  let state = app_state.AppState(config: config, initial_profiles: dict.new())

  let assert Ok(actor.Started(pid: pid, data: ref)) =
    root_supervisor.start(state, names)
  #(ref, names, pid)
}

fn crash_named_process(name: process.Name(msg), times: Int) -> Nil {
  case times {
    0 -> Nil
    _ -> {
      let pid = process.named_subject(name) |> process.subject_owner
      let assert Ok(owner) = pid
      process.kill(owner)
      process.sleep(20)
      crash_named_process(name, times - 1)
    }
  }
}
