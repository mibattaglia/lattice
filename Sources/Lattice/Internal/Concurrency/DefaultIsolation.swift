/// The isolation of an actor-backed shell: a plain serial actor whose executor the shell adopts
/// through `unownedExecutor` and which the shell's `Core` holds as its `isolation`. It is a separate
/// object so that `shell → core → isolation` forms no retain cycle (binding the shell itself would,
/// and its `isolated deinit` would never run).
///
/// File scope and non-generic on purpose: nested in a generic shell, the compiler warns that the
/// shell's generic conformances may be isolated and cannot be passed to the actor.
@available(iOS 26, macOS 26, watchOS 26, *)
actor DefaultIsolation {}
