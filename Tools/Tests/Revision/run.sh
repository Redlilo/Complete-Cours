#!/bin/bash
# Compile Sources/Core/*.swift avec les tests du mode « Révision » puis les lance (faux moteur, aucun réseau).
# Les PDF d'essai et leurs rendus PNG sont écrits dans build/revision/work (à regarder à l'œil).
#
#   Tools/Tests/Revision/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$ROOT/build/revision"
mkdir -p "$OUT/work"
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 "$ROOT"/Sources/Core/*.swift "$HERE/main.swift" -o "$OUT/revision_tests"
exec "$OUT/revision_tests" "$OUT/work"
