# AGENTS

## Project Snapshot
- Lattice is a Swift 6 library (MVVM + unidirectional data flow) with macros.
- Targets: Lattice (library), LatticeMacros (macro plugin), tests in Tests/.
- Supported platforms: iOS 17+, macOS 14+, watchOS 10+.

## Layout
- `Sources/Lattice`: core runtime types (Interactor, FeatureState and its ViewState projection, ViewModel, emissions, testing helpers).
- `Sources/LatticeMacros`: macro definitions; build product used by library.
- `Macros/`: checked-in macro tool binary used by Xcode/tooling.
- `ExampleProject/`: sample Xcode project/workspace for manual validation.
- `Tests/NegativeCompileChecks`: fixtures type-checked by `scripts/negative-compile-checks.sh`; not a SwiftPM target.

## Main library concepts
- **FeatureState**: `@FeatureState` makes a struct or enum a feature's one state. Every stored member is observation-tracked, and a nested `ViewState` projection (a mirror enum for enum states) is what views read. `@Domain` hides a member from `ViewState` at compile time; it stays tracked.
- **Interactor**: the only mutator of a feature's state; returns `Emission<Action>`. Declared with `@Interactor<State, Action>`.
- **Emission**: `.none`, `.action`, `.perform` (async), `.observe` (async stream), `.merge`.
- **Debouncing**: `Emission.debounce(using:)` and `Interactors.Debounce` debounce effects while state mutations remain immediate.
- **Composition**: `Interactors.When` / `when(state:action:child:)` for child-feature scoping via key paths and case paths.
- **ViewModel**: bridges SwiftUI to Interactor; `ViewModel(initialState:feature:)`. Member reads (`viewModel.title`) go through `State.ViewState` and are fine-grained; `viewModel.viewState` is the coarse read. `sendViewEvent(_:)` returns `EventTask`.
- **Feature**: `Feature<Action, State>` bundles the interactor and an optional `areStatesEqual` (`==` for `Equatable` states) for `ViewModel<F>`.
- **ScopedViewModel**: `scope(state:action:)` projects a child, optional child, collection element or enum-case payload (`scopeIfActive`) for child views.
- **Testing**: `TestViewModel(initialState:feature:)` asserts on `state` with the feature's state equality; `TestEventTask`; `TestClock` (swift-clocks) for time control.

## Build & Test (CLI)
- Build all: `swift build`
- Run all tests: `swift test`
- Run macro tests only: `swift test --filter LatticeMacrosTests`
- Run library tests only: `swift test --filter LatticeTests`
- Run `@FeatureState` expansion snapshots: `swift test --filter FeatureStateMacroTests`
- Run projection runtime tests: `swift test --filter ProjectionTests`, `swift test --filter ViewStateProjectionTests`, and `swift test --filter ViewStateCollectionTests`
- Run negative compile checks after `swift build`: `bash scripts/negative-compile-checks.sh` (asserts that `@Domain` members stay hidden and generic states are rejected; CI runs it)
- Run focused debounce tests: `swift test --filter EmissionDebounceTests` and `swift test --filter DebounceInteractorTests`

## Macro notes
- `@FeatureState` and `@Domain` are implemented in `Sources/LatticeMacros/Plugins/` (`FeatureStateMacro.swift`, `ObservationStateMacros.swift`, the `ViewState` projection in `FeatureStateMacro+ViewState.swift`, `ViewStateMember.swift` and `ViewStateRenderer.swift`, and `FeatureStateSupportMacros.swift`), declared in `Sources/Lattice/Macros.swift`, and registered in `Sources/LatticeMacros/Plugins/Plugin.swift`.
- Macro tests are `MacroTesting` snapshots (`assertMacro`); the extension role only expands with `MacroSpec(type:conformances:)`.
- Swift 6.4 compiler bug: a file that holds a `@FeatureState` enum together with other macro-annotated declarations (other `@FeatureState` types, `@CasePathable` enums, `@Observable` classes, `@Interactor` types, …) can crash the compiler (segfault in `TypeCheckPrimaryFileRequest`). Declare each `@FeatureState` enum, `@CasePathable` or not, in its own file with no other macro-annotated declaration; files whose `@FeatureState` types are all structs are not affected. This is a temporary workaround for the compiler bug, not a design rule.

## Macro binary refresh
- If macro sources change, rebuild the tool and update `Macros/LatticeMacros`:
- `scripts/rebuild-macro.sh`
- Set `SKIP_LATTICE_MACRO_BUILD=1` or `SKIP_LATTICE_MACRO_BUILD=true` to skip when needed.

## Skill sync
- Sync `skills/` and `.claude/skills/`: `scripts/sync-skills.sh`
- Sync uses newer file mtimes as source of truth.
- Deletions are removed manually on both sides.

## Formatting
- `swift-format` is used; pre-push hook auto-formats and commits changes in `Sources`/`Tests`.
- Do not run `swift-format` manually; rely on the pre-push hook.

## Skills
- lattice: Build Swift application features using Lattice interactors, features, view models, and @FeatureState state. (file: skills/lattice/SKILL.md)
- lattice-case-paths: Ergonomic enum access and generic algorithms for Lattice actions and enum states using CasePaths. (file: skills/lattice-case-paths/SKILL.md)
- lattice-modern-swiftui: Build SwiftUI features with Lattice ViewModel, @Bindable bindings, and clear view actions. (file: skills/lattice-modern-swiftui/SKILL.md)
- lattice-observable-models: Move SwiftUI logic into Lattice interactors and view models while keeping views thin. (file: skills/lattice-observable-models/SKILL.md)
- lattice-testing: Test Lattice features with TestViewModel, TestEventTask, exhaustivity, and TestClock. (file: skills/lattice-testing/SKILL.md)

## Notes for agents
- `Package.swift` is the only manifest and requires Swift 6.2 tools (`swift-tools-version: 6.2`). CI builds with Xcode 26.4.1 (Swift 6.3.1).
- Keep Swift concurrency annotations consistent (`Sendable`, `@MainActor`) and avoid breaking API surface.
- Update README/examples if public APIs or macros change.
- When updating release tags or creating GitHub releases, make sure `Lattice.podspec` has the matching `s.version` first.
- CocoaPods runtime consumers do not use test helpers; keep `Sources/Lattice/Testing` excluded from `Lattice.podspec` unless adding a dedicated test-support pod.
