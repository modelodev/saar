//// Profile JSON Schema validation for SAAR profiles.
////
//// Mission: validate profile JSON against schema v1 invariants before decoding.
////
//// Responsibilities:
//// - Enforce required fields and enums for profile structure.
//// - Validate input_schema forms and critical additionalProperties=false blocks.
////
//// Non-responsibilities:
//// - Decoding JSON into typed Profile values.
//// - Loading profiles from disk or performing IO.
////
//// Relationships:
//// - Consumed by loaders/tests prior to `saar/decoders`.
//// - Mirrors constraints documented in `docs/arquitectura/config.md`.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Schema validation error for profile JSON.
pub type SchemaError {
  MissingRequired(path: List(String), field: String)
  InvalidEnum(path: List(String), field: String, value: String)
  InvalidPattern(
    path: List(String),
    field: String,
    value: String,
    pattern: String,
  )
  InvalidType(path: List(String), field: String, expected: String)
  AdditionalProperty(path: List(String), field: String)
}

/// Returns a stable error code for a schema error.
pub fn error_code(error: SchemaError) -> String {
  case error {
    MissingRequired(_, _) -> "required"
    InvalidEnum(_, _, _) -> "enum"
    InvalidPattern(_, _, _, _) -> "pattern"
    InvalidType(_, _, _) -> "type"
    AdditionalProperty(_, _) -> "additional_properties"
  }
}

/// Returns a JSONPath-like string for a schema error.
pub fn error_json_path(error: SchemaError) -> String {
  let path = case error {
    MissingRequired(path, _) -> path
    InvalidEnum(path, _, _) -> path
    InvalidPattern(path, _, _, _) -> path
    InvalidType(path, _, _) -> path
    AdditionalProperty(path, _) -> path
  }

  case path {
    [] -> "$"
    _ -> "$." <> string.join(path, ".")
  }
}

/// Validates a profile JSON payload against schema v1 constraints.
pub fn validate_profile(value: Dynamic) -> Result(Nil, List(SchemaError)) {
  case decode_object(value) {
    Error(_) ->
      Error([
        InvalidType(path: [], field: "$", expected: "object"),
      ])

    Ok(root) ->
      case validate_profile_object(root) {
        [] -> Ok(Nil)
        errors -> Error(errors)
      }
  }
}

fn validate_profile_object(root: Dict(String, Dynamic)) -> List(SchemaError) {
  let base_required = ["schema_version", "meta", "runner", "interface"]
  let allowed = ["schema_version", "meta", "parameters", "runner", "interface"]

  []
  |> list.append(validate_required_fields(root, base_required, []))
  |> list.append(validate_allowed_fields(root, allowed, []))
  |> list.append(validate_schema_version(root))
  |> list.append(validate_meta(root))
  |> list.append(validate_parameters(root))
  |> list.append(validate_runner(root))
  |> list.append(validate_interface(root))
}

fn validate_schema_version(root: Dict(String, Dynamic)) -> List(SchemaError) {
  case dict.get(root, "schema_version") {
    Ok(value) ->
      case decode.run(value, decode.string) {
        Ok(version) ->
          case schema_version_ok(version) {
            True -> []
            False -> [
              InvalidPattern(
                path: ["schema_version"],
                field: "schema_version",
                value: version,
                pattern: "^saar\\.profile/\\d+\\.\\d+$",
              ),
            ]
          }

        Error(_) -> [
          InvalidType(
            path: ["schema_version"],
            field: "schema_version",
            expected: "string",
          ),
        ]
      }

    Error(_) -> []
  }
}

fn validate_meta(root: Dict(String, Dynamic)) -> List(SchemaError) {
  validate_object_field(root, "meta", [], fn(meta, path) {
    let required = ["id", "lifecycle", "description"]
    let allowed = ["id", "name", "lifecycle", "description"]

    []
    |> list.append(validate_required_fields(meta, required, path))
    |> list.append(validate_allowed_fields(meta, allowed, path))
    |> list.append(validate_string_field(meta, "id", path))
    |> list.append(validate_string_field(meta, "name", path))
    |> list.append(validate_string_field(meta, "description", path))
    |> list.append(validate_enum_field(
      meta,
      "lifecycle",
      ["transient", "continuous"],
      path,
    ))
  })
}

fn validate_parameters(root: Dict(String, Dynamic)) -> List(SchemaError) {
  validate_object_field(root, "parameters", [], fn(params, path) {
    params
    |> dict.to_list
    |> list.fold([], fn(errors, entry) {
      let #(name, value) = entry
      let param_path = list.append(path, [name])
      let next = validate_parameter(value, param_path)
      list.append(errors, next)
    })
  })
}

fn validate_parameter(value: Dynamic, path: List(String)) -> List(SchemaError) {
  case decode_object(value) {
    Error(_) -> [
      InvalidType(path: path, field: "parameter", expected: "object"),
    ]

    Ok(param) -> {
      let required = ["source", "type"]

      []
      |> list.append(validate_required_fields(param, required, path))
      |> list.append(validate_enum_field(
        param,
        "type",
        ["string", "int", "float", "bool"],
        path,
      ))
      |> list.append(validate_parameter_source(param, path))
    }
  }
}

fn validate_parameter_source(
  param: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  case dict.get(param, "source") {
    Error(_) -> []

    Ok(value) ->
      case decode.run(value, decode.string) {
        Error(_) -> [
          InvalidType(
            path: list.append(path, ["source"]),
            field: "source",
            expected: "string",
          ),
        ]

        Ok(source) ->
          case source {
            "fixed" ->
              []
              |> list.append(validate_allowed_fields(
                param,
                ["source", "type", "value"],
                path,
              ))
              |> list.append(validate_required_fields(param, ["value"], path))

            "config" ->
              []
              |> list.append(validate_allowed_fields(
                param,
                ["source", "type", "key", "default"],
                path,
              ))
              |> list.append(validate_required_fields(param, ["key"], path))

            "init" ->
              []
              |> list.append(validate_allowed_fields(
                param,
                ["source", "type", "key", "default"],
                path,
              ))
              |> list.append(validate_required_fields(param, ["key"], path))

            "secret" ->
              []
              |> list.append(validate_allowed_fields(
                param,
                ["source", "type", "key"],
                path,
              ))
              |> list.append(validate_required_fields(param, ["key"], path))

            _ -> [
              InvalidEnum(
                path: list.append(path, ["source"]),
                field: "source",
                value: source,
              ),
            ]
          }
      }
  }
}

fn validate_runner(root: Dict(String, Dynamic)) -> List(SchemaError) {
  validate_object_field(root, "runner", [], fn(runner, path) {
    let allowed = [
      "type",
      "tool_config",
      "runtime",
      "env_map",
      "args",
      "artifact_config",
      "mode",
    ]

    []
    |> list.append(validate_required_fields(
      runner,
      ["type", "tool_config"],
      path,
    ))
    |> list.append(validate_allowed_fields(runner, allowed, path))
    |> list.append(validate_string_field(runner, "type", path))
    |> list.append(validate_string_field(runner, "mode", path))
    |> list.append(validate_runner_env_map(runner, path))
    |> list.append(validate_string_list_field(runner, "args", path))
    |> list.append(validate_runner_tool_config(runner, path))
    |> list.append(validate_runner_runtime(runner, path))
    |> list.append(validate_runner_artifact_config(runner, path))
  })
}

fn validate_runner_env_map(
  runner: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  validate_object_field(runner, "env_map", path, fn(env_map, env_path) {
    env_map
    |> dict.to_list
    |> list.fold([], fn(errors, entry) {
      let #(key, value) = entry
      let value_path = list.append(env_path, [key])
      let next = validate_dynamic_string(value, value_path, key)
      list.append(errors, next)
    })
  })
}

fn validate_runner_tool_config(
  runner: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  validate_object_field(runner, "tool_config", path, fn(tool, tool_path) {
    case dict.get(tool, "script") {
      Ok(_) -> validate_tool_config_script(tool, tool_path)
      Error(_) -> validate_tool_config_package(tool, tool_path)
    }
  })
}

fn validate_tool_config_script(
  tool: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  []
  |> list.append(validate_allowed_fields(tool, ["script"], path))
  |> list.append(validate_required_fields(tool, ["script"], path))
  |> list.append(validate_string_field(tool, "script", path))
}

fn validate_tool_config_package(
  tool: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  []
  |> list.append(validate_allowed_fields(
    tool,
    ["package", "command", "with_packages", "python"],
    path,
  ))
  |> list.append(validate_required_fields(tool, ["package", "command"], path))
  |> list.append(validate_string_field(tool, "package", path))
  |> list.append(validate_string_field(tool, "command", path))
  |> list.append(validate_string_field(tool, "python", path))
  |> list.append(validate_string_list_field(tool, "with_packages", path))
}

fn validate_runner_runtime(
  runner: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  validate_object_field(runner, "runtime", path, fn(runtime, runtime_path) {
    []
    |> list.append(validate_allowed_fields(
      runtime,
      ["mode", "port_env_var", "host_env_var"],
      runtime_path,
    ))
    |> list.append(validate_enum_field(
      runtime,
      "mode",
      ["managed_port", "no_network"],
      runtime_path,
    ))
    |> list.append(validate_string_field(runtime, "port_env_var", runtime_path))
    |> list.append(validate_string_field(runtime, "host_env_var", runtime_path))
  })
}

fn validate_runner_artifact_config(
  runner: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  validate_object_field(
    runner,
    "artifact_config",
    path,
    fn(config, config_path) {
      []
      |> list.append(validate_allowed_fields(
        config,
        ["include", "exclude"],
        config_path,
      ))
      |> list.append(validate_string_list_field(config, "include", config_path))
      |> list.append(validate_string_list_field(config, "exclude", config_path))
    },
  )
}

fn validate_interface(root: Dict(String, Dynamic)) -> List(SchemaError) {
  validate_object_field(root, "interface", [], fn(interface, path) {
    let required = ["protocol", "capabilities"]

    let base_errors = validate_required_fields(interface, required, path)
    let protocol_errors =
      validate_enum_field(interface, "protocol", ["runner", "http"], path)

    case dict.get(interface, "protocol") {
      Error(_) -> list.append(base_errors, protocol_errors)

      Ok(value) ->
        case decode.run(value, decode.string) {
          Error(_) -> list.append(base_errors, protocol_errors)

          Ok(protocol) ->
            case protocol {
              "runner" ->
                list.append(
                  base_errors,
                  validate_runner_interface(interface, path),
                )

              "http" ->
                list.append(
                  base_errors,
                  validate_http_interface(interface, path),
                )

              _ -> list.append(base_errors, protocol_errors)
            }
        }
    }
  })
}

fn validate_runner_interface(
  interface: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  []
  |> list.append(validate_allowed_fields(
    interface,
    ["protocol", "capabilities"],
    path,
  ))
  |> list.append(validate_capabilities(interface, "runner", path))
}

fn validate_http_interface(
  interface: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  []
  |> list.append(validate_allowed_fields(
    interface,
    ["protocol", "base_url", "headers", "health_check", "capabilities"],
    path,
  ))
  |> list.append(validate_string_field(interface, "base_url", path))
  |> list.append(validate_headers(interface, path))
  |> list.append(validate_health_check(interface, path))
  |> list.append(validate_capabilities(interface, "http", path))
}

fn validate_headers(
  interface: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  validate_object_field(interface, "headers", path, fn(headers, headers_path) {
    headers
    |> dict.to_list
    |> list.fold([], fn(errors, entry) {
      let #(key, value) = entry
      let value_path = list.append(headers_path, [key])
      let next = validate_dynamic_string(value, value_path, key)
      list.append(errors, next)
    })
  })
}

fn validate_health_check(
  interface: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  validate_object_field(interface, "health_check", path, fn(check, check_path) {
    []
    |> list.append(validate_allowed_fields(
      check,
      ["path", "method", "expect_statuses"],
      check_path,
    ))
    |> list.append(validate_required_fields(
      check,
      ["path", "method", "expect_statuses"],
      check_path,
    ))
    |> list.append(validate_string_field(check, "path", check_path))
    |> list.append(validate_http_method(check, "method", check_path))
    |> list.append(validate_int_list_field(check, "expect_statuses", check_path))
  })
}

fn validate_capabilities(
  interface: Dict(String, Dynamic),
  mode: String,
  path: List(String),
) -> List(SchemaError) {
  validate_object_field(
    interface,
    "capabilities",
    path,
    fn(capabilities, caps_path) {
      capabilities
      |> dict.to_list
      |> list.fold([], fn(errors, entry) {
        let #(name, value) = entry
        let cap_path = list.append(caps_path, [name])
        let next = case mode {
          "http" -> validate_http_capability(value, cap_path)
          _ -> validate_runner_capability(value, cap_path)
        }
        list.append(errors, next)
      })
    },
  )
}

fn validate_runner_capability(
  value: Dynamic,
  path: List(String),
) -> List(SchemaError) {
  case decode_object(value) {
    Error(_) -> [
      InvalidType(path: path, field: "capability", expected: "object"),
    ]

    Ok(capability) ->
      []
      |> list.append(validate_allowed_fields(
        capability,
        [
          "input_schema",
          "description",
          "streaming",
          "response_mode",
          "limits",
          "files",
        ],
        path,
      ))
      |> list.append(validate_string_field(capability, "description", path))
      |> list.append(validate_bool_field(capability, "streaming", path))
      |> list.append(validate_response_mode(capability, path))
      |> list.append(validate_capability_limits(capability, path))
      |> list.append(validate_files_semantics(capability, path))
      |> list.append(validate_input_schema_field(capability, path))
  }
}

fn validate_http_capability(
  value: Dynamic,
  path: List(String),
) -> List(SchemaError) {
  case decode_object(value) {
    Error(_) -> [
      InvalidType(path: path, field: "capability", expected: "object"),
    ]

    Ok(capability) ->
      []
      |> list.append(validate_allowed_fields(
        capability,
        [
          "path",
          "method",
          "input_schema",
          "body",
          "response",
          "description",
          "streaming",
          "response_mode",
          "limits",
          "files",
        ],
        path,
      ))
      |> list.append(validate_required_fields(
        capability,
        ["path", "method"],
        path,
      ))
      |> list.append(validate_string_field(capability, "path", path))
      |> list.append(validate_http_method(capability, "method", path))
      |> list.append(validate_string_field(capability, "description", path))
      |> list.append(validate_bool_field(capability, "streaming", path))
      |> list.append(validate_response_mode(capability, path))
      |> list.append(validate_capability_limits(capability, path))
      |> list.append(validate_files_semantics(capability, path))
      |> list.append(validate_input_schema_field(capability, path))
      |> list.append(validate_capability_body(capability, path))
      |> list.append(validate_capability_response(capability, path))
  }
}

fn validate_input_schema_field(
  capability: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  case dict.get(capability, "input_schema") {
    Error(_) -> []
    Ok(value) ->
      validate_input_schema(value, list.append(path, ["input_schema"]))
  }
}

fn validate_input_schema(
  value: Dynamic,
  path: List(String),
) -> List(SchemaError) {
  case decode.run(value, decode.string) {
    Ok(schema) ->
      validate_enum_value(
        schema,
        ["std:chat", "std:files"],
        path,
        "input_schema",
      )

    Error(_) ->
      case decode_object(value) {
        Error(_) -> [
          InvalidType(
            path: path,
            field: "input_schema",
            expected: "string|object",
          ),
        ]

        Ok(obj) -> validate_input_schema_object(obj, path)
      }
  }
}

fn validate_input_schema_object(
  obj: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  case dict.get(obj, "$ref") {
    Ok(ref) ->
      []
      |> list.append(validate_allowed_fields(obj, ["$ref"], path))
      |> list.append(validate_ref_value(ref, path))

    Error(_) -> validate_extended_schema(obj, path)
  }
}

fn validate_ref_value(value: Dynamic, path: List(String)) -> List(SchemaError) {
  case decode.run(value, decode.string) {
    Ok(schema) ->
      validate_enum_value(schema, ["std:chat", "std:files"], path, "$ref")

    Error(_) -> [
      InvalidType(
        path: list.append(path, ["$ref"]),
        field: "$ref",
        expected: "string",
      ),
    ]
  }
}

fn validate_extended_schema(
  obj: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  []
  |> list.append(validate_allowed_fields(obj, ["base", "extra_fields"], path))
  |> list.append(validate_required_fields(obj, ["base", "extra_fields"], path))
  |> list.append(validate_enum_field(obj, "base", ["std:chat"], path))
  |> list.append(validate_extra_fields(obj, path))
}

fn validate_extra_fields(
  obj: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  case dict.get(obj, "extra_fields") {
    Error(_) -> []
    Ok(value) ->
      case decode_object(value) {
        Error(_) -> [
          InvalidType(
            path: list.append(path, ["extra_fields"]),
            field: "extra_fields",
            expected: "object",
          ),
        ]

        Ok(extra_fields) ->
          extra_fields
          |> dict.to_list
          |> list.fold([], fn(errors, entry) {
            let #(name, def_value) = entry
            let def_path = list.append(path, ["extra_fields", name])
            let next = validate_extra_field_def(def_value, def_path)
            list.append(errors, next)
          })
      }
  }
}

fn validate_extra_field_def(
  value: Dynamic,
  path: List(String),
) -> List(SchemaError) {
  case decode_object(value) {
    Error(_) -> [
      InvalidType(path: path, field: "extra_field", expected: "object"),
    ]

    Ok(def) ->
      []
      |> list.append(validate_allowed_fields(
        def,
        ["type", "enum", "default"],
        path,
      ))
      |> list.append(validate_required_fields(def, ["type"], path))
      |> list.append(validate_enum_field(
        def,
        "type",
        ["string", "boolean", "number", "integer"],
        path,
      ))
      |> list.append(validate_string_list_field(def, "enum", path))
  }
}

fn validate_capability_limits(
  capability: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  validate_object_field(capability, "limits", path, fn(limits, limits_path) {
    []
    |> list.append(validate_allowed_fields(
      limits,
      ["call_timeout_ms"],
      limits_path,
    ))
    |> list.append(validate_int_field(limits, "call_timeout_ms", limits_path))
  })
}

fn validate_files_semantics(
  capability: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  validate_object_field(capability, "files", path, fn(files, files_path) {
    []
    |> list.append(validate_allowed_fields(
      files,
      ["accepts", "max_files", "ingest_effect"],
      files_path,
    ))
    |> list.append(validate_required_fields(
      files,
      ["accepts", "max_files"],
      files_path,
    ))
    |> list.append(validate_bool_field(files, "accepts", files_path))
    |> list.append(validate_int_field(files, "max_files", files_path))
    |> list.append(validate_enum_field(
      files,
      "ingest_effect",
      ["immediate", "eventual"],
      files_path,
    ))
  })
}

fn validate_response_mode(
  capability: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  validate_enum_field(
    capability,
    "response_mode",
    ["sync", "stream", "deferred"],
    path,
  )
}

fn validate_capability_body(
  capability: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  validate_object_field(capability, "body", path, fn(body, body_path) {
    let base =
      []
      |> list.append(validate_required_fields(body, ["type"], body_path))
      |> list.append(validate_string_field(body, "type", body_path))

    case dict.get(body, "type") {
      Error(_) -> base

      Ok(value) ->
        case decode.run(value, decode.string) {
          Error(_) -> base

          Ok(kind) ->
            case kind {
              "json" ->
                list.append(
                  base,
                  validate_allowed_fields(body, ["type", "template"], body_path),
                )

              "multipart" ->
                base
                |> list.append(validate_allowed_fields(
                  body,
                  ["type", "fields", "files"],
                  body_path,
                ))
                |> list.append(validate_required_fields(
                  body,
                  ["files"],
                  body_path,
                ))
                |> list.append(validate_multipart_fields(body, body_path))

              _ ->
                list.append(base, [
                  InvalidEnum(
                    path: list.append(body_path, ["type"]),
                    field: "type",
                    value: kind,
                  ),
                ])
            }
        }
    }
  })
}

fn validate_multipart_fields(
  body: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  []
  |> list.append(
    validate_object_field(body, "fields", path, fn(fields, fields_path) {
      fields
      |> dict.to_list
      |> list.fold([], fn(errors, entry) {
        let #(key, value) = entry
        let value_path = list.append(fields_path, [key])
        let next = validate_dynamic_string(value, value_path, key)
        list.append(errors, next)
      })
    }),
  )
  |> list.append(validate_multipart_files(body, path))
}

fn validate_multipart_files(
  body: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  case dict.get(body, "files") {
    Error(_) -> []
    Ok(value) ->
      case decode.run(value, decode.list(of: decode.dynamic)) {
        Error(_) -> [
          InvalidType(
            path: list.append(path, ["files"]),
            field: "files",
            expected: "array",
          ),
        ]

        Ok(items) ->
          items
          |> list.index_map(fn(item, index) { #(index, item) })
          |> list.fold([], fn(errors, entry) {
            let #(index, item) = entry
            let item_path = list.append(path, ["files", int_to_string(index)])
            let next = validate_multipart_file_part(item, item_path)
            list.append(errors, next)
          })
      }
  }
}

fn validate_multipart_file_part(
  value: Dynamic,
  path: List(String),
) -> List(SchemaError) {
  case decode_object(value) {
    Error(_) -> [InvalidType(path: path, field: "file", expected: "object")]

    Ok(part) ->
      []
      |> list.append(validate_allowed_fields(
        part,
        ["field", "source_pointer"],
        path,
      ))
      |> list.append(validate_required_fields(
        part,
        ["field", "source_pointer"],
        path,
      ))
      |> list.append(validate_string_field(part, "field", path))
      |> list.append(validate_string_field(part, "source_pointer", path))
  }
}

fn validate_capability_response(
  capability: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  validate_object_field(
    capability,
    "response",
    path,
    fn(response, response_path) {
      []
      |> list.append(validate_allowed_fields(
        response,
        ["text_pointer", "artifacts_pointer", "capture"],
        response_path,
      ))
      |> list.append(validate_string_field(
        response,
        "text_pointer",
        response_path,
      ))
      |> list.append(validate_string_field(
        response,
        "artifacts_pointer",
        response_path,
      ))
      |> list.append(validate_capture(response, response_path))
    },
  )
}

fn validate_capture(
  response: Dict(String, Dynamic),
  path: List(String),
) -> List(SchemaError) {
  validate_object_field(response, "capture", path, fn(capture, capture_path) {
    capture
    |> dict.to_list
    |> list.fold([], fn(errors, entry) {
      let #(key, value) = entry
      let value_path = list.append(capture_path, [key])
      let next = validate_dynamic_string(value, value_path, key)
      list.append(errors, next)
    })
  })
}

fn validate_http_method(
  obj: Dict(String, Dynamic),
  field: String,
  path: List(String),
) -> List(SchemaError) {
  case dict.get(obj, field) {
    Error(_) -> []
    Ok(value) ->
      case decode.run(value, decode.string) {
        Error(_) -> [
          InvalidType(
            path: list.append(path, [field]),
            field: field,
            expected: "string",
          ),
        ]

        Ok(method) -> {
          let normalized = string.lowercase(method)
          case list.contains(["get", "post", "put", "delete"], normalized) {
            True -> []
            False -> [
              InvalidEnum(
                path: list.append(path, [field]),
                field: field,
                value: method,
              ),
            ]
          }
        }
      }
  }
}

fn validate_required_fields(
  fields: Dict(String, Dynamic),
  required: List(String),
  path: List(String),
) -> List(SchemaError) {
  required
  |> list.fold([], fn(errors, field) {
    case dict.get(fields, field) {
      Ok(_) -> errors
      Error(_) ->
        list.append(errors, [
          MissingRequired(path: list.append(path, [field]), field: field),
        ])
    }
  })
}

fn validate_allowed_fields(
  fields: Dict(String, Dynamic),
  allowed: List(String),
  path: List(String),
) -> List(SchemaError) {
  fields
  |> dict.to_list
  |> list.fold([], fn(errors, entry) {
    let #(field, _) = entry
    case list.contains(allowed, field) {
      True -> errors
      False ->
        list.append(errors, [
          AdditionalProperty(path: list.append(path, [field]), field: field),
        ])
    }
  })
}

fn validate_string_field(
  fields: Dict(String, Dynamic),
  field: String,
  path: List(String),
) -> List(SchemaError) {
  validate_dynamic_field(fields, field, path, decode.string, "string")
}

fn validate_bool_field(
  fields: Dict(String, Dynamic),
  field: String,
  path: List(String),
) -> List(SchemaError) {
  validate_dynamic_field(fields, field, path, decode.bool, "bool")
}

fn validate_int_field(
  fields: Dict(String, Dynamic),
  field: String,
  path: List(String),
) -> List(SchemaError) {
  validate_dynamic_field(fields, field, path, decode.int, "int")
}

fn validate_string_list_field(
  fields: Dict(String, Dynamic),
  field: String,
  path: List(String),
) -> List(SchemaError) {
  validate_list_field(fields, field, path, decode.string, "array")
}

fn validate_int_list_field(
  fields: Dict(String, Dynamic),
  field: String,
  path: List(String),
) -> List(SchemaError) {
  validate_list_field(fields, field, path, decode.int, "array")
}

fn validate_list_field(
  fields: Dict(String, Dynamic),
  field: String,
  path: List(String),
  decoder: decode.Decoder(a),
  expected: String,
) -> List(SchemaError) {
  case dict.get(fields, field) {
    Error(_) -> []
    Ok(value) ->
      case decode.run(value, decode.list(of: decoder)) {
        Ok(_) -> []
        Error(_) -> [
          InvalidType(
            path: list.append(path, [field]),
            field: field,
            expected: expected,
          ),
        ]
      }
  }
}

fn validate_dynamic_field(
  fields: Dict(String, Dynamic),
  field: String,
  path: List(String),
  decoder: decode.Decoder(a),
  expected: String,
) -> List(SchemaError) {
  case dict.get(fields, field) {
    Error(_) -> []
    Ok(value) ->
      validate_dynamic_value(
        value,
        list.append(path, [field]),
        field,
        decoder,
        expected,
      )
  }
}

fn validate_dynamic_value(
  value: Dynamic,
  path: List(String),
  field: String,
  decoder: decode.Decoder(a),
  expected: String,
) -> List(SchemaError) {
  case decode.run(value, decoder) {
    Ok(_) -> []
    Error(_) -> [InvalidType(path: path, field: field, expected: expected)]
  }
}

fn validate_dynamic_string(
  value: Dynamic,
  path: List(String),
  field: String,
) -> List(SchemaError) {
  validate_dynamic_value(value, path, field, decode.string, "string")
}

fn validate_enum_field(
  fields: Dict(String, Dynamic),
  field: String,
  allowed: List(String),
  path: List(String),
) -> List(SchemaError) {
  case dict.get(fields, field) {
    Error(_) -> []
    Ok(value) ->
      case decode.run(value, decode.string) {
        Error(_) -> [
          InvalidType(
            path: list.append(path, [field]),
            field: field,
            expected: "string",
          ),
        ]

        Ok(raw) ->
          validate_enum_value(raw, allowed, list.append(path, [field]), field)
      }
  }
}

fn validate_enum_value(
  value: String,
  allowed: List(String),
  path: List(String),
  field: String,
) -> List(SchemaError) {
  case list.contains(allowed, value) {
    True -> []
    False -> [InvalidEnum(path: path, field: field, value: value)]
  }
}

fn validate_object_field(
  fields: Dict(String, Dynamic),
  field: String,
  path: List(String),
  validator: fn(Dict(String, Dynamic), List(String)) -> List(SchemaError),
) -> List(SchemaError) {
  case dict.get(fields, field) {
    Error(_) -> []
    Ok(value) ->
      case decode_object(value) {
        Ok(obj) -> validator(obj, list.append(path, [field]))
        Error(_) -> [
          InvalidType(
            path: list.append(path, [field]),
            field: field,
            expected: "object",
          ),
        ]
      }
  }
}

fn decode_object(value: Dynamic) -> Result(Dict(String, Dynamic), Nil) {
  decode.run(value, decode.dict(decode.string, decode.dynamic))
  |> result.map_error(fn(_) { Nil })
}

fn schema_version_ok(value: String) -> Bool {
  let prefix = "saar.profile/"
  case string.starts_with(value, prefix) {
    False -> False
    True -> {
      let rest =
        string.slice(value, string.length(prefix), string.length(value))
      case string.split(rest, ".") {
        [major, minor] -> is_digits(major) && is_digits(minor)
        _ -> False
      }
    }
  }
}

fn is_digits(value: String) -> Bool {
  case value {
    "" -> False
    _ ->
      case int.parse(value) {
        Ok(_) -> !string.starts_with(value, "-")
        Error(_) -> False
      }
  }
}

fn int_to_string(value: Int) -> String {
  value |> int.to_string
}
