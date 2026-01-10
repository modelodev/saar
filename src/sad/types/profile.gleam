import gleam/dict.{type Dict}
import gleam/option.{type Option}
import sad/types/core
import sad/types/enums
import sad/types/runner as types_runner

pub type Profile {
  Profile(
    meta: ProfileMeta,
    parameters: Dict(String, Parameter),
    runner: types_runner.Runner,
    interface: Interface,
  )
}

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

pub type InputSchema {
  SchemaChat
  SchemaFiles
  SchemaChatExtended(extra_fields: Dict(String, ExtraFieldDef))
}

pub type ExtraFieldDef {
  ExtraFieldDef(
    type_: ExtraFieldType,
    enum_values: Option(List(String)),
    default: Option(core.Value),
  )
}

pub type ExtraFieldType {
  FieldString
  FieldBoolean
  FieldNumber
  FieldInteger
}

pub type CapabilityLimits {
  CapabilityLimits(call_timeout_ms: Option(Int))
}

pub type RunnerCapability {
  RunnerCapability(
    input_schema: Option(InputSchema),
    description: Option(String),
    streaming: Bool,
    limits: Option(CapabilityLimits),
  )
}

pub type ResponseMapping {
  ResponseMapping(
    text_pointer: Option(String),
    artifacts_pointer: Option(String),
  )
}

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

pub type HealthCheck {
  HealthCheck(path: String, method: HttpMethod, expect_statuses: List(Int))
}

pub type HttpMethod {
  HttpGet
  HttpPost
  HttpPut
  HttpDelete
}

pub type Interface {
  HttpInterface(
    base_url: String,
    headers: Dict(String, String),
    health_check: Option(HealthCheck),
    capabilities: Dict(String, HttpCapability),
  )
  RunnerInterface(capabilities: Dict(String, RunnerCapability))
}
