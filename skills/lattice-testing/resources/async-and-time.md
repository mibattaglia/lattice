# Async and Time

## Root send scopes

- `let task = try await model.send(...)` returns a `TestEventTask` for that send scope only.
- `try await task.finish(timeout:)` waits for in-flight work in that scope to settle.
- Buffered receives remain queued until you `receive(...)` or `skipReceivedActions()`.

## Time control

Use `TestClock` to drive debounced or delayed behavior deterministically. Advance time explicitly and assert on emitted values or final state.

For effect-level debouncing:
- assert state changes immediately after `send`
- advance the clock to trigger debounced `.perform` work
- `receive(...)` the emitted action
- `finish()` the send scope after the expected receives have been handled

`Interactors.Debounce` only wraps top-level `.perform` work. It passes through `.none` and `.action`, and it traps on top-level `.observe`, `.merge`, and `.append`.

## Buffered async output

- Use `receive(...)` for the next effect-emitted action.
- If `Action` is `CasePathable`, `receive(\.loaded)` keeps tests concise.
- `skipReceivedActions()` is the escape hatch for non-exhaustive tests that want to advance past already buffered output.
- `skipInFlightEffects()` cancels and settles long-lived work when a test must move on without waiting for natural completion.
