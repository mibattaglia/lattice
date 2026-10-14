#!/bin/bash
# Negative compile checks for `@FeatureState` hiding.
#
# Type-checks the fixture files in Tests/NegativeCompileChecks against the built Lattice module: once
# with no flag (BASELINE, must compile) and once per flag below (must fail with the listed diagnostics).
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

DOMAIN_MESSAGE="is @Domain state and is not visible to views"

# FLAG|SITES|expected diagnostic substring
#
# Each flag guards one or more rejected sites in the fixtures. A flag passes when it fails to
# type-check and, for each of its entries, at least SITES distinct source locations report an error
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

FLAGS=()
for check in "${CHECKS[@]}"; do
  flag="${check%%|*}"
  case " ${FLAGS[*]-} " in
    *" $flag "*) ;;
    *) FLAGS+=("$flag") ;;
  esac
done

failures=0

output="$(typecheck)"
if [[ $? -eq 0 ]]; then
  echo "ok   BASELINE compiles"
else
  echo "FAIL BASELINE does not compile:"
  grep -E "error:" <<<"$output" | sed 's/^/       /'
  failures=$((failures + 1))
fi

for flag in "${FLAGS[@]}"; do
  output="$(typecheck -D "$flag")"
  status=$?
  if [[ $status -eq 0 ]]; then
    echo "FAIL $flag compiled"
    failures=$((failures + 1))
    continue
  fi
  for check in "${CHECKS[@]}"; do
    [[ "${check%%|*}" == "$flag" ]] || continue
    rest="${check#*|}"
    sites="${rest%%|*}"
    expected="${rest#*|}"
    found="$(grep -E '\.swift:[0-9]+:[0-9]+: error: ' <<<"$output" | grep -F -- "$expected" \
      | sed -E 's/: error: .*//' | sort -u | wc -l | tr -d ' ')"
    if [[ $found -lt $sites ]]; then
      echo "FAIL $flag (exit $status): $found of $sites site(s) report: $expected"
      grep -E '\.swift:[0-9]+:[0-9]+: error: ' <<<"$output" | sed 's/^/       /'
      failures=$((failures + 1))
    else
      echo "ok   $flag rejected at $found site(s): $expected"
    fi
  done
done

if [[ $failures -ne 0 ]]; then
  echo "$failures negative compile check(s) failed"
  exit 1
fi
echo "All negative compile checks passed (BASELINE + ${#FLAGS[@]} flags, ${#CHECKS[@]} diagnostics)"
