# AGENTS

## Project Snapshot
- Lattice is a Swift 6 library (MVVM + unidirectional data flow) with macros.
- Targets: Lattice (library), LatticeMacros (macro plugin), tests in Tests/.
- Supported platforms: iOS 17+, macOS 14+, watchOS 10+. `ActorModel` and `TestModel` need iOS 26, macOS 26 or watchOS 26.

## Layout
- `Sources/Lattice`: core runtime types (Interactor and the `Effects` handle, FeatureState and its ViewState projection, the nonisolated `Core` in `Internal/`, the `ViewModel` and `ActorModel` shells, testing helpers in `Testing/`).
- `Sources/LatticeMacros`: macro definitions; build product used by library.
- `Macros/`: output of `scripts/rebuild-macro.sh`, the release `LatticeMacros` tool used by Xcode/tooling and the CocoaPods pod; not checked in.
- `ExampleProject/`: sample Xcode project/workspace for manual validation, and the example packages (`Search`, `Todos`, `TimerLeak`, `ScopedComposition`, `FineGrained`) with their own tests.
- `Tests/NegativeCompileChecks`: fixtures compiled by `scripts/negative-compile-checks.sh`; not a SwiftPM target.
- `specs/`: source-driven docs. `effects-and-isolation.md`, `interactors.md` and `testing-infrastructure.md` describe the runtime.

## Main library concepts
- **FeatureState**: `@FeatureState` makes a struct or enum a feature's one state. Every stored member is observation-tracked, and a nested `ViewState` projection (a mirror enum for enum states) is what views read. `@Domain` hides a member from `ViewState` at compile time; it stays tracked.
- **Interactor**: the only mutator of a feature's state, with its effects. `interact(state:action:effects:)` mutates `state` synchronously and returns nothing. Declared with `@Interactor<State, Action>`; most bodies use `Interact { state, action, effects in … }`, or `Interact { state, action in … }` when the handler performs no effects.
- **Effects**: `effects.perform { … }` queues an effect. It is legal only during `interact` (`noasync`: a compile error inside an effect; from a synchronous closure inside an effect: reported and dropped). Effects start after `interact` returns, in order, each running its preamble before `send` returns, and they resume on the shell's isolation after every suspension.
- **Results are modifications**: an effect delivers its result with `effects.modify { $0.x = … }` (one commit, one test entry), never with a response action. `effects.send` only starts new effects, runs interactor logic (a parent, a sibling, a `When`) or auto-cancels by case; it is synchronous and depth-first, and during `interact` it is reported and dropped (there is no action queue).
- **Cancellation and errors**: a cancelled effect's `modify` still commits, so `try Task.checkCancellation()` goes before a superseded result and is mandatory after `try?`/`catch`. A live effect's thrown error is reported (`Effect threw: …`); errors thrown once its task is cancelled are not. A replaced run's `defer` runs after its replacement started, so a flag it clears can turn off early.
- **Auto-cancel and EffectID**: re-handling an action case cancels its previous anonymous effects, at the root and at each child case a `When` routes the action into; an ignored action still cancels. `@EffectID var x` with `perform(id: x)`, `cancel(x)` and `isRunning(x)` (per row: `$x.scoped(id)`) names an effect that is never auto-cancelled.
- **Debouncing**: `Interactors.Debounce(for:clock:)` delays every effect the child performs while state mutations stay immediate; it works when built inside `body`. Timers are `while true { try await clock.sleep(for:); try effects.modify(…) }`, never `try?`; clocks are injected as a generic `C: Clock` with a `ContinuousClock` initializer.
- **Composition**: `Interactors.When` / `when(state:action:child:)` for child-feature scoping via key paths and case paths. Consecutive children in `body` build `Merge`, a `for` loop builds `MergeMany`.
- **Shells**: one nonisolated `Core` runs the feature, only ever on its shell's isolation, so nothing in the feature layer needs `Sendable` and `eraseToAnyInteractor()` has no constraint. `ViewModel` (`@MainActor`, SwiftUI), `ActorModel` (actor, OS 26+, `async` init, `await model.state` needs `State: Sendable`), `TestModel` (actor, OS 26+, the primary test shell), `TestViewModel` (`@MainActor`, for main-actor-isolated interactors). Each shell's `isolated deinit` cancels its effects.
- **ViewModel**: bridges SwiftUI to the feature; `ViewModel(initialState:feature:)`. Member reads (`viewModel.title`) go through `State.ViewState` and are fine-grained; `viewModel.viewState` is the coarse read. `sendViewEvent(_:)` returns a discardable `Task<Void, Never>?` for exactly that send's effects; a `.task` forwards its cancellation to it with `withTaskCancellationHandler`.
- **Feature**: `Feature<Action, State>` bundles the interactor and an optional `areStatesEqual` (`==` for `Equatable` states) for `ViewModel<F>`.
- **ScopedViewModel**: `scope(state:action:)` projects a child, optional child, collection element or enum-case payload (`scopeIfActive`) for child views; its `sendViewEvent(_:)` returns the parent's task.
- **Testing**: `TestModel(initialState:feature:)` (`@available` on each `@Test`, nonisolated suites and fixtures, `setExhaustivity(_:)`) and `TestViewModel` assert on `state` with the feature's state equality: `send(_:assert:)`, `receive` (`Equatable`, predicate or case key path) for actions effects send, `expect { … }` for modifications (synchronous, can pass vacuously), `finish()`, `skipReceived(strict:)`, `skipInFlightEffects(strict:)`, `Exhaustivity.on` / `.off(showSkippedAssertions:)`. End exhaustive tests with `finish()`: the deinit report is only a warning under Swift Testing (under XCTest it fails the running test). Never `TestClock.advance` right after `send`; use a test-local gate clock (none ships: copy an example package's, such as `ExampleProject/SearchExamplePackage/Tests/SearchExampleTests/GateClock.swift`; the reference `Tests/LatticeTests/Support/GateClock.swift` has a log hook that needs that folder's `EffectLog.swift`) and never await a looping effect's task.
- **Concurrency settings**: `NonisolatedNonsendingByDefault` is enabled on the `Lattice` target, not on the test targets, which stand in for consumer modules. A consumer's dependency methods are `nonisolated(nonsending)` unless the consumer enables the feature. `Action` should be an enum.

## Build & Test (CLI)
- Build all: `swift build`. CI runs `swift build --build-tests`, `bash scripts/negative-compile-checks.sh`, then `swift test --skip-build`.
- Run all tests: `swift test`
- `swift test --filter` takes a regex matched against `Module.Suite/test` identifiers, not folder names.
- Run macro tests only: `swift test --filter LatticeMacrosTests`
- Run library tests only: `swift test --filter LatticeTests`
- Run `@FeatureState` expansion snapshots: `swift test --filter FeatureStateMacroTests`
- Run projection runtime tests: `swift test --filter '\.ProjectionTests'`, `swift test --filter ViewStateProjectionTests`, and `swift test --filter ViewStateCollectionTests`
- Run the core's behaviour suites: `swift test --filter '\.SchedulingTests'` (plain `SchedulingTests` also matches `ActorModelSchedulingTests`), `ModificationTests`, `CoreExitTests` and `ParallelismTests` (filtering it down to one variant skips the comparison). `--filter IsolationTests` runs only the three `*IsolationTests` regression suites.
- Run the effects, `ActorModel` and debounce suites: `swift test --filter '\.AutoCancelTests'`, `EffectIDTests`, `ActorModel` (the three `ActorModel*` suites) and `DebounceInteractorTests`
- Run the test-shell suites: `swift test --filter TestModel` and `swift test --filter TestViewModelTests`
- Run negative compile checks after `swift build`: `bash scripts/negative-compile-checks.sh` (CI runs it). The `-typecheck` lane asserts that `@Domain` members stay hidden and generic states are rejected; the `-emit-sil -wmo` lane (region isolation) asserts that `NO_SENDABLE_BASELINE` compiles with `-warnings-as-errors` and that `PERFORM_IN_EFFECT` and `MAINACTOR_INTERACTOR_TO_TESTMODEL` fail.

## Macro notes
- `@FeatureState` and `@Domain` are implemented in `Sources/LatticeMacros/Plugins/` (`FeatureStateMacro.swift`, `ObservationStateMacros.swift`, the `ViewState` projection in `FeatureStateMacro+ViewState.swift`, `ViewStateMember.swift` and `ViewStateRenderer.swift`, and `FeatureStateSupportMacros.swift`), declared in `Sources/Lattice/Macros.swift`, and registered in `Sources/LatticeMacros/Plugins/Plugin.swift`.
- Macro tests are `MacroTesting` snapshots (`assertMacro`); the extension role only expands with `MacroSpec(type:conformances:)`.
- Swift 6.4 compiler bug: a file that holds a `@FeatureState` enum together with other macro-annotated declarations (other `@FeatureState` types, `@CasePathable` enums, `@Observable` classes, `@Interactor` types, …) can crash the compiler (segfault in `TypeCheckPrimaryFileRequest`). Declare each `@FeatureState` enum, `@CasePathable` or not, in its own file with no other macro-annotated declaration; files whose `@FeatureState` types are all structs are not affected. This is a temporary workaround for the compiler bug, not a design rule.

## Macro binary refresh
- If macro sources change, rebuild the tool: `scripts/rebuild-macro.sh` builds the package in release and copies the `LatticeMacros` tool to `Macros/LatticeMacros`. The binary is not checked in; the podspec's `prepare_command` runs the same script at `pod install`.
- Set `SKIP_LATTICE_MACRO_BUILD=1` or `SKIP_LATTICE_MACRO_BUILD=true` to skip when needed.

## Skill sync
- Sync `skills/` and `.claude/skills/`: `scripts/sync-skills.sh`
- Sync uses newer file mtimes as source of truth.
- Deletions are removed manually on both sides.

## Formatting
- `swift-format` is used; pre-push hook auto-formats and commits changes in `Sources`/`Tests`.
- Do not run `swift-format` manually; rely on the pre-push hook.

## Skills
- lattice: Build Swift application features using Lattice interactors, effects, features, view models, and @FeatureState state. (file: skills/lattice/SKILL.md)
- lattice-case-paths: Ergonomic enum access and generic algorithms for Lattice actions and enum states using CasePaths. (file: skills/lattice-case-paths/SKILL.md)
- lattice-modern-swiftui: Build SwiftUI features with Lattice ViewModel, @Bindable bindings, clear view actions, and the task sendViewEvent returns. (file: skills/lattice-modern-swiftui/SKILL.md)
- lattice-observable-models: Move SwiftUI logic into Lattice interactors, effects and view models while keeping views thin. (file: skills/lattice-observable-models/SKILL.md)
- lattice-testing: Test Lattice features with TestModel and TestViewModel, exhaustivity, and a test-local gate clock. (file: skills/lattice-testing/SKILL.md)

## Notes for agents
- `Package.swift` is the only manifest and requires Swift 6.2 tools (`swift-tools-version: 6.2`). CI builds on GitHub's `xcode-27` runner image (Xcode 27, Swift 6.4).
- Keep Swift concurrency annotations consistent and avoid breaking API surface. The feature layer needs no `Sendable`: do not add `Sendable` constraints on `State`, `Action`, interactors, `Feature` or effect closures. `Core.startQueued` must create effect tasks in the `for` loop written directly in its `assumeIsolated` body; moving task creation into a nested closure (`map`, `forEach`, a helper) silently loses the shell's isolation after the first suspension.
- Update README/examples if public APIs or macros change.
- When updating release tags or creating GitHub releases, make sure `Lattice.podspec` has the matching `s.version` first.
- Keep `Lattice.podspec` in line with `Package.swift`: `s.swift_version` and `-enable-upcoming-feature NonisolatedNonsendingByDefault` in `OTHER_SWIFT_FLAGS`, and an `s.dependency` for every module `Sources/Lattice` imports outside `Testing/` (CasePaths, IdentifiedCollections, OrderedCollections, IssueReporting).
- CocoaPods runtime consumers do not use test helpers; keep `Sources/Lattice/Testing` excluded from `Lattice.podspec` unless adding a dedicated test-support pod.
