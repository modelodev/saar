import gleam/float
import gleam/int
import gleam/string

pub opaque type ProfileId {
  ProfileId(String)
}

pub opaque type InstanceId {
  InstanceId(String)
}

pub opaque type TraceId {
  TraceId(String)
}

pub fn profile_id(s: String) -> ProfileId {
  ProfileId(s)
}

pub fn profile_id_to_string(id: ProfileId) -> String {
  let ProfileId(s) = id
  s
}

pub fn instance_id(s: String) -> InstanceId {
  InstanceId(s)
}

pub fn instance_id_to_string(id: InstanceId) -> String {
  let InstanceId(s) = id
  s
}

pub fn trace_id(s: String) -> TraceId {
  TraceId(s)
}

pub fn trace_id_to_string(id: TraceId) -> String {
  let TraceId(s) = id
  s
}

pub type Value {
  StringVal(String)
  IntVal(Int)
  FloatVal(Float)
  BoolVal(Bool)
  ListVal(List(String))
}

pub type ValueType {
  TypeString
  TypeInt
  TypeFloat
  TypeBool
  TypeList
}

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

pub fn value_type(value: Value) -> ValueType {
  case value {
    StringVal(_) -> TypeString
    IntVal(_) -> TypeInt
    FloatVal(_) -> TypeFloat
    BoolVal(_) -> TypeBool
    ListVal(_) -> TypeList
  }
}

pub opaque type SecretValue {
  SecretValue(inner: String)
}

pub opaque type ArtifactId {
  ArtifactId(String)
}

pub fn artifact_id(s: String) -> ArtifactId {
  ArtifactId(s)
}

pub fn artifact_id_to_string(id: ArtifactId) -> String {
  let ArtifactId(s) = id
  s
}

pub fn secret_value(s: String) -> SecretValue {
  SecretValue(s)
}

pub fn secret_to_env_value(secret: SecretValue) -> String {
  let SecretValue(inner) = secret
  inner
}

pub fn secret_inspect(_secret: SecretValue) -> String {
  "***REDACTED***"
}

pub fn secret_is_empty(secret: SecretValue) -> Bool {
  let SecretValue(inner) = secret
  string.is_empty(inner)
}
