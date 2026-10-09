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
if [[ -n "${FEATURE_STATE_MACRO_BINARY:-}" ]]; then
  PLUGIN="$FEATURE_STATE_MACRO_BINARY"
else
  PLUGIN="$BIN/LatticeMacros-tool"
  [[ -f "$PLUGIN" ]] || PLUGIN="$BIN/LatticeMacros"
fi
[[ -f "$PLUGIN" ]] || { echo "Macro executable missing: $PLUGIN" >&2; exit 1; }
CASE_PLUGIN="$BIN/CasePathsMacros-tool"
[[ -f "$CASE_PLUGIN" ]] || CASE_PLUGIN="$BIN/CasePathsMacros"
[[ -f "$CASE_PLUGIN" ]] || { echo "Macro executable missing: $CASE_PLUGIN" >&2; exit 1; }
COMPILER=(swiftc -swift-version 6 -parse-as-library -I "$MODULES" -F "$BIN" -F "$BIN/PackageFrameworks" -load-plugin-executable "$PLUGIN#LatticeMacros" -load-plugin-executable "$CASE_PLUGIN#CasePathsMacros")
DEFINITIONS="$FIXTURES/StateDefinitions.swift"

fail unannotated-main-actor-client "main actor-isolated conformance.*cannot satisfy conformance requirement for a 'Sendable' type parameter" "${COMPILER[@]}" -default-isolation MainActor -typecheck -module-name FeatureStateUnannotatedClient -package-name FixturePackage "$DEFINITIONS"

for variant in normal main-actor-default; do
  CLIENT_COMPILER=("${COMPILER[@]}")
  CLIENT_DEFINITIONS="$DEFINITIONS"
  DEST="$LOG_DIR/$variant"
  mkdir -p "$DEST"
  if [[ "$variant" == main-actor-default ]]; then
    CLIENT_COMPILER+=(-default-isolation MainActor)
    CLIENT_DEFINITIONS="$DEST/StateDefinitions.swift"
    # Only client state/action/interactor declarations opt out. The module and
    # UI still default to MainActor; production flags and macro policy are unchanged.
    sed -E 's/public (struct|enum) /nonisolated public \1 /g' "$DEFINITIONS" > "$CLIENT_DEFINITIONS"
  fi
  pass "$variant-local" "${CLIENT_COMPILER[@]}" -typecheck -module-name FeatureStateFixtureLocal -package-name FixturePackage "$CLIENT_DEFINITIONS" "$FIXTURES/ProjectionPass.swift"
  while IFS='|' read -r name expected; do
    fail "$variant-$name" "$expected" "${CLIENT_COMPILER[@]}" -typecheck -module-name FeatureStateFixtureNegative -package-name FixturePackage -D "$name" "$CLIENT_DEFINITIONS" "$FIXTURES/ProjectionFailures.swift"
  done <<'CASES'
DOMAIN_ESCAPE|has no dynamic member|has no member
PRIVATE_ESCAPE|has no dynamic member|has no member
FILEPRIVATE_ESCAPE|has no dynamic member|has no member
OPTIONAL_ESCAPE|has no dynamic member|has no member
CASE_ESCAPE|has no dynamic member|has no member
ROW_ESCAPE|has no dynamic member|has no member
ROW_PRIVATE_ESCAPE|has no dynamic member|has no member
ROW_FILEPRIVATE_ESCAPE|has no dynamic member|has no member
RAW_STATE_ESCAPE|has no dynamic member|has no member
RAW_VIEW_STATE_ESCAPE|has no dynamic member 'viewState'|requires that.*conform to 'ObservableState'
RAW_SCOPE_STATE_ESCAPE|has no dynamic member 'viewState'|requires that.*conform to 'ObservableState'
RAW_CHILD_ESCAPE|cannot convert|cannot assign
RAW_OPTIONAL_ESCAPE|cannot convert|cannot assign
RAW_ARRAY_ESCAPE|cannot convert|cannot assign
RAW_ROW_ESCAPE|cannot convert|cannot assign
RAW_COLLECTION_COERCION|requires that the types 'FixtureRow' and 'ScopedViewModelCollection
TRANSPARENT_CHILD_ESCAPE|no exact matches|requires that.*conform to 'ObservableState'
RAW_READ_CLOSURE_ESCAPE|has no dynamic member|has no member|cannot call value
DESCRIPTOR_STORAGE_ESCAPE|'keyPath' is inaccessible due to 'internal' protection level
DESCRIPTOR_GETTER_ESCAPE|'read' is inaccessible due to 'internal' protection level
COMPOSED_NAMESPACE_PATH|has no member 'secret'
RAW_BINDING_ESCAPE|cannot convert|no exact matches
HIDDEN_BINDING_ESCAPE|has no member 'hiddenCount'
RAW_BINDABLE_ESCAPE|cannot convert value of type.*KeyPath<FixtureRoot|requires that.*conform to 'ObservableState'
RAW_BINDING_MODEL_ESCAPE|cannot convert value of type.*KeyPath<FixtureRoot|requires that.*conform to 'ObservableState'
RAW_ROW_BINDING_ESCAPE|has no dynamic member|has no member
SCOPED_HIDDEN_BINDING_ESCAPE|has no member 'secret'
CASES

  pass "$variant-definitions" "${CLIENT_COMPILER[@]}" -emit-module -module-name FeatureStateFixtureDefinitions -package-name FixturePackage "$CLIENT_DEFINITIONS" -emit-module-path "$DEST/FeatureStateFixtureDefinitions.swiftmodule"
  pass "$variant-external" "${CLIENT_COMPILER[@]}" -typecheck -I "$DEST" -module-name FeatureStateFixtureExternal -package-name OtherPackage "$FIXTURES/ExternalClientPass.swift"
  pass "$variant-same-package" "${CLIENT_COMPILER[@]}" -typecheck -I "$DEST" -module-name FeatureStateFixturePackageClient -package-name FixturePackage -D SAME_PACKAGE "$FIXTURES/ExternalClientPass.swift"
  while IFS='|' read -r name package expected; do
    fail "$variant-$name" "$expected" "${CLIENT_COMPILER[@]}" -typecheck -I "$DEST" -module-name FeatureStateFixtureExternalNegative -package-name "$package" -D "$name" "$FIXTURES/ExternalClientFailures.swift"
  done <<'CASES'
INTERNAL_ESCAPE|FixturePackage|'moduleOnly' is inaccessible due to 'internal' protection level
PACKAGE_ESCAPE|OtherPackage|'packageOnly' is inaccessible due to 'package' protection level
ROW_INTERNAL_ESCAPE|FixturePackage|'moduleOnly' is inaccessible due to 'internal' protection level
ROW_PACKAGE_ESCAPE|OtherPackage|'packageOnly' is inaccessible due to 'package' protection level
EXTERNAL_DOMAIN_ESCAPE|OtherPackage|has no dynamic member|has no member
EXTERNAL_RAW_ESCAPE|OtherPackage|cannot convert|cannot assign
EXTERNAL_RAW_ARRAY_ESCAPE|OtherPackage|cannot convert|cannot assign
EXTERNAL_RAW_ROW_ESCAPE|OtherPackage|cannot convert|cannot assign
EXTERNAL_ROW_PRIVATE_ESCAPE|OtherPackage|has no dynamic member|has no member
EXTERNAL_ROW_FILEPRIVATE_ESCAPE|OtherPackage|has no dynamic member|has no member
CASES

done

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
MULTI_PAYLOAD|multiple associated values require one tracked payload struct
CASE_COLLISION|collides with an existing member
DOMAIN_OUTSIDE|requires an instance property
DOMAIN_STATIC|requires an instance property
NON_EQUATABLE_COMPUTED_CHILD|computed tracked children require a stored child
NON_EQUATABLE_COMPUTED_OPTIONAL|computed tracked children require a stored child
HIDDEN_LAZY|lazy properties are unsupported
HIDDEN_WRAPPER|property attributes/wrappers
HIDDEN_CONDITIONAL|conditional member groups are unsupported
PLAIN_ENUM_PAYLOAD|tracked payload struct
DOMAIN_NESTED_OUTSIDE|requires an instance property
NON_SENDABLE_DOMAIN|non-Sendable type
HIDDEN_ROW_ID|view-visible leaf id
TRACKED_ROW_ID|view-visible leaf id
ARRAY_FEATURE|unsupported tracked container
OPTIONAL_ARRAY_FEATURE|unsupported tracked container
DICTIONARY_FEATURE|unsupported tracked container
SET_FEATURE|unsupported tracked container
DERIVED_ARRAY_FEATURE|unsupported tracked container
OPTIONAL_IDENTIFIED_FEATURE|unsupported tracked container
DICTIONARY_KEY_FEATURE|unsupported tracked container
DICTIONARY_BOTH_FEATURE|unsupported tracked container
ALIASED_ARRAY_FEATURE|unsupported tracked container
CASES

# Compile/link actual ordinary-import clients using the package's archive. These
# isolate duplicate-result preconditions from the test runner process.
[[ -f "$BIN/libLattice.a" ]] || { echo "Runtime fixture archive missing: $BIN/libLattice.a" >&2; exit 1; }
ulimit -c 0
pass result-runtime-build "${COMPILER[@]}" -L "$BIN" -lLattice "$FIXTURES/ResultRuntime.swift" -o "$LOG_DIR/result-runtime"
pass result-runtime "$LOG_DIR/result-runtime"
for boundary in READ COMMIT; do
  pass "duplicate-$boundary-build" "${COMPILER[@]}" -L "$BIN" -lLattice -D "DUPLICATE_$boundary" "$FIXTURES/ResultRuntime.swift" -o "$LOG_DIR/duplicate-$boundary"
  fail "duplicate-$boundary" "FeatureState result contains duplicate row IDs" "$LOG_DIR/duplicate-$boundary"
done

echo "PASS: FeatureState compiler fixtures; logs: $LOG_DIR" | tee -a "$SUMMARY"
