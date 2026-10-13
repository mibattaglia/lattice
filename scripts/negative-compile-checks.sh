#!/bin/bash
# Negative compile checks for `@FeatureState` hiding (specs/plans/unified-feature-state.md §8).
#
# Type-checks the fixture files in Tests/NegativeCompileChecks against the built Lattice module: once
# with no flag (BASELINE, must compile) and once per flag below (must fail with the listed diagnostic).
# A `@FeatureState` enum gets its own fixture file (specs/plans/unified-feature-state.md §10).
# Run after `swift build`; paths come from `swift build --show-bin-path`. Pass the same build options
# in SWIFT_BUILD_FLAGS when the build used non-default ones (for example `--scratch-path <dir>`).
set -uo pipefail

cd "$(dirname "$0")/.."

FIXTURES=(Tests/NegativeCompileChecks/*.swift)
read -r -a BUILD_FLAGS <<<"${SWIFT_BUILD_FLAGS:-}"
BIN_PATH="$(swift build ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} --show-bin-path)"

# The native build system names macro executables `<name>-tool` and puts modules in `Modules/`.
plugin() {
  local candidate
  for candidate in "$BIN_PATH/$1-tool" "$BIN_PATH/$1"; do
    if [[ -f "$candidate" && -x "$candidate" ]]; then
      echo "$candidate#$1"
      return 0
    fi
  done
  echo "error: macro plugin '$1' not found in $BIN_PATH; run 'swift build' first" >&2
  return 1
}

LATTICE_MACROS="$(plugin LatticeMacros)" || exit 1
CASE_PATHS_MACROS="$(plugin CasePathsMacros)" || exit 1
SEARCH_PATHS=(-I "$BIN_PATH")
if [[ -d "$BIN_PATH/Modules" ]]; then
  SEARCH_PATHS+=(-I "$BIN_PATH/Modules")
fi

typecheck() {
  swiftc -typecheck -swift-version 6 "${SEARCH_PATHS[@]}" \
    -load-plugin-executable "$LATTICE_MACROS" \
    -load-plugin-executable "$CASE_PATHS_MACROS" \
    "$@" "${FIXTURES[@]}" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g'
  return "${PIPESTATUS[0]}"
}

DOMAIN_MESSAGE="is @Domain state and is not visible to views"

# FLAG|expected diagnostic substring
#
# Phase 2 must extend the flags marked (P2) to the ViewModel-side API once it reads through
# `State.ViewState`; today they exercise the generated projection directly or a stand-in in the
# fixture (`ScopedRead`, `BindingPaths`):
#   LEAK_ROOT      (P2) add `viewModel.lastUpdatedAt`
#   LEAK_KEYPATH   (P2) add a `viewModel.scope(state:)` / binding key path to a `@Domain` member
#   LEAK_BINDING   (P2) replace the stand-in with `$viewModel.lastUpdatedAt.sending(\.lastUpdatedAtChanged)`
#   LEAK_SCOPED    (P2) replace the stand-in with `ScopedViewModel` member access
#   LEAK_CASE      (P2) add `$viewModel.loaded.etag.sending(...)` through the case binding
#   LEAK_RAW_STATE (P2) add `viewModel.state` (internal to Lattice)
CHECKS=(
  "LEAK_ROOT|'lastUpdatedAt' is unavailable: 'lastUpdatedAt' $DOMAIN_MESSAGE"
  "LEAK_NESTED|'secretThreshold' is unavailable: 'secretThreshold' $DOMAIN_MESSAGE"
  "LEAK_OPTIONAL|'secretThreshold' is unavailable: 'secretThreshold' $DOMAIN_MESSAGE"
  "LEAK_COLLECTION|'secretThreshold' is unavailable: 'secretThreshold' $DOMAIN_MESSAGE"
  "LEAK_KEYPATH|'nonce' is unavailable: 'nonce' $DOMAIN_MESSAGE"
  "LEAK_BINDING|'lastUpdatedAt' is unavailable: 'lastUpdatedAt' $DOMAIN_MESSAGE"
  "LEAK_SCOPED|'secretThreshold' is unavailable: 'secretThreshold' $DOMAIN_MESSAGE"
  "LEAK_CASE|'etag' is unavailable: 'etag' $DOMAIN_MESSAGE"
  "LEAK_RAW_STATE|'_state' is inaccessible due to '@_spi' protection level"
  "GENERIC_STATE|'@FeatureState' cannot be applied to generic type 'GenericState'"
)

failures=0

output="$(typecheck)"
if [[ $? -eq 0 ]]; then
  echo "ok   BASELINE compiles"
else
  echo "FAIL BASELINE does not compile:"
  grep -E "error:" <<<"$output" | sed 's/^/       /'
  failures=$((failures + 1))
fi

for check in "${CHECKS[@]}"; do
  flag="${check%%|*}"
  expected="${check#*|}"
  output="$(typecheck -D "$flag")"
  status=$?
  if [[ $status -eq 0 ]]; then
    echo "FAIL $flag compiled; expected: $expected"
    failures=$((failures + 1))
  elif ! grep -qF -- "$expected" <<<"$output"; then
    echo "FAIL $flag (exit $status) without the expected diagnostic: $expected"
    grep -E "error:" <<<"$output" | sed 's/^/       /'
    failures=$((failures + 1))
  else
    echo "ok   $flag rejected: $expected"
  fi
done

if [[ $failures -ne 0 ]]; then
  echo "$failures negative compile check(s) failed"
  exit 1
fi
echo "All negative compile checks passed (BASELINE + ${#CHECKS[@]} flags)"
