import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import saar/cli_http
import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/enums as types_enums
import saar/types/profile as types_profile
import saar/types/runner as types_runner

pub fn main() {
  gleeunit.main()
}

pub fn base_url_uses_loopback_on_wildcard_host() {
  let cfg = types_config.default_saar_config()
  should.equal(cli_http.base_url_from_config(cfg), "http://127.0.0.1:8080")
}

pub fn auth_header_from_config() {
  let cfg =
    types_config.default_saar_config()
    |> fn(base) {
      types_config.SaarConfig(
        ..base,
        api_key: types_core.secret_value("secret"),
      )
    }

  should.equal(cli_http.auth_header_from_config(cfg), #(
    "authorization",
    "Bearer secret",
  ))
}

pub fn agent_params_reports_missing_secrets() {
  let params =
    dict.from_list([
      #(
        "openrouter_api_key",
        types_profile.SecretParam(
          "OPENROUTER_API_KEY",
          types_profile.ParamString,
        ),
      ),
      #(
        "model",
        types_profile.ConfigParam(
          "params.model",
          None,
          types_profile.ParamString,
        ),
      ),
    ])

  let profile =
    types_profile.Profile(
      meta: types_profile.ProfileMeta(
        id: types_core.profile_id("aider"),
        name: None,
        lifecycle: types_enums.Transient,
        description: "",
      ),
      parameters: params,
      runner: dummy_runner(),
      interface: types_profile.RunnerInterface(dict.new()),
    )

  let cfg =
    types_config.default_saar_config()
    |> fn(base) {
      types_config.SaarConfig(
        ..base,
        params: dict.from_list([#("model", types_core.StringVal("gpt-4"))]),
      )
    }

  let reports =
    cli_http.resolve_param_status(profile, cfg, fn(_key) { Error(Nil) })

  let lines = reports |> list.map(cli_http.render_param_report)

  should.equal(
    list.any(lines, fn(line) {
      line == "- openrouter_api_key (secret env: OPENROUTER_API_KEY) -> MISSING"
    }),
    True,
  )

  should.equal(
    list.any(lines, fn(line) { line == "- model (config: params.model) -> OK" }),
    True,
  )
}

pub fn agent_capability_reads_schema() {
  let extra_fields =
    dict.from_list([
      #(
        "mode",
        types_profile.ExtraFieldDef(
          type_: types_profile.FieldString,
          enum_values: Some(["hybrid", "naive", "local", "global", "mix"]),
          default: Some(types_core.StringVal("hybrid")),
        ),
      ),
    ])

  let caps =
    dict.from_list([
      #(
        "chat",
        types_profile.RunnerCapability(
          input_schema: Some(types_profile.SchemaChatExtended(extra_fields)),
          description: None,
          streaming: False,
          response_mode: types_profile.ResponseModeSync,
          limits: None,
          files: None,
        ),
      ),
    ])

  let profile =
    types_profile.Profile(
      meta: types_profile.ProfileMeta(
        id: types_core.profile_id("lightrag"),
        name: None,
        lifecycle: types_enums.Transient,
        description: "",
      ),
      parameters: dict.new(),
      runner: dummy_runner(),
      interface: types_profile.RunnerInterface(caps),
    )

  let assert Ok(lines) = cli_http.capability_schema_lines(profile, "chat")

  should.equal(
    list.any(lines, fn(line) { line == "- std:chat (requires messages)" }),
    True,
  )

  should.equal(
    list.any(lines, fn(line) {
      line
      == "- extra_fields: mode (optional, enum: hybrid|naive|local|global|mix, default: hybrid)"
    }),
    True,
  )
}

fn dummy_runner() -> types_runner.Runner {
  types_runner.Runner(
    type_: "dummy",
    tool_config: types_runner.ToolConfigScript("/bin/true"),
    runtime: types_runner.default_runtime_config(),
    env_map: dict.new(),
    args: [],
    artifact_config: types_runner.default_artifact_config(),
    exec_path: None,
  )
}
