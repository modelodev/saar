import gleam/erlang/process
import gleeunit
import gleeunit/should
import saar/otp/safe_call

pub fn main() {
  gleeunit.main()
}

type Msg {
  Ping(reply_to: process.Subject(String))
}

pub fn call_within_ok_on_reply() {
  let subject = process.new_subject()

  let _pid =
    process.spawn(fn() {
      case process.receive(subject, 1000) {
        Ok(Ping(reply_to)) -> process.send(reply_to, "pong")
        Error(_) -> Nil
      }
    })

  let result =
    safe_call.call_within(subject, 1000, fn(reply_to) { Ping(reply_to) })
  result |> should.equal(Ok("pong"))
}

pub fn call_within_disconnected_when_callee_down() {
  let ready = process.new_subject()

  let _pid =
    process.spawn(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      Nil
    })

  let subject = case process.receive(ready, 1000) {
    Ok(subject) -> subject
    Error(_) -> panic as "Did not receive subject"
  }

  let result =
    safe_call.call_within(subject, 1000, fn(reply_to) { Ping(reply_to) })
  result |> should.equal(Error(safe_call.Disconnected))
}

pub fn call_within_timed_out_when_no_reply() {
  let ready = process.new_subject()

  let _pid =
    process.spawn(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)

      // Keep the subject owner alive beyond the caller timeout.
      process.sleep(200)
    })

  let subject = case process.receive(ready, 1000) {
    Ok(subject) -> subject
    Error(_) -> panic as "Did not receive subject"
  }

  let result =
    safe_call.call_within(subject, 25, fn(reply_to) { Ping(reply_to) })
  result |> should.equal(Error(safe_call.TimedOut))
}
