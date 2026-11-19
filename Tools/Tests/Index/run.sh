#!/bin/bash
# Compile Core + Recents.swift + les tests de l'index, puis lance (PDF fabriqués dans build/tests/Index-tmp).
set -euo pipefail
RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
mkdir -p "$RACINE/build/tests"
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
  "$RACINE"/Sources/Core/*.swift "$RACINE/Sources/App/Recents.swift" "$RACINE"/Tools/Tests/Index/main.swift \
  -o "$RACINE/build/tests/Index-tests"
"$RACINE/build/tests/Index-tests" "$RACINE/build/tests/Index-tmp"
