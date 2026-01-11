import gleam/dict
import gleam/dynamic
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import sad/decoders
import sad/response_mapping
import sad/types/core as types_core
import sad/types/profile as types_profile
import simplifile

pub fn main() {
  gleeunit.main()
}

pub fn response_mapping_profile_fixture_test() {
  let assert Ok(contents) =
    simplifile.read(
      from: "test/fixtures/source_local/profiles/echo_server.json",
    )

  let assert Ok(profile) = json.parse(contents, decoders.profile_decoder())
  let types_profile.Profile(interface: interface, ..) = profile

  let assert types_profile.HttpInterface(capabilities: caps, ..) = interface
  let assert Ok(capability) = dict.get(caps, "echo")
  let types_profile.HttpCapability(response: response, ..) = capability
  let assert Some(mapping) = response

  let body =
    dynamic.properties([
      #(dynamic.string("answer"), dynamic.string("ok")),
      #(
        dynamic.string("files"),
        dynamic.list([
          dynamic.string("a"),
          dynamic.string("b"),
        ]),
      ),
    ])

  let assert Ok(response_mapping.MappingResult(text: text, artifacts: artifacts)) =
    response_mapping.apply_response_mapping(
      types_core.trace_id("trace-1"),
      Some(mapping),
      body,
    )

  text |> should.equal(Some("ok"))
  let assert Some(items) = artifacts
  list.length(items) |> should.equal(2)
}
