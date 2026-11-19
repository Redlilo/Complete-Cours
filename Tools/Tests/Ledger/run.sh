#!/bin/bash
# Tests du journal (CourseLedger), du cache d'analyse et du lot « Compléter » (BatchCompleter).
#   Tools/Tests/Ledger/run.sh
# Deux programmes : « core » (Sources/Core seulement) et « batch » (Core + modèle de l'app + Batch.swift, faux moteur).
# Aucun réseau, aucune clé, aucun fichier de l'élève : tout est fabriqué dans un dossier temporaire.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$ROOT/build/ledger"
mkdir -p "$OUT"
APP="$ROOT/Sources/App"
SW=(swiftc -O -swift-version 5 -target arm64-apple-macos26.0)
"${SW[@]}" "$ROOT"/Sources/Core/*.swift "$HERE/core/main.swift" -o "$OUT/ledger-core-tests"
"$OUT/ledger-core-tests"
MODELE=("$APP/Format.swift" "$APP/Keychain.swift" "$APP/Preferences.swift" "$APP/Dialogs.swift" "$APP/RecentFiles.swift" "$APP/CoursModel.swift" "$APP/Batch.swift")
"${SW[@]}" "$ROOT"/Sources/Core/*.swift "${MODELE[@]}" "$HERE/batch/main.swift" -o "$OUT/ledger-batch-tests"
"$OUT/ledger-batch-tests"
