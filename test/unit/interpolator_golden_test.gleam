import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import sad/bridge/interpolator
import sad/decoders
import sad/types/core as types_core
import sad/types/input as types_input
import sad/types/profile as types_profile
import simplifile

pub fn main() {
  gleeunit.main()
}

fn http_interp_context() -> interpolator.InterpContext {
  interpolator.build_context(
    dict.new(),
    types_input.PayloadChat([], dict.new()),
    types_input.RequestContext(
      trace_id: types_core.trace_id("trace-1"),
      extra: dict.new(),
    ),
    Some("127.0.0.1"),
    Some(8080),
  )
}

pub fn interpolate_profiles_base_url_golden_test() {
  let ctx = http_interp_context()
  let fixtures = [
    "test/fixtures/source_local/profiles/echo_server.json",
    "test/fixtures/source_local/profiles/slow_poke.json",
  ]

  fixtures
  |> list.each(fn(path) {
    let assert Ok(contents) = simplifile.read(from: path)
    let assert Ok(profile) = json.parse(contents, decoders.profile_decoder())
    let types_profile.Profile(interface: interface, ..) = profile

    let assert types_profile.HttpInterface(base_url: base_url, ..) = interface
    let assert Ok(url) =
      interpolator.interpolate_string_strict(base_url, ctx)

    url |> should.equal("http://127.0.0.1:8080")
  })
}
