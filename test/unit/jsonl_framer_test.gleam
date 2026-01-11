import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import sad/bridge/jsonl_framer

pub fn main() {
  gleeunit.main()
}

pub fn pop_line_none_when_no_newline_test() {
  let framer = jsonl_framer.from_buffer(10, "hello")
  let #(_next, result) = jsonl_framer.pop_line(framer)
  result |> should.equal(Ok(None))
}

pub fn frames_single_line_across_chunks_test() {
  let framer = jsonl_framer.init(100)
  let #(framer, pushed) = jsonl_framer.push_chunk(framer, "hello")
  pushed |> should.equal(Ok(Nil))

  let #(framer, pushed) = jsonl_framer.push_chunk(framer, "world\n")
  pushed |> should.equal(Ok(Nil))

  let #(framer, popped) = jsonl_framer.pop_line(framer)
  popped |> should.equal(Ok(Some("helloworld")))

  let #(_framer, popped2) = jsonl_framer.pop_line(framer)
  popped2 |> should.equal(Ok(None))
}

pub fn frames_multiple_lines_from_single_chunk_test() {
  let framer = jsonl_framer.from_buffer(100, "a\nb\n")

  let #(framer, popped1) = jsonl_framer.pop_line(framer)
  popped1 |> should.equal(Ok(Some("a")))

  let #(framer, popped2) = jsonl_framer.pop_line(framer)
  popped2 |> should.equal(Ok(Some("b")))

  let #(_framer, popped3) = jsonl_framer.pop_line(framer)
  popped3 |> should.equal(Ok(None))
}

pub fn oversized_buffer_without_newline_errors_and_clears_test() {
  let framer = jsonl_framer.init(5)
  let #(framer, pushed) = jsonl_framer.push_chunk(framer, "abcdef")

  pushed |> should.equal(Error(jsonl_framer.OversizedEvent(size: 6, max: 5)))
  framer |> jsonl_framer.buffer |> should.equal("")
}

pub fn oversized_line_errors_and_clears_test() {
  let framer = jsonl_framer.from_buffer(5, "abcdef\nrest")
  let #(framer, popped) = jsonl_framer.pop_line(framer)

  popped |> should.equal(Error(jsonl_framer.OversizedEvent(size: 6, max: 5)))
  framer |> jsonl_framer.buffer |> should.equal("")
}

pub fn finalize_returns_noeol_fragment_and_clears_test() {
  let framer = jsonl_framer.from_buffer(100, "partial")
  let #(framer, finalized) = jsonl_framer.finalize(framer)

  finalized |> should.equal(Error(jsonl_framer.NoeolFragment("partial")))
  framer |> jsonl_framer.buffer |> should.equal("")
}
