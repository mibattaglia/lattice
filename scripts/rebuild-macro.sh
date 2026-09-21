#!/bin/bash
set -e

if [[ "${SKIP_LATTICE_MACRO_BUILD:-}" == "1" || "${SKIP_LATTICE_MACRO_BUILD:-}" == "true" ]]; then
  echo "SKIP_LATTICE_MACRO_BUILD is set; skipping LatticeMacros build."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(dirname "$SCRIPT_DIR")"

echo "Building LatticeMacros..."
cd "$PACKAGE_DIR"
swift build -c release

echo "Copying binary to Macros/"
BIN_DIR="$(swift build -c release --show-bin-path)"
MACRO_BINARY="$BIN_DIR/LatticeMacros-tool"
if [[ ! -f "$MACRO_BINARY" ]]; then
  MACRO_BINARY="$BIN_DIR/LatticeMacros"
fi
if [[ ! -f "$MACRO_BINARY" ]]; then
  echo "LatticeMacros executable not found in $BIN_DIR" >&2
  exit 1
fi
mkdir -p Macros
cp "$MACRO_BINARY" Macros/LatticeMacros

echo "Verifying binary..."
lipo -info Macros/LatticeMacros

echo "Done! Macro binary updated at: Macros/LatticeMacros"
