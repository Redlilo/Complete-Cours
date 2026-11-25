#!/bin/bash
# Compile et lance le test des symboles / du rendu de schémas. Usage : run.sh [dossier_de_sortie]
set -e
RACINE="$(cd "$(dirname "$0")/../../.." && pwd)"
SORTIE="${1:-/private/tmp/claude-501/-Users-maelehuidoux/798c86e0-d112-42ac-8e88-26ff7857191e/scratchpad/schema-dessin}"
mkdir -p "$RACINE/build/dessin" "$SORTIE"
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
  "$RACINE/Sources/Core/SchemaContract.swift" "$RACINE/Sources/Core/SchemaSymbols.swift" \
  "$RACINE/Sources/Core/SchemaRenderer.swift" "$RACINE/Sources/Core/PageImaging.swift" "$RACINE/Tools/Tests/Schema/main.swift" \
  -o "$RACINE/build/dessin/schematest"
"$RACINE/build/dessin/schematest" "$SORTIE"
