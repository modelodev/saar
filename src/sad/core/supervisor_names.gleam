////
//// Mission: define process names used by the SAD core OTP tree.
////
//// Responsibilities:
//// - Create all `process.Name` values exactly once at startup.
//// - Provide a single container (`RootNames`) to pass through bootstrap.
////
//// Non-responsibilities:
//// - Starting any processes.
//// - Providing runtime configuration.
////
//// Relationships:
//// - Consumed by `sad/core/root_supervisor.start`.

import gleam/erlang/process
import gleam/otp/factory_supervisor
import sad/core/agent
import sad/core/artifact_registry_protocol
import sad/core/messages
import youid/uuid

/// Process names required to boot the core OTP tree.
///
/// IMPORTANT: `process.new_name` allocates atoms. Call `new_names` only once at
/// startup.
pub type RootNames {
  RootNames(
    registry: process.Name(messages.RegistryMsg),
    artifact_registry: process.Name(
      artifact_registry_protocol.ArtifactRegistryMsg,
    ),
    port_pool: process.Name(messages.PortPoolMsg),
    profiles: process.Name(messages.ProfilesMsg),
    agent_manager: process.Name(messages.AgentManagerMsg),
    agent_factory: process.Name(
      factory_supervisor.Message(messages.StartArgs, agent.AgentRef),
    ),
  )
}

pub fn new_names() -> RootNames {
  RootNames(
    registry: process.new_name("sad_registry"),
    artifact_registry: process.new_name("sad_artifact_registry"),
    port_pool: process.new_name("sad_port_pool"),
    profiles: process.new_name("sad_profiles"),
    agent_manager: process.new_name("sad_agent_manager"),
    agent_factory: process.new_name("sad_agent_factory"),
  )
}

/// Creates a set of unique process names.
///
/// This is intended for tests that start multiple SAD instances in the same BEAM
/// node. The suffix is appended to each name.
///
/// IMPORTANT: `process.new_name` allocates atoms. Use with care.
pub fn new_names_with_suffix(suffix: String) -> RootNames {
  let unique = suffix <> "_" <> uuid.v7_string()

  RootNames(
    registry: process.new_name("sad_registry_" <> unique),
    artifact_registry: process.new_name("sad_artifact_registry_" <> unique),
    port_pool: process.new_name("sad_port_pool_" <> unique),
    profiles: process.new_name("sad_profiles_" <> unique),
    agent_manager: process.new_name("sad_agent_manager_" <> unique),
    agent_factory: process.new_name("sad_agent_factory_" <> unique),
  )
}
