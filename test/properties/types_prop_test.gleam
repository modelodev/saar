import gleeunit/should
import qcheck
import saar/types/core as types_core
import saar/types/enums as types_enums

const test_count: Int = 200

pub fn prop_error_kind_roundtrip_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let generator =
    qcheck.from_generators(qcheck.return(types_enums.AgentError), [
      qcheck.return(types_enums.InfraError),
      qcheck.return(types_enums.BadRequest),
    ])

  qcheck.run(config, generator, fn(kind) {
    types_enums.error_kind_to_string(kind)
    |> types_enums.error_kind_from_string
    |> should.equal(Ok(kind))
  })
}

pub fn prop_lifecycle_roundtrip_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let generator =
    qcheck.from_generators(qcheck.return(types_enums.Transient), [
      qcheck.return(types_enums.Continuous),
    ])

  qcheck.run(config, generator, fn(lifecycle) {
    types_enums.lifecycle_to_string(lifecycle)
    |> types_enums.lifecycle_from_string
    |> should.equal(Ok(lifecycle))
  })
}

pub fn prop_id_roundtrip_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  qcheck.run(config, qcheck.string(), fn(raw) {
    let profile = types_core.profile_id(raw)
    types_core.profile_id_to_string(profile)
    |> should.equal(raw)

    let trace = types_core.trace_id(raw)
    types_core.trace_id_to_string(trace)
    |> should.equal(raw)
  })

  let id_generator = instance_id_generator()

  qcheck.run(config, id_generator, fn(raw) {
    let assert Ok(instance) = types_core.instance_id(raw)
    types_core.instance_id_to_string(instance)
    |> should.equal(raw)
  })
}

pub fn prop_landlock_mode_roundtrip_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let generator =
    qcheck.from_generators(qcheck.return(types_enums.LandlockBestEffort), [
      qcheck.return(types_enums.LandlockEnforced),
      qcheck.return(types_enums.LandlockOff),
    ])

  qcheck.run(config, generator, fn(mode) {
    types_enums.landlock_mode_to_string(mode)
    |> types_enums.landlock_mode_from_string
    |> should.equal(Ok(mode))
  })
}

pub fn prop_error_kind_string_non_empty_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let generator =
    qcheck.from_generators(qcheck.return(types_enums.AgentError), [
      qcheck.return(types_enums.InfraError),
      qcheck.return(types_enums.BadRequest),
    ])

  qcheck.run(config, generator, fn(kind) {
    types_enums.error_kind_to_string(kind)
    |> should.not_equal("")
  })
}

pub fn prop_instance_id_error_string_non_empty_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let generator =
    qcheck.from_generators(qcheck.return(types_core.EmptyInstanceId), [
      qcheck.return(types_core.InstanceIdTooLong(max: 64)),
      qcheck.return(types_core.InstanceIdInvalidChar(char: "!")),
    ])

  qcheck.run(config, generator, fn(err) {
    types_core.instance_id_error_to_string(err)
    |> should.not_equal("")
  })
}

fn instance_id_generator() -> qcheck.Generator(String) {
  let allowed_chars =
    qcheck.from_weighted_generators(
      #(62, qcheck.alphanumeric_ascii_codepoint()),
      [#(2, qcheck.codepoint_from_ints(45, [95]))],
    )

  qcheck.generic_string(
    codepoints_from: allowed_chars,
    length_from: qcheck.bounded_int(1, 64),
  )
}
