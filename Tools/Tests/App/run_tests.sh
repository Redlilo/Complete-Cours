#!/bin/bash
# Compile et lance les tests du modèle de l'interface (sans fenêtre, sans réseau, sans clé).
# Usage : Tools/Tests/App/run_tests.sh      (la sortie du programme de test est dans build/interface/app-tests)
set -euo pipefail
RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SORTIE="$RACINE/build/interface"
mkdir -p "$SORTIE"
APP="$RACINE/Sources/App"
TESTS="$RACINE/Tools/Tests/App"
# Le modèle d'état et ses utilitaires seulement : pas les vues ni le point d'entrée.
MODELE=("$APP/AppIdentity.swift" "$APP/Format.swift" "$APP/Keychain.swift" "$APP/Preferences.swift" "$APP/Dialogs.swift" "$APP/RecentFiles.swift" "$APP/CoursModel.swift")
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
    "$RACINE"/Sources/Core/*.swift "${MODELE[@]}" \
    "$TESTS/TestPDFs.swift" "$TESTS/FakeEngine.swift" "$TESTS/main.swift" -o "$SORTIE/app-tests"
"$SORTIE/app-tests"
