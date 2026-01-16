//// Gateway request URL helpers.
////
//// Mission: centralize base URL derivation for gateway handlers.
////
//// Responsibilities:
//// - Build an absolute request base URL (scheme + host).
//// - Build instance-scoped A2A base URLs.
////
//// Non-responsibilities:
//// - Performing authentication.
//// - Routing or parsing request bodies.
////
//// Relationships:
//// - Used by HTTP handlers such as `sys_api`, `agents_api`, and `a2a_api`.

import gleam/http
import gleam/http/request
import gleam/option.{type Option, None, Some}
import mist
import saar/types/core as types_core

/// Builds a best-effort absolute base URL for a request.
///
/// The value prefers `x-forwarded-proto`/`x-forwarded-host` when present.
pub fn base_url(req: request.Request(mist.Connection)) -> Option(String) {
  let forwarded_proto = request.get_header(req, "x-forwarded-proto")
  let forwarded_host = request.get_header(req, "x-forwarded-host")

  case forwarded_proto, forwarded_host {
    Ok(proto), Ok(host) -> Some(proto <> "://" <> host)
    _, _ -> {
      let proto = case forwarded_proto {
        Ok(p) -> p
        Error(_) -> http.scheme_to_string(req.scheme)
      }

      case request.get_header(req, "host") {
        Ok(host) -> Some(proto <> "://" <> host)
        Error(_) -> Some(proto <> "://" <> req.host)
      }
    }
  }
}

/// Returns the per-instance base URL prefix for A2A endpoints.
///
/// When the request host cannot be resolved, the function returns a relative
/// path.
pub fn a2a_base_url(
  req: request.Request(mist.Connection),
  instance_id: types_core.InstanceId,
) -> String {
  let suffix =
    "/instances/" <> types_core.instance_id_to_string(instance_id) <> "/"

  case base_url(req) {
    Some(base) -> base <> suffix
    None -> suffix
  }
}
