import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import saar/cli

pub fn main() {
  gleeunit.main()
}

pub fn parse_dry_run_valid() {
  let result =
    cli.parse([
      "dry-run",
      "--profile",
      "aider",
      "--input",
      "payload.json",
      "--capability",
      "chat",
    ])

  case result {
    Ok(cli.DryRun(args)) -> {
      should.equal(args.profile, "aider")
      should.equal(args.input_path, "payload.json")
      should.equal(args.capability, "chat")
      should.equal(args.config_path, None)
    }

    Ok(_) -> panic as "Expected DryRun"
    Error(_) -> panic as "Expected Ok"
  }
}

pub fn parse_dry_run_missing_profile() {
  let result =
    cli.parse(["dry-run", "--input", "payload.json", "--capability", "chat"])

  case result {
    Error(cli.MissingRequiredFlag(flag)) -> should.equal(flag, "--profile")
    _ -> panic as "Expected MissingRequiredFlag(--profile)"
  }
}

pub fn parse_dry_run_missing_capability() {
  let result =
    cli.parse(["dry-run", "--profile", "aider", "--input", "payload.json"])

  case result {
    Error(cli.MissingRequiredFlag(flag)) -> should.equal(flag, "--capability")
    _ -> panic as "Expected MissingRequiredFlag(--capability)"
  }
}

pub fn parse_version() {
  cli.parse(["--version"])
  |> should.equal(Ok(cli.Version))

  should.equal(cli.exit_code(cli.parse(["--version"])), 0)
}

pub fn parse_help() {
  cli.parse(["--help"]) |> should.equal(Ok(cli.Help(None)))
}

pub fn parse_help_subcommand() {
  cli.parse(["serve", "--help"]) |> should.equal(Ok(cli.Help(Some("serve"))))
}

pub fn parse_unknown_command() {
  case cli.parse(["wat"]) {
    Error(cli.UnknownCommand(name, suggestions)) -> {
      should.equal(name, "wat")
      should.equal(suggestions != [], True)
    }

    _ -> panic as "Expected UnknownCommand"
  }

  should.equal(cli.exit_code(cli.parse(["wat"])), 1)
}

pub fn parse_conflicting_flags() {
  case cli.parse(["serve", "-b", "-k"]) {
    Error(cli.ConflictingFlags(_)) -> Nil
    _ -> panic as "Expected ConflictingFlags"
  }

  should.equal(cli.exit_code(cli.parse(["serve", "-b", "-k"])), 1)
}

pub fn parse_duplicate_flags() {
  case cli.parse(["serve", "-p", "8080", "-p", "9090"]) {
    Ok(cli.Serve(args)) -> {
      should.equal(args.port, Some(9090))
    }

    _ -> panic as "Expected Serve with last port winning"
  }
}

pub fn parse_dry_run_valid_test() {
  parse_dry_run_valid()
}

pub fn parse_dry_run_missing_profile_test() {
  parse_dry_run_missing_profile()
}

pub fn parse_dry_run_missing_capability_test() {
  parse_dry_run_missing_capability()
}

pub fn parse_version_test() {
  parse_version()
}

pub fn parse_help_test() {
  parse_help()
}

pub fn parse_help_subcommand_test() {
  parse_help_subcommand()
}

pub fn parse_unknown_command_test() {
  parse_unknown_command()
}

pub fn parse_conflicting_flags_test() {
  parse_conflicting_flags()
}

pub fn parse_duplicate_flags_test() {
  parse_duplicate_flags()
}

pub fn parse_agent_list() {
  let result = cli.parse(["agent", "list"])

  case result {
    Ok(cli.Agent(cli.AgentList(config_path: None))) -> Nil
    _ -> panic as "Expected AgentList"
  }
}

pub fn parse_agent_create() {
  let result =
    cli.parse([
      "agent",
      "create",
      "--profile",
      "aider",
      "--instance",
      "aider-1",
      "--config",
      "./config.toml",
    ])

  case result {
    Ok(cli.Agent(cli.AgentCreate(
      profile_id: profile_id,
      instance_id: instance_id,
      config_path: Some(config_path),
    ))) -> {
      should.equal(profile_id, "aider")
      should.equal(instance_id, "aider-1")
      should.equal(config_path, "./config.toml")
    }

    _ -> panic as "Expected AgentCreate"
  }
}

pub fn parse_agent_status() {
  let result = cli.parse(["agent", "status", "inst-1"])

  case result {
    Ok(cli.Agent(cli.AgentStatus(instance_id: instance_id, ..))) ->
      should.equal(instance_id, "inst-1")
    _ -> panic as "Expected AgentStatus"
  }
}

pub fn parse_agent_start_stop() {
  let start = cli.parse(["agent", "start", "inst-2"])
  let stop = cli.parse(["agent", "stop", "inst-2"])

  case start {
    Ok(cli.Agent(cli.AgentStart(instance_id: instance_id, ..))) ->
      should.equal(instance_id, "inst-2")
    _ -> panic as "Expected AgentStart"
  }

  case stop {
    Ok(cli.Agent(cli.AgentStop(instance_id: instance_id, ..))) ->
      should.equal(instance_id, "inst-2")
    _ -> panic as "Expected AgentStop"
  }
}

pub fn parse_agent_info() {
  let result = cli.parse(["agent", "info", "inst-3"])

  case result {
    Ok(cli.Agent(cli.AgentInfo(instance_id: instance_id, ..))) ->
      should.equal(instance_id, "inst-3")
    _ -> panic as "Expected AgentInfo"
  }
}

pub fn parse_agent_params() {
  let result = cli.parse(["agent", "params", "aider"])

  case result {
    Ok(cli.Agent(cli.AgentParams(profile_id: profile_id, ..))) ->
      should.equal(profile_id, "aider")
    _ -> panic as "Expected AgentParams"
  }
}

pub fn parse_agent_capability() {
  let result = cli.parse(["agent", "capability", "lightrag", "chat"])

  case result {
    Ok(cli.Agent(cli.AgentCapability(
      profile_id: profile_id,
      capability: capability,
      ..,
    ))) -> {
      should.equal(profile_id, "lightrag")
      should.equal(capability, "chat")
    }

    _ -> panic as "Expected AgentCapability"
  }
}

pub fn parse_agent_list_test() {
  parse_agent_list()
}

pub fn parse_agent_create_test() {
  parse_agent_create()
}

pub fn parse_agent_status_test() {
  parse_agent_status()
}

pub fn parse_agent_start_stop_test() {
  parse_agent_start_stop()
}

pub fn parse_agent_info_test() {
  parse_agent_info()
}

pub fn parse_agent_params_test() {
  parse_agent_params()
}

pub fn parse_agent_capability_test() {
  parse_agent_capability()
}
