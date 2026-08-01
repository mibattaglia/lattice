# Async and Time

## Effect tasks and quiescence

- `let task = await model.send(...)` returns a `TestEventTask` over the effects that send
  launched directly.
- `await task.finish()` waits for those effects to settle; `task.cancel()` cancels them.
- `await model.finish()` waits for every in-flight effect task, then (under exhaustivity)
  fails on unasserted commits.
- `await model.dismount()` cancels every task bucket and fails on unasserted commits — the
  right call at the end of a test with long-lived effects.

## Time control

Use `TestClock` to drive debounced or delayed behavior deterministically. Advance time
explicitly and assert the resulting commits:

- assert the synchronous mutation in the `send` block
- `await clock.advance(by: …)` past the debounce/delay window
- `await model.expect { … }` the effect's `modify` re-entry

Debounce is task replacement: re-sending the same action replaces the in-flight task at that
`perform` call site, so only the last dispatch's work survives the window.

## Asserting effect output

- Use `expect(timeout:changes:)` for each `effectState.modify` commit, in commit order.
- Use `receive(_:timeout:changes:)` / `receive(\.case, timeout:changes:)` only for
  `effectState.send` re-entries.
- Commits made by an effect before its first suspension are already pending when `send`
  returns; `expect` consumes them without waiting.
- `skipPendingCommits()` is the escape hatch for non-exhaustive tests that want to advance
  past pending commits; it moves `domainState` to the latest committed state.
