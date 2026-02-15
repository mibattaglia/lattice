# AGENTS

## Project Snapshot
- Lattice is a Swift 6 library (MVVM + unidirectional data flow) with macros.
- Targets: Lattice (library), LatticeMacros (macro plugin), tests in Tests/.
- Supported platforms: iOS 17+, macOS 14+, watchOS 10+.

## Layout
- `Sources/Lattice`: core runtime types (Interactor, ViewModel, emissions, testing helpers).
- `Sources/LatticeMacros`: macro definitions; build product used by library.
- `Macros/`: checked-in macro tool binary used by Xcode/tooling.
- `ExampleProject/`: sample Xcode project/workspace for manual validation.

## Main library concepts
- **Interactor**: mutates domain state from actions; returns `Emission<Action>`.
- **Emission**: `.none`, `.action`, `.perform` (async), `.observe` (async stream), `.merge`.
- **Debouncing**: `Emission.debounce(using:)` and `Interactors.Debounce` debounce effects while state mutations remain immediate.
- **Composition**: `Interactors.When` / `when(state:action:child:)` for child-feature scoping via key paths and case paths.
- **ViewModel**: bridges SwiftUI to Interactor; `sendViewEvent(_:)` returns `EventTask`.
- **Feature**: `Feature<Action, DomainState, ViewState>` bundles interactor + reducer + state equality strategy for `ViewModel<F>`.
- **ViewStateReducer**: maps domain state to view state; macro validates `initialViewState(for:)` or `DefaultValueProvider`.
- **ObservableState**: macro for view state observation conformance.
- **Testing**: `InteractorTestHarness`, `AsyncStreamRecorder`, `TestClock` for time control.

## Build & Test (CLI)
- Build all: `swift build`
- Run all tests: `swift test`
- Run macro tests only: `swift test --filter LatticeMacrosTests`
- Run library tests only: `swift test --filter LatticeTests`
- Run focused debounce tests: `swift test --filter EmissionDebounceTests` and `swift test --filter DebounceInteractorTests`

## Macro binary refresh
- If macro sources change, rebuild the tool and update `Macros/LatticeMacros`:
- `scripts/rebuild-macro.sh`
- Set `SKIP_LATTICE_MACRO_BUILD=1` or `SKIP_LATTICE_MACRO_BUILD=true` to skip when needed.

## Formatting
- `swift-format` is used; pre-push hook auto-formats and commits changes in `Sources`/`Tests`.
- Manual format: `swift-format format --in-place --recursive Sources Tests`

## Skills
- lattice: Build Swift application features using Lattice interactors, view models, and view state reducers. (file: skills/lattice/SKILL.md)
- lattice-case-paths: Ergonomic enum access and generic algorithms for Lattice actions and view state using CasePaths. (file: skills/lattice-case-paths/SKILL.md)
- lattice-modern-swiftui: Build SwiftUI features with Lattice ViewModel, @Bindable bindings, and clear view actions. (file: skills/lattice-modern-swiftui/SKILL.md)
- lattice-observable-models: Move SwiftUI logic into Lattice interactors and view models while keeping views thin. (file: skills/lattice-observable-models/SKILL.md)
- lattice-testing: Test Lattice interactors, emissions, and view models with InteractorTestHarness and TestClock. (file: skills/lattice-testing/SKILL.md)

## Notes for agents
- Prefer `Package.swift` for builds; `Package@swift-6.2.swift` exists for newer toolchains.
- Keep Swift concurrency annotations consistent (`Sendable`, `@MainActor`) and avoid breaking API surface.
- Update README/examples if public APIs or macros change.

## Claude Skills (project-scoped)
- Project skills live in `.claude/skills/`.
- Use `scripts/sync-skills.sh` to keep `skills/` and `.claude/skills/` in sync.
- Sync uses newer file mtimes as source of truth.
- Deletions are removed manually on both sides.
