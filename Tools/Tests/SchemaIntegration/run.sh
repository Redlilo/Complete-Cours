#!/bin/bash
# Tests de l'intégration des zones « Schéma électrique » : exclusion des moteurs de texte, annotation (apply/remove),
# export aplati, magasin d'exemples, modèle de l'app avec un faux générateur. Aucun réseau, aucune clé.
#   Tools/Tests/SchemaIntegration/run.sh [dossier_pour_les_PNG]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$ROOT/build/schema-integration"
mkdir -p "$OUT"
APP="$ROOT/Sources/App"
MODELE=("$APP/AppIdentity.swift" "$APP/Format.swift" "$APP/Keychain.swift" "$APP/Preferences.swift" "$APP/Dialogs.swift" "$APP/RecentFiles.swift" "$APP/CoursModel.swift")
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 "$ROOT"/Sources/Core/*.swift "${MODELE[@]}" "$HERE/main.swift" -o "$OUT/schema-integration-tests"
"$OUT/schema-integration-tests" "${1:-$OUT/png}"
