#!/bin/bash
# Banc d'essai de la détection des trous (zones à remplir) : mesure sur de vrais PDF de l'élève, LECTURE SEULE.
# Sans réseau, sans moteur IA. Rien n'est écrit hors de build/detection/ (copies vierges, PNG de contrôle, TSV, rapport).
#   Tools/Tests/Detection/run.sh                    jeu réel (~/Desktop/Cours) + synthétique
#   Tools/Tests/Detection/run.sh --seul Maths       ne garde que les documents dont le chemin contient « Maths »
#   Tools/Tests/Detection/run.sh --synthetique      seulement les 14 lignes synthétiques (rapide, sans données de l'élève)
#   Tools/Tests/Detection/run.sh --top 20 --sans-png
#   Tools/Tests/Detection/run.sh --maj              écrit reference.txt (chiffres globaux uniquement, aucun nom de document)
# Sans dossier ~/Desktop/Cours : retombe sur le synthétique et sort en 0 (compatible avec Tools/run_all_tests.sh).
# Régression : échoue (code 1) si le synthétique perd un trou ou gagne un faux ; sur le jeu réel, signale (sans échouer)
# une baisse de rappel ou de précision de plus de 3 points par rapport à reference.txt.
# Sorties : build/detection/resultat.txt (rapport), manques.tsv, zones_sans_reponse.tsv, png/ (bleu = zone sûre,
# orange = douteuse ou désactivée, vert pointillé = trou trouvé, rouge pointillé = trou manqué).
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$ROOT/build/detection"
REF="$HERE/reference.txt"
MAJ=0; ARGS=()
for a in "$@"; do if [ "$a" = "--maj" ]; then MAJ=1; else ARGS+=("$a"); fi; done
mkdir -p "$WORK" || exit 1
# Les sources sont modifiées en parallèle par d'autres chantiers : une compilation ratée est signalée, pas masquée.
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 "$ROOT"/Sources/Core/*.swift "$HERE/main.swift" -o "$WORK/detection_test" 2>"$WORK/compile.log" \
  || { echo "COMPILATION du banc échouée (sources en cours de modification ?)"; grep error "$WORK/compile.log" | head; exit 1; }
"$WORK/detection_test" "$WORK" ${ARGS[@]+"${ARGS[@]}"} 2>"$WORK/progression.log"
STATUS=$?
[ $STATUS -ne 0 ] && { echo "Le banc a échoué (code $STATUS), voir $WORK/progression.log"; exit $STATUS; }

RES="$WORK/resultat.txt"
SYN=$(grep '^Synthétique' "$RES")
att=$(echo "$SYN" | sed 's/.*attendus=\([0-9]*\).*/\1/'); trv=$(echo "$SYN" | sed 's/.*trouves=\([0-9]*\).*/\1/'); fx=$(echo "$SYN" | sed 's/.*faux=\([0-9]*\).*/\1/')
# chiffres globaux, lus sur la ligne « REEL » écrite par le programme
REEL=$(grep '^REEL' "$RES")
GLOBAL=""
if [ -n "$REEL" ]; then
  g() { echo "$REEL" | grep -o "$1=[0-9]*" | cut -d= -f2; }
  te=$(g trous_eleve); fe=$(g trouves_eleve); ta=$(g trous_appli); fa=$(g trouves_appli); z=$(g zones); v=$(g vraies)
  pc() { [ "$2" -gt 0 ] && echo $((100 * $1 / $2)) || echo 0; }
  GLOBAL="RAPPEL_ELEVE=$(pc "$fe" "$te") RAPPEL_APPLI=$(pc "$fa" "$ta") PRECISION=$(pc "$v" "$z")"
fi
echo
echo "Rapport complet : $RES"
if [ $MAJ -eq 1 ]; then
  { echo "SYNTHESE attendus=$att trouves=$trv faux=$fx"; [ -n "$GLOBAL" ] && echo "$GLOBAL"; } > "$REF"
  echo "Référence écrite : $REF"; exit 0
fi
STATUS=0
if [ -f "$REF" ]; then
  RSYN=$(grep '^SYNTHESE' "$REF")
  ot=$(echo "$RSYN" | sed 's/.*trouves=\([0-9]*\).*/\1/'); of=$(echo "$RSYN" | sed 's/.*faux=\([0-9]*\).*/\1/')
  if [ "$trv" -lt "$ot" ] || [ "$fx" -gt "$of" ]; then echo "RÉGRESSION synthétique : trouvés $ot -> $trv, faux $of -> $fx"; STATUS=1; fi
  if [ -n "$GLOBAL" ] && grep -q RAPPEL_ELEVE "$REF"; then
    for k in RAPPEL_ELEVE RAPPEL_APPLI PRECISION; do
      old=$(grep -o "$k=[0-9]*" "$REF" | cut -d= -f2); new=$(echo "$GLOBAL" | grep -o "$k=[0-9]*" | cut -d= -f2)
      if [ -n "$old" ] && [ -n "$new" ] && [ $((new + 3)) -lt "$old" ]; then echo "ATTENTION (jeu réel) : $k $old % -> $new %"; fi
    done
  fi
else
  [ "$trv" -lt "$att" ] && STATUS=1
fi
[ $STATUS -eq 0 ] && echo "OK : synthétique $trv/$att trouvés, $fx faux ; réel : ${GLOBAL:-non mesuré}"
exit $STATUS
