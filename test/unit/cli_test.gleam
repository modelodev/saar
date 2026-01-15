import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import sad/cli

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
