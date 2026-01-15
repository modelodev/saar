import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import qcheck
import sad/bridge/runner_contract
import sad/types/runner as types_runner

const test_count: Int = 200

pub fn prop_validate_sequence_chunks_require_streaming_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let deltas_generator =
    qcheck.generic_list(qcheck.string(), qcheck.bounded_int(0, 5))

  let generator = qcheck.tuple2(qcheck.bool(), deltas_generator)

  qcheck.run(config, generator, fn(pair) {
    let #(streaming, deltas) = pair

    let chunk_events =
      deltas
      |> list.map(fn(delta) { types_runner.RunnerEventChunk(delta: delta) })

    let result_event =
      types_runner.RunnerEventResult(
        response: types_runner.RunnerSuccess(data: None, artifacts: []),
      )

    let events = list.append(chunk_events, [result_event])

    case streaming, deltas {
      False, [_, ..] ->
        should.equal(
          runner_contract.validate_sequence(events, streaming),
          Error(runner_contract.ChunkWithoutStreaming),
        )

      _, _ ->
        should.equal(
          runner_contract.validate_sequence(events, streaming),
          Ok(Nil),
        )
    }
  })
}

pub fn prop_validate_sequence_rejects_duplicate_result_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let result_event =
    types_runner.RunnerEventResult(
      response: types_runner.RunnerSuccess(data: None, artifacts: []),
    )

  qcheck.run(config, qcheck.bool(), fn(_flag) {
    should.equal(
      runner_contract.validate_sequence([result_event, result_event], True),
      Error(runner_contract.DuplicateResult),
    )
  })
}

pub fn prop_enforce_max_stdout_bytes_tracks_byte_size_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let generator = qcheck.tuple2(qcheck.bounded_int(1, 200), qcheck.string())

  qcheck.run(config, generator, fn(pair) {
    let #(max_bytes, line) = pair
    let expected_next = string.byte_size(line)

    case runner_contract.enforce_max_stdout_bytes(0, line, max_bytes) {
      Ok(next) -> {
        should.equal(next, expected_next)
        should.equal(next <= max_bytes, True)
      }

      Error(runner_contract.StdoutBytesExceeded(max: max, total: total)) -> {
        should.equal(max, max_bytes)
        should.equal(total, expected_next)
        should.equal(expected_next > max_bytes, True)
      }

      Error(_) -> should.fail()
    }
  })
}
