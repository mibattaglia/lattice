# AGENTS

## Project Snapshot
- Lattice is a Swift library (MVVM + unidirectional data flow) with macros.
- Targets: Lattice (library), LatticeMacros (macro plugin), tests in Tests/.
- Toolchain floor: Swift 6.2 / Xcode 26. Supported platforms: iOS 17+, macOS 14+, watchOS 10+.

## Layout
- `Sources/Lattice`: core runtime (interactors, effects, feature state, view model, testing helpers).
- `Sources/LatticeMacros`: macro definitions; build product used by library.
- `Macros/`: gitignored, consumer-side build artifact (CocoaPods `pod install` generates the macro binary here; never checked in).
- `ExampleProject/`: sample Xcode project/workspace for manual validation.

## Main library concepts
- **Interactor**: `interact(state:action:effects:)` mutates domain state synchronously and launches effects; returns `Void`.
- **Effects**: `effects.perform` launches async work during the update phase; the effect re-enters via `effectState.modify` / `effectState.send` / `effectState.state`. Per-call-site task auto-replacement; `@EffectID` for explicit cancel/await.
- **Debouncing**: no debounce API — task replacement at a `perform` call site plus a leading `clock.sleep` is the debounce idiom.
- **Composition**: `Interactors.When` / `when(state:action:child:)` for child-feature scoping via key paths and case paths; a departed scope cancels child effects and drops straggler writes.
- **Feature state**: one `@FeatureState` type per feature; `@Domain` marks interactor-only members; visible computed properties are derived view output; the generated `_commit` diffs per member at commit.
- **ViewModel**: thin main-actor host; views read visible members through the generated projection (`viewModel.someLabel`); `sendViewEvent(_:)` returns `EventTask`.
- **Feature**: `Feature<State, Action>` bundles an erased interactor; `ViewModel(initialState:interactor:)` works without it.
- **Testing**: snapshot-diff `TestViewModel` (`send(_:changes:)`, `expect(timeout:changes:)`, `receive`, `skipPendingCommits()`, `dismount()`), `TestClock` for time control.

## Build & Test (CLI)
- Build all: `swift build`
- Run all tests: `swift test`
- Run macro tests only: `swift test --filter LatticeMacrosTests`
- Run library tests only: `swift test --filter LatticeTests`
- Run focused effect suites: `swift test --filter EffectsHandleTests`, `swift test --filter EffectCancellationTests`, `swift test --filter EffectIDTests`, `swift test --filter ScopedEffectsTests`, `swift test --filter InteractorGraphPathTests`

## Macro binary
- Never checked in and never rebuilt by maintainers. SwiftPM/Xcode consumers build the `LatticeMacros` target from source; the build system handles linking.
- CocoaPods consumers generate `Macros/LatticeMacros` at `pod install` via the podspec `prepare_command` (`scripts/rebuild-macro.sh`).
- `SKIP_LATTICE_MACRO_BUILD=1` or `SKIP_LATTICE_MACRO_BUILD=true` skips the script when needed.

## Skill sync
- Sync `skills/` and `.claude/skills/`: `scripts/sync-skills.sh`
- Sync uses newer file mtimes as source of truth.
- Deletions are removed manually on both sides.

## Formatting
- `swift-format` is used; pre-push hook auto-formats and commits changes in `Sources`/`Tests`.
- Do not run `swift-format` manually; rely on the pre-push hook.

## Skills
- lattice: Build Swift application features using Lattice interactors, view models, and feature state projections. (file: skills/lattice/SKILL.md)
- lattice-case-paths: Ergonomic enum access and generic algorithms for Lattice actions and feature state using CasePaths. (file: skills/lattice-case-paths/SKILL.md)
- lattice-modern-swiftui: Build SwiftUI features with Lattice ViewModel, @Bindable bindings, and clear view actions. (file: skills/lattice-modern-swiftui/SKILL.md)
- lattice-observable-models: Move SwiftUI logic into Lattice interactors and view models while keeping views thin. (file: skills/lattice-observable-models/SKILL.md)
- lattice-testing: Test Lattice features with snapshot-diff TestViewModel assertions and TestClock. (file: skills/lattice-testing/SKILL.md)

## Notes for agents
- Prefer `Package.swift` for builds.
- Toolchain floor is Swift 6.2 / Xcode 26 (upcoming features `InferIsolatedConformances` and `NonisolatedNonsendingByDefault` are enabled).
- Library and consumer types do not need `Sendable`; keep `@MainActor` annotations consistent and avoid breaking API surface.
- Update README/examples if public APIs or macros change.
- When updating release tags or creating GitHub releases, make sure `Lattice.podspec` has the matching `s.version` first.
- CocoaPods runtime consumers do not use test helpers; keep `Sources/Lattice/Testing` excluded from `Lattice.podspec` unless adding a dedicated test-support pod.
