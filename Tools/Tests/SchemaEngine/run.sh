#!/bin/bash
# Compile le moteur de schémas (Sources/Core/*.swift) avec le dessin réel (SchemaSymbols/SchemaRenderer) et lance les tests
# contre un faux serveur local (mock.py, 127.0.0.1 seulement) : aucun appel réseau réel, aucune clé.
#   Tools/Tests/SchemaEngine/run.sh [dossier d'images de sortie]
# Compilation : build/schema-engine/schema_tests. Sans COMPTE_PERSO ; avec : COMPTE=1 run.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$ROOT/build/schema-engine"
mkdir -p "$OUT"
FLAGS=()
[ "${COMPTE:-0}" = "1" ] && FLAGS+=(-D COMPTE_PERSO)
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 ${FLAGS[@]+"${FLAGS[@]}"} "$ROOT"/Sources/Core/*.swift "$HERE/main.swift" -o "$OUT/schema_tests"
cd "$ROOT"
exec "$OUT/schema_tests" "$HERE/mock.py" "${1:-$OUT/images}"
