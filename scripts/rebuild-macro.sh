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
mkdir -p Macros
cp "$BIN_DIR/LatticeMacros-tool" Macros/LatticeMacros

echo "Verifying binary..."
lipo -info Macros/LatticeMacros

echo "Done! Macro binary updated at: Macros/LatticeMacros"
