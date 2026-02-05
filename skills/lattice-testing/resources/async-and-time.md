# Async and Time

## EventTask sequencing

When testing async actions, await `EventTask.finish()` to ensure effects complete before asserting on state.

## Time control

Use `TestClock` to drive debounced or delayed behavior deterministically. Advance time explicitly and assert on emitted values or final state.

## Streams

Wrap `AsyncStream` outputs with `AsyncStreamRecorder` to assert emissions without ad-hoc sleeps.
