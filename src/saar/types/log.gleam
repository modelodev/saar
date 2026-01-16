////
//// Mission: define safe-to-log structured log event types.
////
//// Responsibilities:
//// - Provide `LogEvent` values that preserve timestamp and correlation ids.
//// - Keep the type stable for internal streaming and diagnostics.
////
//// Non-responsibilities:
//// - Redacting runner-produced content.
//// - Persisting logs or providing transport-specific encodings.
////
//// Relationships:
//// - Used by core actors (e.g. `saar/core/agent`) and by gateway streaming.

import gleam/option.{type Option}
import saar/ffi
import saar/types/core

/// Origin of a log line.
///
/// This is intentionally small and stable.
pub type LogSource {
  StdErr
  AppLog
  SystemLog
}

/// A single structured log line with correlation metadata.
///
/// `line` is UTF-8 text and `ts_ms` is milliseconds since epoch.
pub type LogEvent {
  LogEvent(
    source: LogSource,
    line: String,
    ts_ms: Int,
    trace_id: Option(core.TraceId),
    instance_id: core.InstanceId,
  )
}

/// Builds a `LogEvent` capturing the current timestamp.
///
/// This function does not attempt to redact `line`.
pub fn log_event(
  source: LogSource,
  line: String,
  trace_id: Option(core.TraceId),
  instance_id: core.InstanceId,
) -> LogEvent {
  LogEvent(
    source: source,
    line: line,
    ts_ms: ffi.now_ms(),
    trace_id: trace_id,
    instance_id: instance_id,
  )
}
