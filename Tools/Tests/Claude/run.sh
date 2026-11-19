#!/bin/bash
# Compile le moteur Claude (Sources/Core/*.swift) avec le programme de test, puis lance les tests contre le faux
# serveur local claude_mock.py (aucun appel réseau réel). Code de sortie non nul si un scénario échoue.
#
#   Tools/Tests/Claude/run.sh                               tous les scénarios
#   Tools/Tests/Claude/run.sh --save-images DOSSIER         enregistre aussi les images reçues par le mock (à regarder)
#
# Compilation : build/claude/claude_tests ; journal du mock : build/claude/mock-out/mock.log
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$ROOT/build/claude"
mkdir -p "$OUT"
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 "$ROOT"/Sources/Core/*.swift "$HERE/main.swift" -o "$OUT/claude_tests"
exec "$OUT/claude_tests" "$@"
