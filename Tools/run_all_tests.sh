#!/bin/bash
# =============================================================================
# run_all_tests.sh — compile et lance toutes les suites de tests de Tools/Tests/.
#
#   Tools/run_all_tests.sh                    toutes les suites (sauf Apple, lente et dépendante du Mac)
#   Tools/run_all_tests.sh --avec-apple       ... y compris Tools/Tests/Apple (banc d'essai Apple Intelligence)
#   Tools/run_all_tests.sh Pipeline Text      seulement ces suites (noms de dossiers, casse indifférente)
#   Tools/run_all_tests.sh --aide
#
# Les suites sont découvertes dans Tools/Tests/<Nom>/ :
#   - si le dossier contient run.sh ou run_tests.sh, ce script est lancé (il compile lui-même) ;
#   - sinon, tous les .swift du dossier sont compilés avec Sources/Core/*.swift et le programme est lancé
#     (Renderer : argument « all » ; Pipeline : dossier de sortie dans build/tests/) ;
#   - Apple : Core + bench/*.swift, seulement avec --avec-apple.
# Sortie : une ligne PASS / FAIL par suite, un résumé, code de sortie non nul si une suite échoue.
# Journaux et programmes compilés : build/tests/ (le journal complet de chaque suite est dans build/tests/<Nom>.log).
# Aucun appel réseau (les tests de Claude utilisent un faux serveur local 127.0.0.1).
# =============================================================================
if [ -z "${BASH_VERSION:-}" ]; then exec /bin/bash "$0" "$@"; fi
set -uo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SORTIE="$RACINE/build/tests"
TESTS="$RACINE/Tools/Tests"
AVEC_APPLE=0
FILTRE=()
for a in "$@"; do
    case "$a" in
        --avec-apple) AVEC_APPLE=1 ;;
        -h|--help|--aide) sed -n '3,/^# ====/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Option inconnue : $a" >&2; exit 2 ;;
        *) FILTRE+=("$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')") ;;
    esac
done
mkdir -p "$SORTIE"
SWIFTC=(swiftc -O -swift-version 5 -target arm64-apple-macos26.0)

choisie() { # le nom de suite $1 est-il demandé ?
    [ "${#FILTRE[@]}" -eq 0 ] && return 0
    local n; n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    local f; for f in "${FILTRE[@]}"; do [ "$f" = "$n" ] && return 0; done
    return 1
}

NB_PASS=0; NB_FAIL=0; NB_SKIP=0; ECHECS=()

lancer_suite() { # nom, commande... (la sortie va dans le journal)
    local nom="$1"; shift
    local journal="$SORTIE/$nom.log" debut=$SECONDS
    if "$@" >"$journal" 2>&1; then
        printf 'PASS  %-12s (%d s)\n' "$nom" $((SECONDS - debut)); NB_PASS=$((NB_PASS + 1))
    else
        printf 'FAIL  %-12s (%d s)  journal : %s\n' "$nom" $((SECONDS - debut)) "$journal"; NB_FAIL=$((NB_FAIL + 1)); ECHECS+=("$nom")
        tail -n 12 "$journal" | sed 's/^/        | /'
    fi
}

compiler_et_lancer() { # nom, dossier, sorties... : compile Core + dossier/*.swift puis lance avec les arguments restants
    local nom="$1" dossier="$2"; shift 2
    local exe="$SORTIE/$nom-tests"
    "${SWIFTC[@]}" "$RACINE"/Sources/Core/*.swift "$dossier"/*.swift -o "$exe" || return 1
    "$exe" "$@"
}

[ -d "$TESTS" ] || { echo "Dossier introuvable : $TESTS" >&2; exit 2; }
for dossier in "$TESTS"/*/; do
    dossier="${dossier%/}"; nom="$(basename "$dossier")"
    choisie "$nom" || continue
    if [ "$nom" = "Apple" ] && [ "$AVEC_APPLE" = 0 ]; then
        printf 'SKIP  %-12s (option --avec-apple)\n' "$nom"; NB_SKIP=$((NB_SKIP + 1)); continue
    fi
    if [ "$nom" = "Apple" ]; then
        lancer_suite "$nom" compiler_et_lancer "$nom" "$dossier/bench"
    elif [ -f "$dossier/run.sh" ]; then
        lancer_suite "$nom" /bin/bash "$dossier/run.sh"
    elif [ -f "$dossier/run_tests.sh" ]; then
        lancer_suite "$nom" /bin/bash "$dossier/run_tests.sh"
    elif ls "$dossier"/*.swift >/dev/null 2>&1; then
        case "$nom" in
            Renderer) lancer_suite "$nom" compiler_et_lancer "$nom" "$dossier" all "$SORTIE/$nom-sortie" ;;
            Pipeline) mkdir -p "$SORTIE/$nom-sortie"; lancer_suite "$nom" compiler_et_lancer "$nom" "$dossier" "$SORTIE/$nom-sortie" ;;
            *)        lancer_suite "$nom" compiler_et_lancer "$nom" "$dossier" ;;
        esac
    else
        printf 'SKIP  %-12s (aucun test trouvé)\n' "$nom"; NB_SKIP=$((NB_SKIP + 1))
    fi
done

echo
echo "Résumé : $NB_PASS réussie(s), $NB_FAIL échouée(s), $NB_SKIP ignorée(s)."
if [ "$NB_FAIL" -gt 0 ]; then echo "Échecs : ${ECHECS[*]}"; exit 1; fi
if [ "$NB_PASS" -eq 0 ]; then echo "Aucune suite n'a tourné." >&2; exit 1; fi
exit 0
