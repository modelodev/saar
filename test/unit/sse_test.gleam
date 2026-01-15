import gleeunit
import gleeunit/should
import sad/sse

pub fn main() {
  gleeunit.main()
}

pub fn line_format() {
  sse.line("{\"ok\":true}")
  |> should.equal("data: {\"ok\":true}\n\n")
}

pub fn named_event_format() {
  sse.named_event("task_status", "{\"taskId\":\"t\"}")
  |> should.equal("event: task_status\ndata: {\"taskId\":\"t\"}\n\n")
}

pub fn comment_format() {
  sse.comment("keep-alive")
  |> should.equal(": keep-alive\n\n")
}
