//// Profile definitions.
////
//// Mission: describe a runnable profile: its metadata, parameters, runner
//// definition, and the interface/capabilities exposed to clients.
////
//// Responsibilities:
//// - Provide typed structures for profiles loaded from disk/git.
//// - Describe parameter sources (fixed/config/secret/init) and capabilities.
////
//// Non-responsibilities:
//// - Loading/parsing profiles from files.
//// - Resolving config/secret/init values into concrete values.
////
//// Relationships:
//// - Uses `sad/types/core` for ids and values.
//// - Uses `sad/types/runner` for runner definitions.
//// - Used by parameter resolution and API capability exposure.

import gleam/dict.{type Dict}
import gleam/option.{type Option}
import sad/types/core
import sad/types/enums
import sad/types/runner as types_runner

/// A complete profile definition.
///
/// A profile ties together parameters, runner definition, and interface.
pub type Profile {
  Profile(
    meta: ProfileMeta,
    parameters: Dict(String, Parameter),
    runner: types_runner.Runner,
    interface: Interface,
  )
}

/// Human and runtime metadata about a profile.
///
/// `id` is the stable identifier used for selection.
pub type ProfileMeta {
  ProfileMeta(
    id: core.ProfileId,
    name: Option(String),
    lifecycle: enums.Lifecycle,
    description: String,
  )
}

/// The allowed value types for profile parameters.
///
/// This is a strict subset of `core.ValueType`.
pub type ParamType {
  ParamString
  ParamInt
  ParamFloat
  ParamBool
}

/// Converts a profile `ParamType` into a `core.ValueType`.
pub fn param_type_to_value_type(param_type: ParamType) -> core.ValueType {
  case param_type {
    ParamString -> core.TypeString
    ParamInt -> core.TypeInt
    ParamFloat -> core.TypeFloat
    ParamBool -> core.TypeBool
  }
}

/// Definition of a profile parameter.
///
/// - `FixedParam`: hard-coded value.
/// - `ConfigParam`: read from runtime config by `key`.
/// - `SecretParam`: read from runtime config and treated as secret.
/// - `InitParam`: evaluated/derived during initialization.
pub type Parameter {
  FixedParam(value: core.Value)
  ConfigParam(
    key: String,
    default: Option(core.Value),
    expected_type: ParamType,
  )
  SecretParam(key: String, expected_type: ParamType)
  InitParam(key: String, default: Option(core.Value), expected_type: ParamType)
}

/// Declares what input shape a capability expects.
pub type InputSchema {
  SchemaChat
  SchemaFiles
  SchemaChatExtended(extra_fields: Dict(String, ExtraFieldDef))
}

/// Definition of an extra field accepted in `SchemaChatExtended`.
pub type ExtraFieldDef {
  ExtraFieldDef(
    type_: ExtraFieldType,
    enum_values: Option(List(String)),
    default: Option(core.Value),
  )
}

/// Scalar types available for extra fields.
pub type ExtraFieldType {
  FieldString
  FieldBoolean
  FieldNumber
  FieldInteger
}

/// Optional per-capability limits.
///
/// When absent, server defaults apply.
pub type CapabilityLimits {
  CapabilityLimits(call_timeout_ms: Option(Int))
}

/// A capability provided by a runner interface.
///
/// This is used when the interface is runner-native rather than HTTP.
pub type RunnerCapability {
  RunnerCapability(
    input_schema: Option(InputSchema),
    description: Option(String),
    streaming: Bool,
    limits: Option(CapabilityLimits),
  )
}

/// Mapping of response fields for HTTP capabilities.
///
/// JSON pointers can be used to locate text and artifacts in a response body.
pub type ResponseMapping {
  /// Use the default mapping behavior.
  Default
  /// Resolve text from a JSON pointer.
  Text(String)
  /// Resolve artifacts from a JSON pointer.
  Artifacts(String)
  /// Resolve both text and artifacts from JSON pointers.
  Both(String, String)
}

/// A single HTTP-exposed capability.
///
/// `path` and `method` identify the endpoint; `response` can optionally map
/// response fields.
pub type HttpCapability {
  HttpCapability(
    path: String,
    method: HttpMethod,
    input_schema: Option(InputSchema),
    response: Option(ResponseMapping),
    description: Option(String),
    streaming: Bool,
    limits: Option(CapabilityLimits),
  )
}

/// Health check configuration for an HTTP interface.
pub type HealthCheck {
  HealthCheck(path: String, method: HttpMethod, expect_statuses: List(Int))
}

/// Supported HTTP methods for capability definitions.
pub type HttpMethod {
  HttpGet
  HttpPost
  HttpPut
  HttpDelete
}

/// How the profile is invoked.
///
/// - `HttpInterface`: invoke via HTTP endpoints.
/// - `RunnerInterface`: invoke via runner-native capabilities.
pub type Interface {
  HttpInterface(
    base_url: String,
    headers: Dict(String, String),
    health_check: Option(HealthCheck),
    capabilities: Dict(String, HttpCapability),
  )
  RunnerInterface(capabilities: Dict(String, RunnerCapability))
}
