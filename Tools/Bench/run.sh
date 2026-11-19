#!/bin/bash
# =============================================================================
# Tools/Bench/run.sh — banc d'essai de la détection des zones, avec vérité de terrain (LECTURE SEULE).
#
#   Tools/Bench/run.sh                         dossier des cours par défaut (~/Desktop/Cours)
#   Tools/Bench/run.sh <dossier> [options]
#   options : --json            sortie JSON (résumé, documents, pires erreurs)
#             --top N           longueur des listes d'erreurs (défaut 15)
#             --seul <texte>    ne garde que les documents dont le chemin contient ce texte
#             --douteux X       seuil de confiance « douteuse » (défaut 0.6)
#             --aide
# Paires : original vide dans « _Originaux avant completion/<chemin> » ↔ version « (complétée) », « - rempli »,
# « _complete » dans le dossier miroir (ou à côté de l'original). Les évaluations ne sont JAMAIS ouvertes.
# Vérité : une zone de l'original est vraie si de l'encre/du texte a été ajouté dedans (PageDiff).
# Le programme compilé est dans build/bench/ ; rien n'est écrit dans le dossier des cours.
# =============================================================================
if [ -z "${BASH_VERSION:-}" ]; then exec /bin/bash "$0" "$@"; fi
set -euo pipefail
RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SORTIE="$RACINE/build/bench"; mkdir -p "$SORTIE"
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 "$RACINE"/Sources/Core/*.swift "$RACINE"/Tools/Bench/*.swift -o "$SORTIE/bench"
exec "$SORTIE/bench" "$@"
