#!/bin/bash
# Compile le moteur « Claude (mon compte) » (Sources/Core/*.swift avec -D COMPTE_PERSO) et lance ses tests contre un FAUX
# programme claude (fake_claude.py) : aucun appel réseau, aucun quota consommé, jamais « auth login » pour de vrai.
# La phase 1 essaie aussi le VRAI programme installé, seulement pour ce qui ne coûte rien (--version, auth status, un appel -p qui
# répond « Not logged in ») ; elle est ignorée si le programme est absent, et l'appel -p l'est si le compte est connecté.
#
#   Tools/Tests/ClaudeCode/run.sh            compile et lance les tests
#   Tools/Tests/ClaudeCode/run.sh --live     compile seulement l'outil `live` (premier vrai essai, une fois connecté)
#
# Sorties : build/claudecode/claudecode_tests (et build/claudecode/live). Code de sortie non nul si un test échoue.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$ROOT/build/claudecode"
mkdir -p "$OUT"
SWIFTC=(swiftc -O -swift-version 5 -target arm64-apple-macos26.0 -D COMPTE_PERSO)
if [ "${1:-}" = "--live" ]; then
    "${SWIFTC[@]}" -parse-as-library "$ROOT"/Sources/Core/*.swift "$HERE/live.swift" -o "$OUT/live"
    echo "Outil compilé : $OUT/live"
    echo "Usage : $OUT/live <fichier.pdf> <page> [--model opus|sonnet|haiku] [--effort low|medium|high] [--cli chemin] [--sans-humanisation]"
    exit 0
fi
"${SWIFTC[@]}" "$ROOT"/Sources/Core/*.swift "$HERE/main.swift" -o "$OUT/claudecode_tests"
exec "$OUT/claudecode_tests" --fake "$HERE/fake_claude.py" --work "$OUT/work" "$@"
