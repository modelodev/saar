//// Example snippet showing where system logs are emitted.
////
//// This module is documentation-only. It is meant to be formatted by `gleam format`.
//// It is not used by the application at runtime.

pub fn example() {
  // In init_state(), after creating the state:
  let profile = todo
  let instance_id = todo

  let _ =
    system_log(
      AgentStarted,
      dict.from_list([
        #("profile", profile_id_to_string(profile.meta.id)),
        #("lifecycle", lifecycle_to_string(profile.meta.lifecycle)),
      ]),
      None,
      instance_id,
    )

  // In the provisioning worker (spawned in the initialiser):
  let agent_ref = todo
  let start_ms = now_ms()

  let _ =
    agent.internal_ingest_log(
      agent_ref,
      system_log(
        ProvisioningStarted,
        dict.from_list([#("profile", profile_id_to_string(profile.meta.id))]),
        None,
        instance_id,
      ),
    )

  // ... outcome = runner.provision_and_start(ctx, agent_ref) (inside the default Bridge)

  // In start_interaction():
  let state = todo
  let req = todo

  let _ =
    system_log(
      InteractionStarted,
      dict.from_list([
        #("profile", profile_id_to_string(state.profile.meta.id)),
        #("capability", req.capability),
      ]),
      Some(req.trace_id),
      state.instance_id,
    )

  // In finalize_interaction() with a successful outcome:
  let in_flight = todo
  let interaction_start_time = todo
  let duration_ms = now_ms() - interaction_start_time

  let _ =
    system_log(
      InteractionFinished,
      dict.from_list([
        #("profile", profile_id_to_string(state.profile.meta.id)),
        #("capability", in_flight.request.capability),
        #("duration_ms", int.to_string(duration_ms)),
      ]),
      Some(in_flight.request.trace_id),
      state.instance_id,
    )

  let _ = start_ms
}
