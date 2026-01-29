//// CLI parsing for SAAR.
////
//// Mission: parse `argv` into a typed command model.
////
//// Responsibilities:
//// - Provide a small, pure command parser used by `saar.main`.
//// - Enforce basic flag semantics (required flags, conflicts, duplicates).
////
//// Non-responsibilities:
//// - Executing commands (server startup, IO, daemonization).
//// - Printing help/version strings.
////
//// Relationships:
//// - Used by `src/saar.gleam` as the entrypoint parser.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Command {
  Serve(ServeArgs)
  Validate(ValidateArgs)
  DryRun(DryRunArgs)
  RunnerTest(RunnerTestArgs)
  Agent(AgentCommand)
  Interact(InteractArgs)
  Version
  Help(Option(String))
}

pub type ServeMode {
  Foreground
  Background
  Kill
  Status
}

pub type ServeArgs {
  ServeArgs(mode: ServeMode, port: Option(Int), config_path: Option(String))
}

pub type ValidateArgs {
  ValidateArgs(path: String, config_path: Option(String))
}

pub type DryRunArgs {
  DryRunArgs(
    profile: String,
    input_path: String,
    capability: String,
    config_path: Option(String),
  )
}

pub type RunnerTestArgs {
  RunnerTestProfile(
    profile_path: String,
    input_path: Option(String),
    config_path: Option(String),
  )
  RunnerTestContract(
    contract_path: String,
    input_path: Option(String),
    config_path: Option(String),
  )
}

pub type AgentCommand {
  AgentList(config_path: Option(String))
  AgentCreate(
    profile_id: String,
    instance_id: String,
    config_path: Option(String),
  )
  AgentStatus(instance_id: String, config_path: Option(String))
  AgentStart(instance_id: String, config_path: Option(String))
  AgentStop(instance_id: String, config_path: Option(String))
  AgentInfo(instance_id: String, config_path: Option(String))
  AgentLogs(instance_id: String, config_path: Option(String))
  AgentParams(profile_id: String, config_path: Option(String))
  AgentCapability(
    profile_id: String,
    capability: String,
    config_path: Option(String),
  )
}

pub type InteractArgs {
  InteractArgs(
    instance_id: String,
    capability: String,
    input_path: Option(String),
    content: Option(String),
    mode: Option(String),
    file_urls: List(String),
    file_names: List(String),
    file_mimes: List(String),
    stream: Bool,
    trace_id: Option(String),
    output_dir: Option(String),
    config_path: Option(String),
  )
}

pub type ParseError {
  MissingCommand
  UnknownCommand(name: String, suggestions: List(String))
  MissingRequiredFlag(flag: String)
  MissingFlagValue(flag: String)
  UnknownFlag(flag: String)
  ConflictingFlags(flags: List(String))
  InvalidFlagValue(flag: String, value: String)
}

pub fn parse(argv: List(String)) -> Result(Command, ParseError) {
  case argv {
    [] -> Ok(Help(None))
    ["--help", ..] -> Ok(Help(None))
    ["-h", ..] -> Ok(Help(None))
    ["--version", ..] -> Ok(Version)
    [first, ..rest] -> parse_subcommand(first, rest)
  }
}

fn parse_subcommand(
  cmd: String,
  args: List(String),
) -> Result(Command, ParseError) {
  case cmd {
    "serve" -> parse_serve(args)
    "validate" -> parse_validate(args)
    "dry-run" -> parse_dry_run(args)
    "runner-test" -> parse_runner_test(args)
    "agent" -> parse_agent(args)
    "interact" -> parse_interact(args)
    _ -> Error(UnknownCommand(cmd, known_commands()))
  }
}

fn known_commands() -> List(String) {
  ["serve", "validate", "dry-run", "runner-test", "agent", "interact"]
}

/// Maps parsing results to CLI exit codes.
///
/// - `Ok(_)` -> 0
/// - `Error(_)` -> 1 (usage)
pub fn exit_code(result: Result(Command, ParseError)) -> Int {
  case result {
    Ok(_) -> 0
    Error(_) -> 1
  }
}

fn parse_serve(args: List(String)) -> Result(Command, ParseError) {
  case list.any(args, fn(a) { a == "--help" || a == "-h" }) {
    True -> Ok(Help(Some("serve")))
    False -> {
      use parsed <- result.try(parse_serve_flags(args, Foreground, None, None))
      Ok(Serve(parsed))
    }
  }
}

fn parse_serve_flags(
  args: List(String),
  mode: ServeMode,
  port: Option(Int),
  config_path: Option(String),
) -> Result(ServeArgs, ParseError) {
  case args {
    [] -> Ok(ServeArgs(mode: mode, port: port, config_path: config_path))

    ["-b", ..rest] ->
      set_serve_mode(rest, mode, Background, "-b", port, config_path)

    ["--background", ..rest] ->
      set_serve_mode(rest, mode, Background, "--background", port, config_path)

    ["-k", ..rest] -> set_serve_mode(rest, mode, Kill, "-k", port, config_path)

    ["--kill", ..rest] ->
      set_serve_mode(rest, mode, Kill, "--kill", port, config_path)

    ["--status", ..rest] ->
      set_serve_mode(rest, mode, Status, "--status", port, config_path)

    ["-p", value, ..rest] ->
      case int.parse(value) {
        Ok(p) -> parse_serve_flags(rest, mode, Some(p), config_path)
        Error(_) -> Error(InvalidFlagValue(flag: "-p", value: value))
      }

    ["--port", value, ..rest] ->
      case int.parse(value) {
        Ok(p) -> parse_serve_flags(rest, mode, Some(p), config_path)
        Error(_) -> Error(InvalidFlagValue(flag: "--port", value: value))
      }

    ["-p"] -> Error(MissingFlagValue("-p"))
    ["--port"] -> Error(MissingFlagValue("--port"))

    ["--config", value, ..rest] ->
      parse_serve_flags(rest, mode, port, Some(value))

    ["--config"] -> Error(MissingFlagValue("--config"))

    [flag, ..] ->
      case string.starts_with(flag, "-") {
        True -> Error(UnknownFlag(flag))
        False -> Error(UnknownFlag("<arg>"))
      }
  }
}

fn set_serve_mode(
  rest: List(String),
  current: ServeMode,
  next: ServeMode,
  flag: String,
  port: Option(Int),
  config_path: Option(String),
) -> Result(ServeArgs, ParseError) {
  case current {
    Foreground -> parse_serve_flags(rest, next, port, config_path)
    _ -> Error(ConflictingFlags([flag]))
  }
}

fn parse_validate(args: List(String)) -> Result(Command, ParseError) {
  case list.any(args, fn(a) { a == "--help" || a == "-h" }) {
    True -> Ok(Help(Some("validate")))
    False ->
      case parse_optional_config(args) {
        Error(e) -> Error(e)
        Ok(#(config_path, remaining)) ->
          case remaining {
            [path] ->
              Ok(Validate(ValidateArgs(path: path, config_path: config_path)))
            [] -> Error(MissingRequiredFlag("<path>"))
            _ -> Error(UnknownFlag("<arg>"))
          }
      }
  }
}

fn parse_dry_run(args: List(String)) -> Result(Command, ParseError) {
  case list.any(args, fn(a) { a == "--help" || a == "-h" }) {
    True -> Ok(Help(Some("dry-run")))
    False -> {
      use #(config_path, remaining) <- result.try(parse_optional_config(args))

      use profile <- result.try(required_flag_value(remaining, "--profile"))
      use input_path <- result.try(required_flag_value(remaining, "--input"))
      use capability <- result.try(required_flag_value(
        remaining,
        "--capability",
      ))

      Ok(
        DryRun(DryRunArgs(
          profile: profile,
          input_path: input_path,
          capability: capability,
          config_path: config_path,
        )),
      )
    }
  }
}

fn parse_runner_test(args: List(String)) -> Result(Command, ParseError) {
  case list.any(args, fn(a) { a == "--help" || a == "-h" }) {
    True -> Ok(Help(Some("runner-test")))
    False -> {
      use #(config_path, remaining) <- result.try(parse_optional_config(args))

      case remaining {
        ["--contract", contract_path, ..rest] -> {
          let input_path = optional_flag_value(rest, "--input")
          Ok(
            RunnerTest(RunnerTestContract(
              contract_path: contract_path,
              input_path: input_path,
              config_path: config_path,
            )),
          )
        }

        [profile_path, ..rest] -> {
          let input_path = optional_flag_value(rest, "--input")
          Ok(
            RunnerTest(RunnerTestProfile(
              profile_path: profile_path,
              input_path: input_path,
              config_path: config_path,
            )),
          )
        }

        [] -> Error(MissingRequiredFlag("<profile_path>|--contract"))
      }
    }
  }
}

fn parse_optional_config(
  args: List(String),
) -> Result(#(Option(String), List(String)), ParseError) {
  extract_flag_value(args, "--config")
}

fn extract_flag_value(
  args: List(String),
  flag: String,
) -> Result(#(Option(String), List(String)), ParseError) {
  extract_flag_value_loop(args, flag, None, [])
}

fn extract_flag_value_loop(
  args: List(String),
  flag: String,
  found: Option(String),
  acc: List(String),
) -> Result(#(Option(String), List(String)), ParseError) {
  case args {
    [] -> Ok(#(found, list.reverse(acc)))
    [a] if a == flag -> Error(MissingFlagValue(flag))
    [a, b, ..rest] if a == flag ->
      extract_flag_value_loop(rest, flag, Some(b), acc)
    [a, ..rest] -> extract_flag_value_loop(rest, flag, found, [a, ..acc])
  }
}

fn parse_agent(args: List(String)) -> Result(Command, ParseError) {
  case list.any(args, fn(a) { a == "--help" || a == "-h" }) {
    True -> Ok(Help(Some("agent")))
    False -> {
      use #(config_path, remaining) <- result.try(parse_optional_config(args))

      case remaining {
        ["list"] -> Ok(Agent(AgentList(config_path: config_path)))

        ["create", ..rest] -> {
          use profile_id <- result.try(required_flag_value(rest, "--profile"))
          use instance_id <- result.try(required_flag_value(rest, "--instance"))
          Ok(
            Agent(AgentCreate(
              profile_id: profile_id,
              instance_id: instance_id,
              config_path: config_path,
            )),
          )
        }

        ["status", instance_id] ->
          Ok(
            Agent(AgentStatus(
              instance_id: instance_id,
              config_path: config_path,
            )),
          )

        ["start", instance_id] ->
          Ok(
            Agent(AgentStart(instance_id: instance_id, config_path: config_path)),
          )

        ["stop", instance_id] ->
          Ok(
            Agent(AgentStop(instance_id: instance_id, config_path: config_path)),
          )

        ["info", instance_id] ->
          Ok(
            Agent(AgentInfo(instance_id: instance_id, config_path: config_path)),
          )

        ["logs", instance_id] ->
          Ok(
            Agent(AgentLogs(instance_id: instance_id, config_path: config_path)),
          )

        ["params", profile_id] ->
          Ok(
            Agent(AgentParams(profile_id: profile_id, config_path: config_path)),
          )

        ["capability", profile_id, capability] ->
          Ok(
            Agent(AgentCapability(
              profile_id: profile_id,
              capability: capability,
              config_path: config_path,
            )),
          )

        [] -> Error(MissingRequiredFlag("<agent_subcommand>"))
        _ -> Error(UnknownFlag("<arg>"))
      }
    }
  }
}

fn parse_interact(args: List(String)) -> Result(Command, ParseError) {
  case list.any(args, fn(a) { a == "--help" || a == "-h" }) {
    True -> Ok(Help(Some("interact")))
    False -> {
      use #(config_path, remaining) <- result.try(parse_optional_config(args))

      use instance_id <- result.try(required_flag_value(remaining, "--instance"))
      use capability <- result.try(required_flag_value(
        remaining,
        "--capability",
      ))
      use input_path <- result.try(optional_flag_value_checked(
        remaining,
        "--input",
      ))
      use content <- result.try(optional_flag_value_checked(
        remaining,
        "--content",
      ))
      use mode <- result.try(optional_flag_value_checked(remaining, "--mode"))
      use file_urls <- result.try(collect_flag_values(remaining, "--file-url"))
      use file_names <- result.try(collect_flag_values(remaining, "--file-name"))
      use file_mimes <- result.try(collect_flag_values(remaining, "--file-mime"))
      use trace_id <- result.try(optional_flag_value_checked(
        remaining,
        "--trace-id",
      ))
      use output_dir <- result.try(optional_flag_value_checked(
        remaining,
        "--output",
      ))

      let stream = list.any(remaining, fn(a) { a == "--stream" })

      Ok(
        Interact(InteractArgs(
          instance_id: instance_id,
          capability: capability,
          input_path: input_path,
          content: content,
          mode: mode,
          file_urls: file_urls,
          file_names: file_names,
          file_mimes: file_mimes,
          stream: stream,
          trace_id: trace_id,
          output_dir: output_dir,
          config_path: config_path,
        )),
      )
    }
  }
}

fn collect_flag_values(
  args: List(String),
  flag: String,
) -> Result(List(String), ParseError) {
  collect_flag_values_loop(args, flag, [])
}

fn collect_flag_values_loop(
  args: List(String),
  flag: String,
  acc: List(String),
) -> Result(List(String), ParseError) {
  case args {
    [] -> Ok(list.reverse(acc))
    [a] if a == flag -> Error(MissingFlagValue(flag))
    [a, b, ..rest] if a == flag ->
      collect_flag_values_loop(rest, flag, [b, ..acc])
    [_a, ..rest] -> collect_flag_values_loop(rest, flag, acc)
  }
}

fn required_flag_value(
  args: List(String),
  flag: String,
) -> Result(String, ParseError) {
  case find_flag_value(args, flag) {
    Ok(Some(value)) -> Ok(value)
    Ok(None) -> Error(MissingRequiredFlag(flag))
    Error(err) -> Error(err)
  }
}

fn optional_flag_value_checked(
  args: List(String),
  flag: String,
) -> Result(Option(String), ParseError) {
  case find_flag_value(args, flag) {
    Ok(value) -> Ok(value)
    Error(err) -> Error(err)
  }
}

fn optional_flag_value(args: List(String), flag: String) -> Option(String) {
  case find_flag_value(args, flag) {
    Ok(Some(value)) -> Some(value)
    _ -> None
  }
}

fn find_flag_value(
  args: List(String),
  flag: String,
) -> Result(Option(String), ParseError) {
  find_flag_value_loop(args, flag)
}

fn find_flag_value_loop(
  args: List(String),
  flag: String,
) -> Result(Option(String), ParseError) {
  case args {
    [] -> Ok(None)
    [a] if a == flag -> Error(MissingFlagValue(flag))
    [a, b, ..rest] if a == flag -> {
      // last flag wins
      use _ <- result.try(find_flag_value_loop(rest, flag))
      Ok(Some(b))
    }
    [a, ..rest] if a == flag -> find_flag_value_loop(rest, flag)
    [_other, ..rest] -> find_flag_value_loop(rest, flag)
  }
}
