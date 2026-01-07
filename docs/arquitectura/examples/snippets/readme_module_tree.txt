src/
├── sad.gleam                 # Entrypoint
└── sad/
    ├── sys.gleam             # Orquestación: cargar perfiles, resolver params, arrancar OTP
    ├── types.gleam           # Dominio + wire (IDs/payloads/errores/config; sin OTP)
    ├── workspace.gleam       # WorkspacePath + validación/normalización segura
    ├── params.gleam          # Resolución de parámetros (config/env/init)
    ├── decoders.gleam        # JSON → tipos (config/perfiles/wire)
    ├── runner_contract.gleam # Tipos wire del runner (eventos JSONL)
    ├── response_mapping.gleam# JSON pointers para mapear respuestas a `ResponseData`
	├── sse.gleam             # Helpers SSE: `line`, `comment`, `named_event`
	├── otp/
	│   └── safe_call.gleam    # Safe-call (reply+monitor) para bordes HTTP/SSE (no panic)
	├── streams/
	│   └── sink.gleam        # `StreamSink` (solo interacción SSE por request): `push_batch` + `finish`
    │
    ├── core/
    │   ├── messages.gleam    # Mensajes OTP internos (`AgentMsg`, `RegistryMsg`, ...)
    │   ├── agent.gleam       # AgentActor + API pública (`AgentRef`)
    │   ├── agent_internal.gleam # API interna (bridge → actor): eventos internos
    │   ├── registry.gleam    # RegistryActor (InstanceKey → AgentRef)
    │   ├── registry_api.gleam# API pública del registry
	    │   ├── artifact_registry.gleam     # Registro de artefactos (SSOT)
	    │   ├── artifact_registry_api.gleam # API de artefactos (register/lookup/purge)
	    │   ├── port_pool.gleam   # Helper puro (allocate/release)
	    │   ├── port_pool_actor.gleam # SSOT de reservas de puertos (OTP; si managed_port)
	    │   ├── port_pool_api.gleam  # API tipada del port pool (allocate/release)
	    │   ├── profiles.gleam    # SSOT de perfiles en memoria (reload sin reinicio)
	    │   ├── profiles_api.gleam# API tipada para ProfilesActor
	    │   └── agent_manager.gleam # Manager de instancias (OTP)
	    │
    ├── adapters/
    │   ├── agui.gleam        # Adapter AG-UI
	    │   └── a2a.gleam         # Adapter A2A
    │   └── a2ui.gleam        # Adapter A2UI (aware; nativo y extensión A2A)
    │
    ├── bridge/
    │   ├── bridge.gleam        # Fachada inyectable (Bridge record) para core
    │   ├── port_process.gleam  # Frontera con ports + framing STDOUT JSONL
    │   ├── runner.gleam        # Ejecuta runners + interpreta contrato (stdout JSONL)
    │   ├── client.gleam        # HTTP para continuous
    │   ├── serialization.gleam # Tipos → JSON wire
    │   └── interpolator.gleam  # Templates
    │
		└── gateway/
		    ├── api.gleam         # Endpoints HTTP (sys + nativo + A2A)
		    ├── problem.gleam     # RFC7807 (Problem Details): dominio → Problem → HTTP response
		    ├── proxy.gleam       # /artifacts
		    └── ui_proxy.gleam    # /agents/:instance_id/ui/* (proxy UI HTTP-only)
