#!/bin/bash
# Tests de la détection des zones à partir du texte du PDF. Ne lit AUCUN vrai cours de l'élève.
# Ce que la suite vérifie :
#   1. cas synthétiques (main.swift : PDF généré avec des trous connus et des faux trous à éviter : sommaires à
#      points, « etc... », deux-points suivis d'une liste...) -> trouvés / faux / manqués, sans régression ;
#   2. PDF fabriqués (genpdf.swift, mêmes générateurs que la suite App : texte à pointillés/soulignés/cadre,
#      champs de formulaire, page tournée, page rognée, page vide) passés dans le harnais : nombre de zones
#      par page et par source comparé à reference.txt, plus un temps d'analyse maximal par PDF.
# usage : Tools/Tests/Text/run.sh          compare à reference.txt, signale les régressions
#         Tools/Tests/Text/run.sh --maj    écrit une nouvelle référence (après une amélioration vérifiée)
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$ROOT/build/texte"
REF="$HERE/reference.txt"
MAJ=0; [ "$1" = "--maj" ] && MAJ=1
mkdir -p "$WORK/pdf" "$WORK/out" || exit 1

REELS=("texte" "tourne" "rognage" "vide")

swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos26.0 "$HERE/genpdf.swift" "$ROOT/Tools/Tests/App/TestPDFs.swift" -o "$WORK/genpdf" 2>"$WORK/compile_gen.log" || { echo "COMPILATION genpdf échouée"; grep error "$WORK/compile_gen.log" | head; exit 1; }
rm -rf "$WORK/pdf"; mkdir -p "$WORK/pdf"
"$WORK/genpdf" "$WORK/pdf" || { echo "fabrication des PDF impossible"; exit 1; }

swiftc -O -swift-version 5 -target arm64-apple-macos26.0 "$ROOT"/Sources/Core/*.swift "$ROOT"/Tools/Harness/main.swift -o "$WORK/harness" 2>"$WORK/compile_harness.log" || { echo "COMPILATION harnais échouée"; grep error "$WORK/compile_harness.log" | head; exit 1; }
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 "$ROOT"/Sources/Core/*.swift "$HERE/main.swift" -o "$WORK/texte_test" 2>"$WORK/compile_test.log" || { echo "COMPILATION test échouée"; grep error "$WORK/compile_test.log" | head; exit 1; }

"$WORK/texte_test" "$WORK/out" > "$WORK/synthese.txt"
cat "$WORK/synthese.txt"
SYN=$(grep '^SYNTHESE' "$WORK/synthese.txt")
: > "$WORK/reel.txt"
for nom in "${REELS[@]}"; do
  mkdir -p "$WORK/out/$nom"
  "$WORK/harness" zones "$WORK/pdf/$nom.pdf" "$WORK/out/$nom" --blank > "$WORK/out/$nom.txt" 2>&1
  awk -v d="$nom" '
    /^=== page/ { if (pg!="") flush(); pg=$3; ms=$(NF-1); gsub(/\[/,"",ms); tot+=ms; delete c; t=0 }
    /^  #/ { c[$2]++; t++ }
    END { if (pg!="") flush(); printf "TEMPS %s ms=%d\n", d, tot }
    function flush() { printf "PAGE %s p%s total=%d formulaire=%d texte=%d ligne=%d cadre=%d\n", d, pg, t, c["formulaire"]+0, c["texte"]+0, c["ligne"]+0, c["cadre"]+0 }
  ' "$WORK/out/$nom.txt" >> "$WORK/reel.txt"
done
{ echo "$SYN"; cat "$WORK/reel.txt"; } > "$WORK/resultat.txt"

if [ $MAJ -eq 1 ]; then
  cp "$WORK/resultat.txt" "$REF"; echo "Référence écrite : $REF"; exit 0
fi
[ -f "$REF" ] || { echo "Pas de référence : lancer avec --maj"; exit 1; }

STATUS=0
RSYN=$(grep '^SYNTHESE' "$REF")
rt=$(echo "$SYN" | sed 's/.*trouves=\([0-9]*\).*/\1/'); rf=$(echo "$SYN" | sed 's/.*faux=\([0-9]*\).*/\1/')
ot=$(echo "$RSYN" | sed 's/.*trouves=\([0-9]*\).*/\1/'); of=$(echo "$RSYN" | sed 's/.*faux=\([0-9]*\).*/\1/')
if [ "$rt" -lt "$ot" ] || [ "$rf" -gt "$of" ]; then echo "RÉGRESSION synthétique : trouvés $ot -> $rt, faux $of -> $rf"; STATUS=1; fi
DIFF=$(diff <(grep -v '^SYNTHESE\|^TEMPS' "$REF") <(grep -v '^SYNTHESE\|^TEMPS' "$WORK/resultat.txt"))
[ -n "$DIFF" ] && { echo "Différences sur les PDF réels (à relire) :"; echo "$DIFF"; }
while read -r l; do
  ms="${l##*ms=}"; nom=$(echo "$l" | awk '{print $2}')
  [ "$ms" -gt 2000 ] && { echo "TEMPS trop long : $nom $ms ms"; STATUS=1; }
done < <(grep '^TEMPS' "$WORK/resultat.txt")
[ $STATUS -eq 0 ] && echo "OK : aucune régression (synthétique : $SYN)"
exit $STATUS
