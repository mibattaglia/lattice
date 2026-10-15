#!/bin/bash
# Negative compile checks for `@FeatureState` hiding and for the effects API.
#
# Compiles the fixture files in Tests/NegativeCompileChecks against the built Lattice module, in two
# lanes:
# - `-typecheck`: once with no flag (BASELINE, must compile) and once per CHECKS flag (must fail with
#   the listed diagnostics).
# - `-emit-sil -wmo -o /dev/null`: region-isolation diagnostics are produced only by SIL passes, never
#   by `-typecheck` (and `-emit-sil` without `-wmo` rejects `-o` with multiple files). Once per
#   SIL_COMPILES flag (must compile with -warnings-as-errors) and once per SIL_CHECKS flag (must fail
#   with the listed diagnostics). This lane prints diagnostics in the LLVM style, one line per error
#   and per note, because a region-isolation error names the isolation domains only in its note.
# Each `@FeatureState` enum has its own fixture file.
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

emit_sil() {
  swiftc -emit-sil -wmo -o /dev/null -parse-as-library -module-name NegativeCompileChecks \
    -swift-version 6 -diagnostic-style llvm "${SEARCH_PATHS[@]}" \
    -load-plugin-executable "$LATTICE_MACROS" \
    -load-plugin-executable "$CASE_PATHS_MACROS" \
    "$@" "${FIXTURES[@]}" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g'
  return "${PIPESTATUS[0]}"
}

DOMAIN_MESSAGE="is @Domain state and is not visible to views"
MAIN_ACTOR_SENDING="sending main actor-isolated value of non-Sendable type"

# FLAG|SITES|expected diagnostic substring
#
# Each flag guards one or more rejected sites in the fixtures. A flag passes when it fails to
# compile and, for each of its entries, at least SITES distinct source locations report an error
# containing the substring. A flag may have several entries.
CHECKS=(
  "LEAK_ROOT|2|'lastUpdatedAt' is unavailable: 'lastUpdatedAt' $DOMAIN_MESSAGE"
  "LEAK_NESTED|2|'secretThreshold' is unavailable: 'secretThreshold' $DOMAIN_MESSAGE"
  "LEAK_OPTIONAL|2|'secretThreshold' is unavailable: 'secretThreshold' $DOMAIN_MESSAGE"
  "LEAK_COLLECTION|2|'secretThreshold' is unavailable: 'secretThreshold' $DOMAIN_MESSAGE"
  "LEAK_KEYPATH|2|'nonce' is unavailable: 'nonce' $DOMAIN_MESSAGE"
  "LEAK_KEYPATH|1|'secretThreshold' is unavailable: 'secretThreshold' $DOMAIN_MESSAGE"
  "LEAK_BINDING|1|'lastUpdatedAt' is unavailable: 'lastUpdatedAt' $DOMAIN_MESSAGE"
  "LEAK_BINDING|1|'secretThreshold' is unavailable: 'secretThreshold' $DOMAIN_MESSAGE"
  "LEAK_SCOPED|2|'secretThreshold' is unavailable: 'secretThreshold' $DOMAIN_MESSAGE"
  "LEAK_CASE|3|'etag' is unavailable: 'etag' $DOMAIN_MESSAGE"
  "LEAK_CASE|1|to expected argument type 'KeyPath<Case<ScreenState.ViewState>, Case<"
  "LEAK_RAW_STATE|1|'_state' is inaccessible due to '@_spi' protection level"
  "LEAK_RAW_STATE|1|'_base' is inaccessible due to '@_spi' protection level"
  "LEAK_RAW_STATE|1|has no dynamic member 'state' using key path from root type 'CounterState.ViewState'"
  "GENERIC_STATE|1|'@FeatureState' cannot be applied to generic type 'GenericState'"
)

# `-emit-sil -wmo` lane. SIL_COMPILES flags are positive checks: the fixtures they enable must compile
# with -warnings-as-errors. SIL_CHECKS entries have the CHECKS format and match error or note lines.
SIL_COMPILES=(
  # Non-Sendable state, action and dependency (a `nonisolated(nonsending)` async method).
  "NO_SENDABLE_BASELINE"
)
SIL_CHECKS=(
  # A Sema diagnostic (`-typecheck` reports it too), kept with the effects fixtures it guards.
  "PERFORM_IN_EFFECT|1|'perform' is unavailable from asynchronous contexts"
  # Notes of "sending … risks causing data races": a main-actor interactor (from a `@MainActor`
  # factory, and formed inline in a `@MainActor` test) and a main-actor `receive` predicate.
  "MAINACTOR_INTERACTOR_TO_TESTMODEL|2|$MAIN_ACTOR_SENDING 'Feature<CounterAction, CounterState>' to actor-isolated initializer 'init(initialState:feature:"
  "MAINACTOR_INTERACTOR_TO_TESTMODEL|1|$MAIN_ACTOR_SENDING '(CounterAction) -> Bool' to actor-isolated instance method 'receive("
)

failures=0
flag_count=0

# Runs every flag of the given checks through the compile function: a flag fails when it compiles
# or when one of its entries is reported at fewer than SITES locations. An entry matches the lines
# of the diagnostic kinds in KINDS, an extended regular expression ("error" or "error|note"). Sets
# `flag_count`.
# Usage: expect_rejections COMPILE_FUNCTION KINDS CHECK...
expect_rejections() {
  local compile_function="$1"
  local kinds="$2"
  shift 2
  local flags=() check flag rest sites expected found output status
  for check in "$@"; do
    flag="${check%%|*}"
    case " ${flags[*]-} " in
      *" $flag "*) ;;
      *) flags+=("$flag") ;;
    esac
  done
  flag_count=${#flags[@]}

  for flag in ${flags[@]+"${flags[@]}"}; do
    output="$("$compile_function" -D "$flag")"
    status=$?
    if [[ $status -eq 0 ]]; then
      echo "FAIL $flag compiled"
      failures=$((failures + 1))
      continue
    fi
    for check in "$@"; do
      [[ "${check%%|*}" == "$flag" ]] || continue
      rest="${check#*|}"
      sites="${rest%%|*}"
      expected="${rest#*|}"
      found="$(grep -E "\.swift:[0-9]+:[0-9]+: ($kinds): " <<<"$output" | grep -F -- "$expected" \
        | sed -E "s/: ($kinds): .*//" | sort -u | wc -l | tr -d ' ')"
      if [[ $found -lt $sites ]]; then
        echo "FAIL $flag (exit $status): $found of $sites site(s) report: $expected"
        grep -E "\.swift:[0-9]+:[0-9]+: ($kinds): " <<<"$output" | sed 's/^/       /'
        failures=$((failures + 1))
      else
        echo "ok   $flag rejected at $found site(s): $expected"
      fi
    done
  done
}

echo "-typecheck"
output="$(typecheck)"
if [[ $? -eq 0 ]]; then
  echo "ok   BASELINE compiles"
else
  echo "FAIL BASELINE does not compile:"
  grep -E "error:" <<<"$output" | sed 's/^/       /'
  failures=$((failures + 1))
fi
expect_rejections typecheck "error" "${CHECKS[@]}"
typecheck_flag_count=$flag_count

echo "-emit-sil -wmo"
for flag in "${SIL_COMPILES[@]}"; do
  output="$(emit_sil -D "$flag" -warnings-as-errors)"
  if [[ $? -eq 0 ]]; then
    echo "ok   $flag compiles with -warnings-as-errors"
  else
    echo "FAIL $flag does not compile with -warnings-as-errors:"
    grep -E "(error|warning):" <<<"$output" | sed 's/^/       /'
    failures=$((failures + 1))
  fi
done
expect_rejections emit_sil "error|note" "${SIL_CHECKS[@]}"
sil_flag_count=$flag_count

if [[ $failures -ne 0 ]]; then
  echo "$failures negative compile check(s) failed"
  exit 1
fi
echo "All negative compile checks passed (-typecheck: BASELINE + $typecheck_flag_count flags," \
  "${#CHECKS[@]} diagnostics; -emit-sil -wmo: ${#SIL_COMPILES[@]} positive + $sil_flag_count flags," \
  "${#SIL_CHECKS[@]} diagnostics)"
