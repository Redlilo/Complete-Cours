#!/bin/bash
# Compile Sources/Core/*.swift avec -D COMPTE_PERSO et lance les tests du passage de vérification (faux générateur :
# aucun réseau, aucun programme claude, aucun quota consommé). Le PDF d'essai est écrit dans build/verification/work.
#
#   Tools/Tests/Verification/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$ROOT/build/verification"
mkdir -p "$OUT/work"
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 -D COMPTE_PERSO "$ROOT"/Sources/Core/*.swift "$HERE/main.swift" -o "$OUT/verification_tests"
exec "$OUT/verification_tests" "$OUT/work"
