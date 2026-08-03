# 01 — Toolchain Floor: Swift 6.2, Upcoming Features, Podspec, Macro Binary

Workstream 1 of the Sendable-removal rework (see `README.md` in this directory). Everything in
plans 02–04 and 06–07 depends on the language semantics enabled here, so this lands first and alone: it
must build green against the **current** (pre-rework) sources before any runtime code changes.

## Overview

| Change | Decision |
|--------|----------|
| Manifest strategy | **Retire `Package@swift-6.2.swift`**: its content becomes the base `Package.swift` (tools 6.2), the variant file is deleted. |
| Upcoming features | `NonisolatedNonsendingByDefault` + `InferIsolatedConformances` on `Lattice`, `LatticeTests`, `LatticeMacrosTests` (not the macro target). |
| Podspec | `swift_version` → `'6.2'`; the same two upcoming-feature flags added to `OTHER_SWIFT_FLAGS` so CocoaPods builds compile with identical semantics. |
| Macro binary | **Never checked in.** `Macros/LatticeMacros` is generated on the *consumer's* machine: SwiftPM/Xcode consumers build the `.macro` target from source automatically; CocoaPods consumers generate it at `pod install` via `prepare_command` → `scripts/rebuild-macro.sh`. Maintainers run nothing. Fix stale AGENTS.md/CLAUDE.md wording; add `Macros/` to `.gitignore`. |
| CI | No change required — `.github/workflows/CI.yml` already selects Xcode 26.4.1 (Swift 6.3.1 ≥ 6.2). Documented below. |
| `Package.resolved` | Re-resolve; `originHash` changes because the manifest changes. Pins should be a no-op (already resolved via the 6.2 variant). |

### Why these two features are load-bearing (not just diagnostics)

- **`NonisolatedNonsendingByDefault`** ([SE-0461]): nonisolated `async` functions run in the
  *caller's* isolation domain instead of hopping to the global executor. This is the entire
  basis of the new effect runtime: `Effects.perform` closures are non-`@Sendable` `async`
  closures that must execute in the host's domain (MainActor today) without the state ever
  crossing an isolation boundary. Without this flag, every `await` inside an effect would hop
  off-domain and the non-Sendable-state design in `02-core-runtime.md` / `03-effects-handle.md`
  is unsound.
- **`InferIsolatedConformances`** ([SE-0470]): protocol conformances declared on
  `@MainActor`-isolated types are inferred `@MainActor`-isolated, so consumer `DomainState` /
  `ViewState` types and MainActor-hosted interactors conform to Lattice protocols without
  `Sendable`/`nonisolated` contortions.

TCA26 enables both (plus four others) on all non-test targets — see
`/Users/michaelbattaglia/Documents/pointfree/TCA26/Package.swift` lines 262–273:

```swift
for target in package.targets where !target.isTest {
  target.swiftSettings = target.swiftSettings ?? []
  target.swiftSettings?.append(contentsOf: [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  ])
}
```

We adopt **only** the two features the design contract requires. The other four are stylistic
hardening; adding them now would churn the pre-rework sources for zero design benefit
(`ExistentialAny` alone would touch dozens of files). Skipped deliberately; revisit in
workstream 8 if desired.

Unlike TCA26 we **do** enable the features on test targets (per the pinned contract): the new
snapshot-diff tests in `07-testing.md` exercise non-Sendable state through async effect
boundaries, and must compile under the same isolation semantics as the library. The
`LatticeMacros` target is excluded — it is host-toolchain plugin code operating on
already-Sendable swift-syntax values, and keeping its dialect stable avoids any behavioral
delta in the prebuilt plugin binary beyond the dependency bump.

### Why retire the variant manifest (not keep two)

- The version-suffixed manifest mechanism exists to serve *older* toolchains from
  `Package.swift`. With a 6.2 floor (decision of record), there is no older toolchain to serve.
- The two manifests have already drifted (swift-syntax `apple/…@601` vs `swiftlang/…@602`,
  different macro-target dependency lists). One file removes the drift class entirely.
- `Package.resolved` is already the 6.2-variant resolution (`swiftlang/swift-syntax` @ 602.0.0),
  so collapsing to one manifest causes no dependency churn for current developers or CI.

## File-by-file changes

### 1. `Package.swift` — replaced (becomes the 6.2 manifest + upcoming features)

The new content is the current `Package@swift-6.2.swift` with the tools declaration retained,
plus the upcoming-features loop appended. Shown first as a diff against the **current
`Package.swift`**, then in full.

```diff
--- a/Package.swift
+++ b/Package.swift
@@ -1,4 +1,4 @@
-// swift-tools-version: 6.0
+// swift-tools-version: 6.2
 
 import CompilerPluginSupport
 import PackageDescription
@@ -23,8 +23,8 @@ let package = Package(
             .upToNextMajor(from: "1.7.0")
         ),
         .package(
-            url: "https://github.com/apple/swift-syntax",
-            .upToNextMajor(from: "601.0.0")
+            url: "https://github.com/swiftlang/swift-syntax",
+            .upToNextMajor(from: "602.0.0")
         ),
         .package(
             url: "https://github.com/pointfreeco/swift-macro-testing",
@@ -63,8 +63,13 @@ let package = Package(
         .macro(
             name: "LatticeMacros",
             dependencies: [
-                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                 .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
+                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
+                .product(name: "SwiftOperators", package: "swift-syntax"),
+                .product(name: "SwiftSyntax", package: "swift-syntax"),
+                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
+                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
+                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
             ]
         ),
         .testTarget(
@@ -79,8 +84,17 @@ let package = Package(
             dependencies: [
                 "LatticeMacros",
                 .product(name: "MacroTesting", package: "swift-macro-testing"),
+                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
             ]
         ),
     ],
     swiftLanguageModes: [.v6]
 )
+
+for target in package.targets where target.type != .macro {
+    target.swiftSettings = target.swiftSettings ?? []
+    target.swiftSettings?.append(contentsOf: [
+        .enableUpcomingFeature("InferIsolatedConformances"),
+        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
+    ])
+}
```

Full new `Package.swift`:

```swift
// swift-tools-version: 6.2

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "swift-lattice",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(
            name: "Lattice",
            targets: ["Lattice"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-async-algorithms",
            .upToNextMajor(from: "1.0.0")
        ),
        .package(
            url: "https://github.com/pointfreeco/combine-schedulers",
            .upToNextMajor(from: "1.0.3")
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-case-paths",
            .upToNextMajor(from: "1.7.0")
        ),
        .package(
            url: "https://github.com/swiftlang/swift-syntax",
            .upToNextMajor(from: "602.0.0")
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-macro-testing",
            from: "0.2.0"
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-clocks",
            .upToNextMajor(from: "1.0.0")
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-custom-dump",
            from: "1.0.0"
        ),
        .package(
            url: "https://github.com/pointfreeco/xctest-dynamic-overlay",
            from: "1.0.0"
        ),
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),
        .package(url: "https://github.com/pointfreeco/swift-identified-collections", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "Lattice",
            dependencies: [
                "LatticeMacros",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "CombineSchedulers", package: "combine-schedulers"),
                .product(name: "CasePaths", package: "swift-case-paths"),
                .product(name: "Clocks", package: "swift-clocks"),
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(name: "IssueReporting", package: "xctest-dynamic-overlay"),
                .product(name: "IdentifiedCollections", package: "swift-identified-collections"),
                .product(name: "OrderedCollections", package: "swift-collections"),
            ]
        ),
        .macro(
            name: "LatticeMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "LatticeTests",
            dependencies: [
                "Lattice",
                .product(name: "IssueReporting", package: "xctest-dynamic-overlay"),
                .product(name: "IssueReportingTestSupport", package: "xctest-dynamic-overlay"),
            ]
        ),
        .testTarget(
            name: "LatticeMacrosTests",
            dependencies: [
                "LatticeMacros",
                .product(name: "MacroTesting", package: "swift-macro-testing"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

for target in package.targets where target.type != .macro {
    target.swiftSettings = target.swiftSettings ?? []
    target.swiftSettings?.append(contentsOf: [
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    ])
}
```

Notes:
- Dependency list is intentionally untouched. `AsyncAlgorithms` / `CombineSchedulers` likely
  become removable once `Emission`/`Debouncer` are deleted — that pruning belongs to
  workstreams 4 and 8, not here.
- `swiftLanguageModes: [.v6]` stays; both upcoming features are additive on top of Swift 6 mode
  and become default only in a future major language mode.

### 2. `Package@swift-6.2.swift` — deleted

```diff
--- a/Package@swift-6.2.swift
+++ /dev/null
```

(Entire file removed; its content, verified identical modulo the appended feature loop, now
lives in `Package.swift` above.)

```bash
git rm "Package@swift-6.2.swift"
```

### 3. `Package.resolved` — regenerated

Run `swift package resolve` after the manifest change. Expected delta: **`originHash` only**
(it hashes the manifest). All pins stay put because the current resolved file was already
produced against the 6.2 variant (`swiftlang/swift-syntax` @ 602.0.0 is already pinned).
Commit the regenerated file. If any pin other than `originHash` moves, stop and inspect —
that would mean local state had drifted from the 6.2 variant.

### 4. `Lattice.podspec` — swift_version sync + matching feature flags

CocoaPods compiles `Sources/Lattice/**` directly with the flags in `pod_target_xcconfig`; it
never reads `Package.swift`. If the pod build lacks the two upcoming features, effect closures
would compile with *different isolation semantics* than the SPM build — a correctness split,
not a style one. So the flags are mirrored here.

```diff
--- a/Lattice.podspec
+++ b/Lattice.podspec
@@ -9,7 +9,7 @@ Pod::Spec.new do |s|
   s.license        = { type: 'MIT' }
   s.platforms      = { ios: '17.0', macos: '14.0', watchos: '10.0' }
   s.source         = { git: 'https://github.com/mibattaglia/lattice.git', tag: s.version.to_s }
-  s.swift_version  = '6.0'
+  s.swift_version  = '6.2'
 
   s.static_framework = true
 
@@ -27,7 +27,7 @@ Pod::Spec.new do |s|
   # Configure build flags to load the macro plugin
   s.pod_target_xcconfig = {
     'DEFINES_MODULE' => 'YES',
-    'OTHER_SWIFT_FLAGS' => '-load-plugin-executable ${PODS_TARGET_SRCROOT}/Macros/LatticeMacros#LatticeMacros'
+    'OTHER_SWIFT_FLAGS' => '-load-plugin-executable ${PODS_TARGET_SRCROOT}/Macros/LatticeMacros#LatticeMacros -enable-upcoming-feature InferIsolatedConformances -enable-upcoming-feature NonisolatedNonsendingByDefault'
   }
 
   # For the main app target (if it uses macros directly)
```

Notes:
- `s.version` stays `0.3.1` here. The major-version bump is workstream 8's release step
  (AGENTS.md: podspec version must match the release tag, and no rework tag exists yet).
- `user_target_xcconfig` is deliberately **not** given the feature flags: forcing upcoming
  features onto the consumer's app target is not ours to decide. Consumer-facing isolation
  guidance is a `09-docs-release.md` migration-guide item.
- Dependencies section untouched (pruning is workstream 8).

### 5. `scripts/rebuild-macro.sh` — no change; no maintainer step

The script (verified current content) builds with the local toolchain via `swift build -c
release` and copies `LatticeMacros-tool` to `Macros/LatticeMacros`. **It exists for CocoaPods
consumers**, who run it implicitly at `pod install` time via the podspec's `prepare_command`
— after cloning, on their own toolchain. It needs no edits:

- After the manifest change, `swift build` on a `< 6.2` toolchain fails with SwiftPM's explicit
  "requires a minimum Swift tools version of 6.2" error — already a clear failure mode, no
  guard needed. (Consequence for pod consumers: `pod install` now requires a 6.2+ toolchain.)
- The macro target is excluded from the feature loop, so the plugin sources compile as before;
  only its swift-syntax dependency moves 601 → 602 — which consumers pick up automatically on
  their next `pod install`, since the binary is always built fresh from the cloned sources.

**No maintainer rebuild step and no committed binary.** SwiftPM/Xcode consumers never touch the
binary at all: `LatticeMacros` is a `.macro` target, built from source and linked by the build
system. `Macros/` is a consumer-side build artifact only.

Repository cleanups in this workstream's commit:

- **AGENTS.md / CLAUDE.md**: the `Macros/: checked-in macro tool binary used by Xcode/tooling`
  layout line and the "Macro binary refresh" section describe a contract that does not exist
  (the file has never been in the index). Rewrite both to state: macro is a source-built
  target; `Macros/LatticeMacros` is generated by pod consumers at `pod install` via
  `prepare_command`; maintainers never rebuild or commit it.
- **`.gitignore`**: add `Macros/` so a locally generated binary (e.g. from testing the pod
  flow) can never be committed accidentally.

### 6. `.github/workflows/CI.yml` — no change

Verified current workflow: `macos-latest`, explicit `sudo xcode-select -s
/Applications/Xcode_26.4.1.app` (Swift 6.3.1), then `swift build --build-tests` +
`swift test --skip-build`. Swift 6.3.1 satisfies the 6.2 tools floor and supports both upcoming
feature flags. Implication to record (in `09-docs-release.md` README updates): **minimum
supported development toolchain is now Xcode 26 / Swift 6.2**; older Xcode installs can no
longer build the package at all, whereas previously the 6.0 base manifest served them.

The existing build+test job is itself the acceptance gate that the feature flags don't break
the pre-rework sources (see below — they may; that's the point of gating).

## Execution order

1. Replace `Package.swift` with the content above; `git rm "Package@swift-6.2.swift"`.
2. `swift package resolve`; verify only `originHash` changed in `Package.resolved`.
3. `swift build` — expect possible new diagnostics from the two upcoming features against the
   *current* sources (see Risks). Fix-forward only mechanical breaks (e.g., a conformance that
   must be marked `nonisolated`); anything structural waits for workstream 2's rewrite and gets
   escalated instead.
4. `swift test` — full suite green.
5. Update AGENTS.md/CLAUDE.md macro wording and add `Macros/` to `.gitignore` (see §5). No
   binary is built or committed. Optional gate: `bash scripts/rebuild-macro.sh && lipo -info
   Macros/LatticeMacros` to verify the pod consumers' `prepare_command` path still works on the
   6.2 manifest, then delete the artifact.
6. Apply the podspec diff; `pod lib lint` (or at minimum `pod ipc spec Lattice.podspec` for
   syntax) if CocoaPods is available locally.
7. Commit; CI (push to main) re-validates on Xcode 26.4.1.

## Acceptance gates

All must pass before workstream 2 starts:

```bash
# Manifest sanity: exactly one manifest, tools 6.2
test ! -f "Package@swift-6.2.swift"
head -1 Package.swift | grep -q "swift-tools-version: 6.2"

# Flags actually reach the compiler for library + test targets
swift build --verbose 2>&1 | grep -q "enable-upcoming-feature NonisolatedNonsendingByDefault"
swift build --verbose 2>&1 | grep -q "enable-upcoming-feature InferIsolatedConformances"

# Full build + tests under the new dialect
swift build --build-tests
swift test
swift test --filter LatticeMacrosTests   # macro plugin healthy on swift-syntax 602
swift test --filter LatticeTests

# Macro binary regenerated and runnable
scripts/rebuild-macro.sh
test -x Macros/LatticeMacros
lipo -info Macros/LatticeMacros

# Podspec consistency
grep -q "s.swift_version  = '6.2'" Lattice.podspec
grep -q "enable-upcoming-feature NonisolatedNonsendingByDefault" Lattice.podspec
grep -q "enable-upcoming-feature InferIsolatedConformances" Lattice.podspec

# Resolved-file hygiene: pins unchanged (originHash may differ)
git diff Package.resolved | grep '^[+-] ' | grep -v originHash | grep -v '^[+-][+-]' \
  && { echo "unexpected pin drift"; exit 1; } || echo "pins stable"
```

Do **not** run `swift-format` manually (pre-push hook owns it, per AGENTS.md).

## Risks

| Risk | Severity | Mitigation |
|------|----------|-----------|
| `NonisolatedNonsendingByDefault` changes runtime behavior of *existing* nonisolated async functions (they now run in the caller's isolation) — pre-rework `Emission`/`Debouncer` internals could deadlock or behave differently under test. | **High** | Gate on the full existing test suite (step 4). These files are all deleted in workstreams 2–4, so any fix here is a temporary shim at most; if a fix is non-mechanical, escalate rather than patch deeply. |
| `InferIsolatedConformances` makes some existing conformances MainActor-isolated where nonisolated was assumed, producing new errors in `Sources/Lattice` or tests. | Medium | Mechanical fix: annotate the specific conformance `nonisolated` (SE-0470's opt-out). Expected blast radius is small since the library currently avoids MainActor-isolated conforming types. |
| swift-syntax 601 → 602 as the *only* resolution (older-toolchain path gone) breaks macro expansion or `MacroTesting` fixtures. | Low | `Package.resolved` already pins 602 and `LatticeMacrosTests` currently passes against it; gate re-runs the filter explicitly. |
| Pod consumers on Xcode < 26 can no longer `pod install` (prepare_command builds with tools 6.2; `swift_version 6.2` also requires it). | Medium | Deliberate floor per decision of record. Migration-guide callout in workstream 8. Error message from SwiftPM is self-explanatory. |
| `-enable-upcoming-feature` flags in `OTHER_SWIFT_FLAGS` rejected by consumer's older Swift compiler. | Low | Same floor as above — any compiler new enough for `swift_version 6.2` accepts both flags. |
| Committing `Macros/LatticeMacros` (option (a)) adds a multi-MB binary to git history on every macro change. | Low | Accepted trade-off matching existing documented workflow; revisit if repo size becomes a problem (e.g., release-asset download instead). |
| `apple/swift-syntax` vs `swiftlang/swift-syntax` URL identity: consumers of Lattice-as-dependency who also depend on `apple/swift-syntax` could hit SwiftPM "same package different URL" conflicts. | Low | GitHub redirects `apple/…` → `swiftlang/…` and SwiftPM canonicalizes the identity (`swift-syntax` in both); already the status quo for anyone building via the 6.2 variant today. |

[SE-0461]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md
[SE-0470]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0470-isolated-conformances.md
