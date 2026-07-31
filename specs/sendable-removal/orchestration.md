# Orchestration

How the plans in this directory land: strictly sequential, as a stacked branch chain, with
plan 09 at the tip as the integration/testing surface.

## Order

```
01 → 05 (phase A, then B) → 02 → 03 → 04 → 06 → 07 → 09
```

- 05 lands before 02 deliberately: phases A/B are additive and core-independent (stub host),
  and they validate the riskiest design bets (overload ranking, key-path keying, raw
  `ObservationRegistrar` interop) before the core rewrite sits on top of them.
- 08 has no branch: its macro work is 05 phase B; the residual audit rides with 09.
- 10 is future work, not in the chain.

## Branch topology

Each branch is a child of the previous plan's branch; 09 is the tip:

```
main
└── sendable-removal/01-toolchain
    └── sendable-removal/05-feature-state
        └── sendable-removal/02-core-runtime
            └── sendable-removal/03-effects-handle
                └── sendable-removal/04-interactor-combinators
                    └── sendable-removal/06-viewmodel
                        └── sendable-removal/07-testing
                            └── sendable-removal/09-docs-release   ← tip; test here
```

- End-to-end validation (ExampleProject pass, full `swift test`, migration-guide dry run)
  happens on `09-docs-release`, which contains the entire stack.
- Fixes to an earlier plan go on that plan's branch, then rebase the descendants in order
  (`git rebase --update-refs` from the tip does the whole cascade in one command).
- Merge to main only when the stack is done, in order, `--first-parent` history reading as
  the plan sequence.

## Per-branch rules

- **Gate before stacking.** A branch must pass its plan's acceptance gate (see each plan's
  final section) before the next branch is cut from it. Plans 01–05 additionally keep the
  *old* test suite green — everything before 06 is additive.
- **06 splits its diff**: one commit for the new ViewModel host wiring, a separate commit for
  the §10 deletion table, so the reviewable change isn't buried under mechanical red lines.
- **05 splits by phase**: phase A (runtime types + hand expansions) commits first; the
  phase B commit replacing hand expansions with the real macro must leave
  `FeatureStateRuntimeTests` untouched, proving behavior-neutral expansion.
- **Spec deviations amend the spec in the same commit.** The README requires spec-first
  changes; doing it atomically means no commit where code and spec disagree.
- Commit messages reference the plan and section: `[05A] FeatureState runtime types (§3)`.
