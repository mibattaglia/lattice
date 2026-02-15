# Async and Time

## EventTask sequencing

When testing async actions, await `EventTask.finish()` to ensure effects complete before asserting on state.

## Time control

Use `TestClock` to drive debounced or delayed behavior deterministically. Advance time explicitly and assert on emitted values or final state.

For effect-level debouncing:
- assert state changes immediately after `send`
- advance the clock to trigger debounced `.perform` work
- assert the final state/action history after awaiting completion

## Streams

Wrap `AsyncStream` outputs with `AsyncStreamRecorder` to assert emissions without ad-hoc sleeps.
Use `waitForEmissions(count:timeout:)` and `waitForNextEmission(timeout:)` for deterministic checkpoints.
