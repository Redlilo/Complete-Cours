#!/bin/bash
# Compile et lance les tests du mode Révision (sans fenêtre, sans réseau, sans clé).
# Usage : Tools/Tests/RevisionApp/run_tests.sh   (programme dans build/revision-app/)
set -euo pipefail
RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SORTIE="${REVISION_OUT:-$RACINE/build/revision-app}"
mkdir -p "$SORTIE"
APP="$RACINE/Sources/App"
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
    "$RACINE"/Sources/Core/*.swift "$APP/Format.swift" "$APP/RevisionModel.swift" "$APP/RevisionFake.swift" "$APP/RevisionView.swift" "$APP/RevisionCardsView.swift" "$APP/Style.swift" \
    "$RACINE/Tools/Tests/RevisionApp/main.swift" -o "$SORTIE/revision-app-tests"
"$SORTIE/revision-app-tests" "$SORTIE"
