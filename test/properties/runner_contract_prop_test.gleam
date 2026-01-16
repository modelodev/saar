import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import qcheck
import sad/bridge/runner_contract
import sad/types/enums as types_enums
import sad/types/runner as types_runner

const test_count: Int = 200

pub fn prop_valid_sequences_pass_validation() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let deltas_generator =
    qcheck.generic_list(qcheck.string(), qcheck.bounded_int(0, 5))

  let generator =
    qcheck.bind(qcheck.bool(), fn(streaming) {
      let deltas = case streaming {
        True -> deltas_generator
        False -> qcheck.return([])
      }

      qcheck.map(deltas, fn(deltas) { #(streaming, deltas) })
    })

  qcheck.run(config, generator, fn(pair) {
    let #(streaming, deltas) = pair

    let events =
      list.append(deltas |> list.map(types_runner.RunnerEventChunk(delta: _)), [
        success_result_event(),
      ])

    runner_contract.validate_sequence(events, streaming)
    |> should.equal(Ok(Nil))
  })
}

pub fn prop_validate_sequence_chunks_require_streaming_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let deltas_generator =
    qcheck.generic_list(qcheck.string(), qcheck.bounded_int(0, 5))

  let generator = qcheck.tuple2(qcheck.bool(), deltas_generator)

  qcheck.run(config, generator, fn(pair) {
    let #(streaming, deltas) = pair

    let chunk_events =
      deltas |> list.map(types_runner.RunnerEventChunk(delta: _))
    let events = list.append(chunk_events, [success_result_event()])

    case streaming, deltas {
      False, [_, ..] ->
        runner_contract.validate_sequence(events, streaming)
        |> should.equal(Error(runner_contract.ChunkWithoutStreaming))

      _, _ ->
        runner_contract.validate_sequence(events, streaming)
        |> should.equal(Ok(Nil))
    }
  })
}

pub fn prop_validate_sequence_rejects_duplicate_result_test() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let result_event = success_result_event()

  qcheck.run(config, qcheck.bool(), fn(_flag) {
    runner_contract.validate_sequence([result_event, result_event], True)
    |> should.equal(Error(runner_contract.DuplicateResult))
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

pub fn prop_decode_event_result_matches_runner_response_from_raw() {
  let config = qcheck.default_config() |> qcheck.with_test_count(test_count)

  let generator =
    qcheck.tuple3(qcheck.bool(), qcheck.bool(), qcheck.uniform_int())

  qcheck.run(config, generator, fn(triple) {
    let #(is_success, include_data, n) = triple

    let data = case include_data {
      True -> Some(json.object([#("n", json.int(n))]))
      False -> None
    }

    let status = case is_success {
      True -> "success"
      False -> "error"
    }

    let expected_status = case is_success {
      True -> types_runner.StatusSuccess
      False -> types_runner.StatusError
    }

    let expected_error = case is_success {
      True -> None
      False ->
        Some(types_runner.RunnerError(
          kind: types_enums.InfraError,
          message: "boom",
        ))
    }

    let line =
      json.object([
        #("t", json.string("result")),
        #("status", json.string(status)),
        #("data", json_or_null(data)),
        #("error", error_payload_or_null(is_success)),
      ])
      |> json.to_string

    let assert Ok(types_runner.RunnerEventResult(response: got)) =
      runner_contract.decode_event(line)

    let expected =
      types_runner.runner_response_from_raw(
        expected_status,
        data,
        [],
        expected_error,
      )

    should.equal(got, expected)
  })
}

fn success_result_event() -> types_runner.RunnerEvent {
  types_runner.RunnerEventResult(
    response: types_runner.RunnerSuccess(data: None, artifacts: []),
  )
}

fn json_or_null(value: Option(json.Json)) -> json.Json {
  case value {
    None -> json.null()
    Some(v) -> v
  }
}

fn error_payload_or_null(is_success: Bool) -> json.Json {
  case is_success {
    True -> json.null()
    False ->
      json.object([
        #("kind", json.string("infra_error")),
        #("message", json.string("boom")),
      ])
  }
}
