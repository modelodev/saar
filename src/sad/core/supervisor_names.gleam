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
import sad/core/messages

/// Process names required to boot the core OTP tree.
///
/// IMPORTANT: `process.new_name` allocates atoms. Call `new_names` only once at
/// startup.
pub type RootNames {
  RootNames(
    registry: process.Name(messages.RegistryMsg),
    artifact_registry: process.Name(messages.ArtifactRegistryMsg),
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
