#!/bin/bash
set -e

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
