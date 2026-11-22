#!/bin/bash
# Installe la reconnaissance de la voix du prof (une seule fois) : un environnement Python avec la bibliothèque Resemblyzer.
# Usage : installer.sh <dossier de destination>      Télécharge environ 250 Mo (internet) et occupe environ 1,1 Go ; rien n'est modifié ailleurs.
set -euo pipefail
DEST="${1:?dossier de destination manquant}"
ICI="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DEST"

PY=""
for c in /Library/Frameworks/Python.framework/Versions/3.14/bin/python3 /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 \
         /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    [ -x "$c" ] && PY="$c" && break
done
[ -n "$PY" ] || { echo "ERREUR : Python 3.12 ou plus récent est introuvable (installe-le depuis python.org)."; exit 2; }
echo "Python : $PY"

echo "Création de l'environnement…"
rm -rf "$DEST/venv"
"$PY" -m venv "$DEST/venv"

echo "Téléchargement de la bibliothèque (environ 250 Mo, quelques minutes)…"
"$DEST/venv/bin/pip" install --quiet --disable-pip-version-check resemblyzer "setuptools<81"

cp "$ICI/voice.py" "$DEST/voice.py"
echo "Vérification…"
"$DEST/venv/bin/python3" -c "from resemblyzer import VoiceEncoder; VoiceEncoder('cpu', verbose=False); print('modèle de voix chargé')"
echo "OK"
