import gleeunit/should
import qcheck
import sad/types

const test_count: Int = 200

pub fn prop_error_kind_roundtrip_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let generator =
    qcheck.from_generators(qcheck.return(types.AgentError), [
      qcheck.return(types.InfraError),
      qcheck.return(types.BadRequest),
    ])

  qcheck.run(config, generator, fn(kind) {
    types.error_kind_to_string(kind)
    |> types.error_kind_from_string
    |> should.equal(Ok(kind))
  })
}

pub fn prop_lifecycle_roundtrip_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let generator =
    qcheck.from_generators(qcheck.return(types.Transient), [
      qcheck.return(types.Continuous),
    ])

  qcheck.run(config, generator, fn(lifecycle) {
    types.lifecycle_to_string(lifecycle)
    |> types.lifecycle_from_string
    |> should.equal(Ok(lifecycle))
  })
}

pub fn prop_id_roundtrip_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  qcheck.run(config, qcheck.string(), fn(raw) {
    let profile = types.profile_id(raw)
    types.profile_id_to_string(profile)
    |> should.equal(raw)

    let instance = types.instance_id(raw)
    types.instance_id_to_string(instance)
    |> should.equal(raw)

    let trace = types.trace_id(raw)
    types.trace_id_to_string(trace)
    |> should.equal(raw)
  })
}
