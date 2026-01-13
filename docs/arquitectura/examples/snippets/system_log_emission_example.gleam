// En init_state(), tras crear el estado:
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

// En el worker de provisioning (spawn en initialiser):
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

// ... outcome = runner.provision_and_start(ctx, agent_ref)  // (dentro del Bridge por defecto)

// En start_interaction():
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

// En finalize_interaction() con resultado exitoso:
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
