#!/bin/bash
# Test du Suivi MacBook IA (version personnelle). Usage : run.sh [dossier des pages enregistrées]
# Les tests de lecteurs ont besoin de pages HTML enregistrées ; sans elles, seuls les calculs (prix, notes) sont vérifiés.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$ROOT/build/suivitest"; mkdir -p "$OUT"
A="$ROOT/Sources/App"
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 -D COMPTE_PERSO \
  "$A/SuiviMacModels.swift" "$A/SuiviMacSources.swift" "$A/SuiviMacWebKit.swift" "$A/SuiviMacAnalyse.swift" "$A/SuiviMacModeles.swift" \
  "$HERE/main.swift" -o "$OUT/suivimac-tests"
"$OUT/suivimac-tests" "${1:-$HERE/pages}"
