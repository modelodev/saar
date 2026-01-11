//// Core domain primitives.
////
//// Mission: define small, shared types used across SAD (ids, values, and
//// secrets) with lightweight helpers for parsing and rendering.
////
//// Responsibilities:
//// - Provide strongly-typed IDs (`ProfileId`, `InstanceId`, `TraceId`).
//// - Provide value representations used in parameters and payloads.
//// - Provide secret handling utilities (redaction and env rendering).
////
//// Non-responsibilities:
//// - JSON encoding/decoding of domain values.
//// - Persistence or storage concerns.
////
//// Relationships:
//// - Used by most `sad/types/*` modules.
//// - Secret redaction is centralized here via `secret_inspect`.

import gleam/float
import gleam/int
import gleam/list
import gleam/string

/// Identifier of a loaded profile.
///
/// This is opaque to prevent accidental mixing with other ids.
pub opaque type ProfileId {
  ProfileId(String)
}

/// Identifier of a running instance.
///
/// This id is validated by `instance_id` and is restricted to
/// alphanumerics plus `-` and `_`.
pub opaque type InstanceId {
  InstanceId(String)
}

/// Errors produced when validating an `InstanceId`.
pub type InstanceIdError {
  EmptyInstanceId
  InstanceIdTooLong(max: Int)
  InstanceIdInvalidChar(char: String)
}

/// Identifier used to correlate logs, requests, and responses.
///
/// This is typically propagated end-to-end in server responses.
pub opaque type TraceId {
  TraceId(String)
}

/// Wraps a string as a `ProfileId`.
///
/// Example:
/// ```gleam
/// import sad/types/core
///
/// let id = core.profile_id("default")
/// ```
pub fn profile_id(s: String) -> ProfileId {
  ProfileId(s)
}

/// Unwraps a `ProfileId` into its string representation.
pub fn profile_id_to_string(id: ProfileId) -> String {
  let ProfileId(s) = id
  s
}

/// Validates and constructs an `InstanceId`.
///
/// Rules:
/// - Must be non-empty.
/// - Max length is 64.
/// - Allowed characters: letters, digits, `-`, `_`.
///
/// Example:
/// ```gleam
/// import sad/types/core
///
/// let id = core.instance_id("run-001")
/// ```
pub fn instance_id(s: String) -> Result(InstanceId, InstanceIdError) {
  case string.is_empty(s) {
    True -> Error(EmptyInstanceId)
    False ->
      case string.length(s) > 64 {
        True -> Error(InstanceIdTooLong(max: 64))
        False ->
          case
            s
            |> string.to_graphemes
            |> list.find(fn(char) { is_instance_id_char(char) == False })
          {
            Ok(char) -> Error(InstanceIdInvalidChar(char))
            Error(_) -> Ok(InstanceId(s))
          }
      }
  }
}

/// Converts an `InstanceIdError` to a stable string code.
///
/// This is intended for logs and client-facing error messages.
pub fn instance_id_error_to_string(err: InstanceIdError) -> String {
  case err {
    EmptyInstanceId -> "empty"
    InstanceIdTooLong(max) -> "too_long:" <> int.to_string(max)
    InstanceIdInvalidChar(char) -> "invalid_char:" <> char
  }
}

/// Unwraps an `InstanceId` into its string representation.
pub fn instance_id_to_string(id: InstanceId) -> String {
  let InstanceId(s) = id
  s
}

/// Wraps a string as a `TraceId`.
pub fn trace_id(s: String) -> TraceId {
  TraceId(s)
}

/// Unwraps a `TraceId` into its string representation.
pub fn trace_id_to_string(id: TraceId) -> String {
  let TraceId(s) = id
  s
}

/// A small set of value types used across SAD.
///
/// This is used for parameters and for `InputPayload.extra_params`.
pub type Value {
  StringVal(String)
  IntVal(Int)
  FloatVal(Float)
  BoolVal(Bool)
  ListVal(List(String))
}

/// The kind of a `Value`.
///
/// Use `value_type` to derive it from a runtime `Value`.
pub type ValueType {
  TypeString
  TypeInt
  TypeFloat
  TypeBool
  TypeList
}

/// Renders a `Value` to its string representation.
///
/// Lists are joined with `,`.
pub fn value_to_string(value: Value) -> String {
  case value {
    StringVal(s) -> s
    IntVal(i) -> int.to_string(i)
    FloatVal(f) -> float.to_string(f)
    BoolVal(True) -> "true"
    BoolVal(False) -> "false"
    ListVal(items) -> string.join(items, ",")
  }
}

/// Returns the `ValueType` corresponding to a `Value`.
pub fn value_type(value: Value) -> ValueType {
  case value {
    StringVal(_) -> TypeString
    IntVal(_) -> TypeInt
    FloatVal(_) -> TypeFloat
    BoolVal(_) -> TypeBool
    ListVal(_) -> TypeList
  }
}

/// A value that should not be printed in logs.
///
/// Use `secret_to_env_value` when exporting, and `secret_inspect` for safe
/// diagnostics.
pub opaque type SecretValue {
  SecretValue(inner: String)
}

/// Identifier of a stored artifact.
pub opaque type ArtifactId {
  ArtifactId(String)
}

/// Wraps a string as an `ArtifactId`.
pub fn artifact_id(s: String) -> ArtifactId {
  ArtifactId(s)
}

/// Unwraps an `ArtifactId` into its string representation.
pub fn artifact_id_to_string(id: ArtifactId) -> String {
  let ArtifactId(s) = id
  s
}

/// Wraps a string as a `SecretValue`.
///
/// Prefer creating secrets at the boundary where they enter the system.
pub fn secret_value(s: String) -> SecretValue {
  SecretValue(s)
}

/// Unwraps a secret for environment export.
///
/// This returns the raw value.
pub fn secret_to_env_value(secret: SecretValue) -> String {
  let SecretValue(inner) = secret
  inner
}

/// Renders a secret for logs.
///
/// This never returns the raw value.
pub fn secret_inspect(_secret: SecretValue) -> String {
  "***REDACTED***"
}

/// Returns `True` when the wrapped secret is empty.
pub fn secret_is_empty(secret: SecretValue) -> Bool {
  let SecretValue(inner) = secret
  string.is_empty(inner)
}

fn is_instance_id_char(char: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_",
    char,
  )
}
