#!/bin/bash
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$PACKAGE_DIR/Tests/FeatureStateCompileFixtures"
LOG_DIR="${FEATURE_STATE_FIXTURE_LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/lattice-feature-state-fixtures.XXXXXX")}"
mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/results.txt"
: > "$SUMMARY"
swift --version | tee -a "$SUMMARY"

run() {
  local name="$1"
  shift
  printf '%q ' "$@" >> "$SUMMARY"
  printf '\n' >> "$SUMMARY"
  local result=0
  "$@" > "$LOG_DIR/$name.log" 2>&1 || result=$?
  echo "$name exit=$result" | tee -a "$SUMMARY"
  return "$result"
}

pass() {
  local name="$1"
  shift
  if ! run "$name" "$@"; then
    cat "$LOG_DIR/$name.log" >&2
    exit 1
  fi
  if grep -E 'warning:|error:' "$LOG_DIR/$name.log"; then
    echo "Unexpected diagnostic in positive fixture: $name" >&2
    exit 1
  fi
}

fail() {
  local name="$1" expected="$2"
  shift 2
  if run "$name" "$@"; then
    echo "Expected $name to fail" >&2
    exit 1
  fi
  if grep -E 'no such module|plugin.*not found|could not.*plugin|failed to load' "$LOG_DIR/$name.log"; then
    echo "Fixture setup failure: $name" >&2
    exit 1
  fi
  if ! grep -E "$expected" "$LOG_DIR/$name.log"; then
    cat "$LOG_DIR/$name.log" >&2
    echo "Missing intended diagnostic: $name" >&2
    exit 1
  fi
}

run build swift build --package-path "$PACKAGE_DIR"
BIN="$(swift build --package-path "$PACKAGE_DIR" --show-bin-path)"
MODULES="$BIN"
[[ ! -d "$BIN/Modules" ]] || MODULES="$BIN/Modules"
PLUGIN="$BIN/LatticeMacros-tool"
[[ -f "$PLUGIN" ]] || PLUGIN="$BIN/LatticeMacros"
[[ -f "$PLUGIN" ]] || { echo "Macro executable missing: $PLUGIN" >&2; exit 1; }
COMPILER=(swiftc -swift-version 6 -parse-as-library -I "$MODULES" -F "$BIN" -F "$BIN/PackageFrameworks" -load-plugin-executable "$PLUGIN#LatticeMacros")
DEFINITIONS="$FIXTURES/StateDefinitions.swift"

pass local "${COMPILER[@]}" -typecheck -module-name FeatureStateFixtureLocal -package-name FixturePackage "$DEFINITIONS" "$FIXTURES/ProjectionPass.swift"
for name in DOMAIN_ESCAPE PRIVATE_ESCAPE FILEPRIVATE_ESCAPE OPTIONAL_ESCAPE CASE_ESCAPE ROW_ESCAPE; do
  fail "$name" "has no dynamic member|has no member" "${COMPILER[@]}" -typecheck -module-name FeatureStateFixtureNegative -package-name FixturePackage -D "$name" "$DEFINITIONS" "$FIXTURES/ProjectionFailures.swift"
done
fail RAW_CHILD_ESCAPE "cannot convert|cannot assign" "${COMPILER[@]}" -typecheck -module-name FeatureStateFixtureNegative -package-name FixturePackage -D RAW_CHILD_ESCAPE "$DEFINITIONS" "$FIXTURES/ProjectionFailures.swift"
fail RAW_OPTIONAL_ESCAPE "cannot convert|cannot assign" "${COMPILER[@]}" -typecheck -module-name FeatureStateFixtureNegative -package-name FixturePackage -D RAW_OPTIONAL_ESCAPE "$DEFINITIONS" "$FIXTURES/ProjectionFailures.swift"
fail DESCRIPTOR_STORAGE_ESCAPE "'keyPath' is inaccessible due to 'internal' protection level" "${COMPILER[@]}" -typecheck -module-name FeatureStateFixtureNegative -package-name FixturePackage -D DESCRIPTOR_STORAGE_ESCAPE "$DEFINITIONS" "$FIXTURES/ProjectionFailures.swift"
fail COMPOSED_NAMESPACE_PATH "has no member 'secret'" "${COMPILER[@]}" -typecheck -module-name FeatureStateFixtureNegative -package-name FixturePackage -D COMPOSED_NAMESPACE_PATH "$DEFINITIONS" "$FIXTURES/ProjectionFailures.swift"

pass definitions "${COMPILER[@]}" -emit-module -module-name FeatureStateFixtureDefinitions -package-name FixturePackage "$DEFINITIONS" -emit-module-path "$LOG_DIR/FeatureStateFixtureDefinitions.swiftmodule"
pass external "${COMPILER[@]}" -typecheck -I "$LOG_DIR" -module-name FeatureStateFixtureExternal -package-name OtherPackage "$FIXTURES/ExternalClientPass.swift"
pass same-package "${COMPILER[@]}" -typecheck -I "$LOG_DIR" -module-name FeatureStateFixturePackageClient -package-name FixturePackage -D SAME_PACKAGE "$FIXTURES/ExternalClientPass.swift"
fail INTERNAL_ESCAPE "'moduleOnly' is inaccessible due to 'internal' protection level" "${COMPILER[@]}" -typecheck -I "$LOG_DIR" -module-name FeatureStateFixtureExternalNegative -package-name FixturePackage -D INTERNAL_ESCAPE "$FIXTURES/ExternalClientFailures.swift"
fail PACKAGE_ESCAPE "'packageOnly' is inaccessible due to 'package' protection level" "${COMPILER[@]}" -typecheck -I "$LOG_DIR" -module-name FeatureStateFixtureExternalNegative -package-name OtherPackage -D PACKAGE_ESCAPE "$FIXTURES/ExternalClientFailures.swift"
fail EXTERNAL_DOMAIN_ESCAPE "has no dynamic member|has no member" "${COMPILER[@]}" -typecheck -I "$LOG_DIR" -module-name FeatureStateFixtureExternalNegative -package-name OtherPackage -D EXTERNAL_DOMAIN_ESCAPE "$FIXTURES/ExternalClientFailures.swift"
fail EXTERNAL_RAW_ESCAPE "cannot convert|cannot assign" "${COMPILER[@]}" -typecheck -I "$LOG_DIR" -module-name FeatureStateFixtureExternalNegative -package-name OtherPackage -D EXTERNAL_RAW_ESCAPE "$FIXTURES/ExternalClientFailures.swift"
while IFS='|' read -r name expected; do
  fail "$name" "$expected" "${COMPILER[@]}" -typecheck -module-name FeatureStateMacroNegative -package-name FixturePackage -D "$name" "$DEFINITIONS" "$FIXTURES/MacroFailures.swift"
done <<'CASES'
MISSING_TYPE|explicit type annotation
CLASS_STATE|can only be attached to structs and enums
LAZY_PROPERTY|lazy properties are unsupported
SETTABLE_GETTER|synchronous, nonmutating, get-only
ASYNC_GETTER|synchronous, nonmutating, get-only
THROWING_GETTER|synchronous, nonmutating, get-only
MUTATING_GETTER|synchronous, nonmutating, get-only
CONDITIONAL_MEMBER|conditional member groups are unsupported
MEMBER_AVAILABILITY|member-specific availability are unsupported
PROPERTY_WRAPPER|property attributes/wrappers
GENERATED_COLLISION|generated-name collision
MULTI_PAYLOAD|multiple associated values require one payload struct
CASE_COLLISION|collides with an existing member
DOMAIN_OUTSIDE|requires an instance property
DOMAIN_STATIC|requires an instance property
NON_EQUATABLE_LEAF|leaf outputs must be Equatable
NON_EQUATABLE_COMPUTED_CHILD|computed feature outputs must be Equatable
NON_EQUATABLE_COMPUTED_OPTIONAL|computed feature outputs must be Equatable
DOMAIN_NESTED_OUTSIDE|requires an instance property
NON_SENDABLE_DOMAIN|non-Sendable type
ARRAY_FEATURE|standard containers of feature states are unsupported
OPTIONAL_ARRAY_FEATURE|standard containers of feature states are unsupported
DICTIONARY_FEATURE|standard containers of feature states are unsupported
SET_FEATURE|standard containers of feature states are unsupported
DERIVED_ARRAY_FEATURE|standard containers of feature states are unsupported
OPTIONAL_IDENTIFIED_FEATURE|standard containers of feature states are unsupported
DICTIONARY_KEY_FEATURE|standard containers of feature states are unsupported
DICTIONARY_BOTH_FEATURE|standard containers of feature states are unsupported
ALIASED_ARRAY_FEATURE|standard containers of feature states are unsupported
CASES

echo "PASS: FeatureState compiler fixtures; logs: $LOG_DIR" | tee -a "$SUMMARY"
