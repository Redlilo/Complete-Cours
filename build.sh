#!/bin/bash
# =============================================================================
# build.sh — compile « Complète-Cours » et fabrique l'application macOS (sans Xcode).
#
#   ./build.sh               compile et crée  build/Complete-Cours.app  (signature ad hoc, non notarisée)
#   ./build.sh --install     ... puis copie l'app dans ~/Applications (remplace l'ancienne version)
#   ./build.sh --zip         ... puis crée Distribution/Complete-Cours-<version>.zip (app + LISEZMOI.txt) à donner
#                            à un camarade, et vérifie le contenu du zip extrait (structure, plist, arm64, signature,
#                            absence du moteur « mon compte »). Le zip ne contient JAMAIS le moteur « mon compte ».
#   ./build.sh --personnel   variante PERSONNELLE, pour toi seul : compile avec le moteur « Claude (mon compte) »
#                            (-D COMPTE_PERSO) et l'écran « Suivi MacBook IA ». Elle s'appelle « App Perso »
#                            (build/App Perso.app, identifiant fr.complete-cours.app.perso, inchangé : tes réglages, ton
#                            trousseau et ton historique sont conservés) pour ne pas mélanger avec la version distribuable.
#                            Combinable avec --install et --run ; incompatible avec --zip.
#   ./build.sh --run         ... puis lance l'app
#   ./build.sh --clean       supprime l'app et les fichiers intermédiaires de build/ (puis s'arrête ;
#                            avec --install ou --run, reconstruit tout de zéro)
#   ./build.sh --aide        affiche cette aide
#
# Il suffit des « Command Line Tools » d'Apple (xcode-select --install) : ni Xcode ni Swift Package Manager.
# Le script fonctionne depuis n'importe quel dossier et avec des espaces ou des accents dans les chemins.
# Avancé : la variable COMPLETE_COURS_BUILD change le dossier de sortie (par défaut : <projet>/build).
# =============================================================================

# Ce script utilise des tableaux (propres à bash) : s'il est lancé par erreur avec zsh ou dash, on relance bash.
if [ -z "${BASH_VERSION:-}" ]; then exec /bin/bash "$0" "$@"; fi
set -euo pipefail

NOM_APP="Complete-Cours"    # nom du paquet .app (sans accent : plus sûr pour les chemins et le Terminal)
NOM_AFFICHE="Complète-Cours" # nom affiché (CFBundleDisplayName) ; changé par --personnel
NOM_EXE="Complete-Cours"      # nom de l'exécutable (doit correspondre à CFBundleExecutable)
NOM_MODULE="CompleteCours"    # nom du module Swift (un identifiant valide, sans tiret)
DEBUT=$SECONDS

# --- Emplacements ------------------------------------------------------------

# Dossier du projet = dossier de ce script (en suivant d'éventuels liens symboliques).
trouver_racine() {
    local source="${BASH_SOURCE[0]}" dossier
    while [ -h "$source" ]; do
        dossier="$(cd -P "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        case "$source" in /*) ;; *) source="$dossier/$source" ;; esac
    done
    cd -P "$(dirname "$source")" && pwd
}
RACINE="$(trouver_racine)"
SORTIE="${COMPLETE_COURS_BUILD:-$RACINE/build}"
INTERM="$SORTIE/.intermediaires"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# --- Messages ----------------------------------------------------------------

if [ -t 1 ]; then GRAS=$'\033[1m'; RAZ=$'\033[0m'; else GRAS=""; RAZ=""; fi
if [ -t 2 ]; then ROUGE=$'\033[1;31m'; JAUNE=$'\033[1;33m'; RAZ_ERR=$'\033[0m'; else ROUGE=""; JAUNE=""; RAZ_ERR=""; fi

etape()   { printf '\n%s==> %s%s\n' "$GRAS" "$*" "$RAZ"; }
info()    { printf '    %s\n' "$*"; }
avertir() { printf '%sAttention :%s %s\n' "$JAUNE" "$RAZ_ERR" "$*" >&2; }
echec()   { printf '\n%sErreur :%s %s\n' "$ROUGE" "$RAZ_ERR" "$*" >&2; exit 1; }

# Filet de sécurité : toute commande qui échoue sans message prévu est signalée en français.
inattendu() { printf '\n%sErreur inattendue%s (ligne %s du script, code %s). Relance avec « bash -x build.sh » pour voir le détail.\n' \
                  "$ROUGE" "$RAZ_ERR" "$1" "$2" >&2; }
trap 'inattendu "$LINENO" "$?"' ERR

aide() {
    sed -n '3,/^# ====/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
}

# --- Options -----------------------------------------------------------------

INSTALLER=0; LANCER=0; NETTOYER=0; ZIPPER=0; PERSO=0
for option in "$@"; do
    case "$option" in
        --install)         INSTALLER=1 ;;
        --run)             LANCER=1 ;;
        --zip)             ZIPPER=1 ;;
        --personnel)       PERSO=1 ;;
        --clean)           NETTOYER=1 ;;
        -h|--help|--aide)  aide; exit 0 ;;
        *) printf 'Option inconnue : %s\n\n' "$option" >&2; aide >&2; exit 2 ;;
    esac
done

# La variante personnelle ne doit jamais partir en zip : le zip est destiné à d'autres personnes.
if [ "$PERSO" = 1 ] && [ "$ZIPPER" = 1 ]; then
    echec "--personnel et --zip ne se combinent pas : le zip ne doit contenir que la version distribuable (sans le moteur « mon compte »)."
fi
# Nom du paquet : la variante personnelle a un nom distinct pour ne pas être confondue avec la version distribuable.
DRAPEAUX=()
ID_BUNDLE_PERSO="fr.complete-cours.app.perso"
if [ "$PERSO" = 1 ]; then
    NOM_APP="App Perso"
    NOM_AFFICHE="App Perso"
    DRAPEAUX=(-D COMPTE_PERSO)
fi
APP="$SORTIE/$NOM_APP.app"

# --- Nettoyage ---------------------------------------------------------------
# Seuls l'app et les fichiers intermédiaires sont supprimés : le reste de build/ (outils de test…) n'est pas touché.

if [ "$NETTOYER" = 1 ]; then
    etape "Nettoyage"
    rm -rf "$APP" "$SORTIE/Complète-Cours.app" "$INTERM"
    info "Supprimé : $APP"
    info "Supprimé : $INTERM"
    if [ "$INSTALLER" = 0 ] && [ "$LANCER" = 0 ] && [ "$ZIPPER" = 0 ]; then exit 0; fi
fi

# --- Vérification des outils -------------------------------------------------

etape "Vérification des outils"
# On regarde d'abord xcode-select : sans les outils d'Apple, « swiftc » n'est qu'un faux raccourci qui ouvrirait
# une fenêtre d'installation au lieu de compiler.
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
    echec "swiftc est introuvable : les outils de ligne de commande d'Apple ne sont pas installés.
       Installe-les avec cette commande, puis relance ce script :

           xcode-select --install"
fi
VERSION_SWIFT="$(swiftc --version 2>&1 | head -n 1)" ||
    echec "swiftc ne fonctionne pas. Réinstalle les outils de ligne de commande :  xcode-select --install"
info "$VERSION_SWIFT"
for outil in iconutil codesign plutil ditto xattr find sort shasum lipo; do
    command -v "$outil" >/dev/null 2>&1 || echec "L'outil « $outil » est introuvable (il fait partie de macOS)."
done
# Après une mise à jour de macOS, les outils de ligne de commande restent parfois sur l'ancienne version.
VERSION_SDK="$(xcrun --show-sdk-version 2>/dev/null || true)"
if [ -n "$VERSION_SDK" ] && [ "${VERSION_SDK%%.*}" -lt 26 ] 2>/dev/null; then
    echec "les outils de ligne de commande sont trop anciens (SDK macOS $VERSION_SDK, il faut 26 ou plus).
       Mets-les à jour dans Réglages Système > Général > Mise à jour de logiciels,
       ou réinstalle-les :  sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"
fi
if [ "$(uname -m)" != "arm64" ]; then
    avertir "cette app est compilée pour les Mac Apple Silicon (arm64) ; elle ne se lancera pas sur ce Mac."
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ]; then
    avertir "Complète-Cours demande macOS 26 ou plus récent ; elle ne se lancera pas sur ce Mac."
fi

# Tous les fichiers Swift du cœur (Core) et de l'interface (App), dans un ordre fixe.
[ -f "$RACINE/Resources/Info.plist" ] || echec "Fichier introuvable : $RACINE/Resources/Info.plist"
[ -f "$RACINE/Tools/make_icon.swift" ] || echec "Fichier introuvable : $RACINE/Tools/make_icon.swift"
# Info.plist est vérifié avant la compilation (qui peut durer une minute) pour échouer tout de suite s'il est faux.
plutil -lint "$RACINE/Resources/Info.plist" >/dev/null || echec "$RACINE/Resources/Info.plist n'est pas un fichier plist valide (plutil -lint pour le détail)."
EXE_DECLARE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$RACINE/Resources/Info.plist" 2>/dev/null || true)"
[ "$EXE_DECLARE" = "$NOM_EXE" ] ||
    echec "CFBundleExecutable vaut « $EXE_DECLARE » dans Resources/Info.plist, mais l'exécutable s'appelle « $NOM_EXE »."
MIN_SYSTEME="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$RACINE/Resources/Info.plist" 2>/dev/null || true)"
[ "$MIN_SYSTEME" = "26.0" ] ||
    echec "LSMinimumSystemVersion vaut « $MIN_SYSTEME » dans Resources/Info.plist ; il doit valoir 26.0."
mkdir -p "$SORTIE" "$INTERM"
: > "$INTERM/sources.liste"
for dossier in Core App; do
    [ -d "$RACINE/Sources/$dossier" ] || echec "Dossier introuvable : $RACINE/Sources/$dossier"
    avant=$(wc -c < "$INTERM/sources.liste")
    find "$RACINE/Sources/$dossier" -type f -name '*.swift' ! -name '.*' -print0 >> "$INTERM/sources.liste"
    [ "$(wc -c < "$INTERM/sources.liste")" -gt "$avant" ] || echec "Aucun fichier .swift trouvé dans $RACINE/Sources/$dossier"
done
LC_ALL=C sort -z "$INTERM/sources.liste" > "$INTERM/sources.triees"
SOURCES=()
while IFS= read -r -d '' fichier; do SOURCES+=("$fichier"); done < "$INTERM/sources.triees"

# --- Compilation de l'app ----------------------------------------------------

etape "Compilation de ${#SOURCES[@]} fichiers Swift (cela peut prendre une minute)"
rm -f "$INTERM/$NOM_EXE"
# DRAPEAUX est vide dans la version distribuable : le moteur « mon compte » n'est alors pas compilé du tout.
if ! swiftc -O -swift-version 5 -target arm64-apple-macos26.0 -parse-as-library \
        ${DRAPEAUX[@]+"${DRAPEAUX[@]}"} \
        -module-name "$NOM_MODULE" -file-prefix-map "$RACINE=." "${SOURCES[@]}" -o "$INTERM/$NOM_EXE" >"$INTERM/compilation.log" 2>&1; then
    cat "$INTERM/compilation.log" >&2
    echec "la compilation a échoué (messages ci-dessus)."
fi
AVERTISSEMENTS="$(grep -c 'warning:' "$INTERM/compilation.log" || true)"
info "Compilation réussie ($AVERTISSEMENTS avertissement(s), détail dans $INTERM/compilation.log)"
if [ "$PERSO" = 1 ]; then
    info "Variante personnelle : moteur « Claude (mon compte) » inclus (-D COMPTE_PERSO). Ne pas distribuer."
else
    info "Version distribuable : moteur « Claude (mon compte) » absent (COMPTE_PERSO non défini)."
fi

# --- Icône -------------------------------------------------------------------

etape "Création de l'icône"
# L'icône n'est redessinée que si Tools/make_icon.swift a changé depuis la dernière fois.
EMPREINTE_ICONE="$(shasum -a 256 "$RACINE/Tools/make_icon.swift" | cut -d' ' -f1)"
if [ -f "$INTERM/AppIcon.icns" ] && [ "$(cat "$INTERM/icone.empreinte" 2>/dev/null)" = "$EMPREINTE_ICONE" ]; then
    info "Icône déjà à jour."
else
    rm -f "$INTERM/AppIcon.icns" "$INTERM/icone.empreinte"
    swiftc -O -swift-version 5 "$RACINE/Tools/make_icon.swift" -o "$INTERM/make_icon" >"$INTERM/icone.log" 2>&1 ||
        { cat "$INTERM/icone.log" >&2; echec "impossible de compiler Tools/make_icon.swift."; }
    "$INTERM/make_icon" "$INTERM/icone" >>"$INTERM/icone.log" 2>&1 ||
        { cat "$INTERM/icone.log" >&2; echec "la génération des images de l'icône a échoué."; }
    iconutil -c icns -o "$INTERM/AppIcon.icns" "$INTERM/icone/AppIcon.iconset" ||
        echec "iconutil n'a pas pu fabriquer AppIcon.icns."
    printf '%s' "$EMPREINTE_ICONE" > "$INTERM/icone.empreinte"
    info "AppIcon.icns créé."
fi

# --- Assemblage du paquet ----------------------------------------------------

etape "Assemblage de $NOM_APP.app"
NOUVELLE="$INTERM/$NOM_APP.app"
rm -rf "$NOUVELLE"
mkdir -p "$NOUVELLE/Contents/MacOS" "$NOUVELLE/Contents/Resources"
cp "$INTERM/$NOM_EXE" "$NOUVELLE/Contents/MacOS/$NOM_EXE"
cp "$RACINE/Resources/Info.plist" "$NOUVELLE/Contents/Info.plist"
if [ "$PERSO" = 1 ]; then
    # Variante personnelle : identifiant et nom distincts (préférences, trousseau d'accès et menus séparés).
    plutil -replace CFBundleIdentifier -string "$ID_BUNDLE_PERSO" "$NOUVELLE/Contents/Info.plist"
    plutil -replace CFBundleName -string "$NOM_AFFICHE" "$NOUVELLE/Contents/Info.plist"
    plutil -replace CFBundleDisplayName -string "$NOM_AFFICHE" "$NOUVELLE/Contents/Info.plist"
    # Les phrases d'autorisation (micro, dossiers…) parlent aussi de l'app par son nom.
    sed -i '' "s/Complète-Cours/$NOM_AFFICHE/g" "$NOUVELLE/Contents/Info.plist"
fi
cp "$INTERM/AppIcon.icns" "$NOUVELLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$NOUVELLE/Contents/PkgInfo"
# Tout autre fichier ou dossier placé dans Resources/ (hors Info.plist et fichiers cachés) est ajouté tel quel au paquet.
# Resources/Perso/ (Atlas des skills) n'est copié que par la variante personnelle : jamais dans la version distribuable.
EXCLUS_PERSO=(); [ "$PERSO" = 1 ] || EXCLUS_PERSO=(! -name 'Perso')
find "$RACINE/Resources" -mindepth 1 -maxdepth 1 ! -name 'Info.plist' ! -name '.*' ${EXCLUS_PERSO[@]+"${EXCLUS_PERSO[@]}"} -print0 > "$INTERM/ressources.liste"
while IFS= read -r -d '' fichier; do
    ditto "$fichier" "$NOUVELLE/Contents/Resources/$(basename "$fichier")"
done < "$INTERM/ressources.liste"

# Enregistreur de fond (variante personnelle seulement) : petit programme séparé, embarqué dans l'app puis copié par l'app
# hors du paquet (l'installation de l'app ne l'interrompt donc jamais). Signature ad hoc propre : l'autorisation du micro
# est au nom de « Enregistreur Cours », et ne change que si son code change.
if [ "$PERSO" = 1 ]; then
    etape "Enregistreur de fond"
    HELPER="$INTERM/Enregistreur Cours.app"
    rm -rf "$HELPER"; mkdir -p "$HELPER/Contents/MacOS"
    swiftc -O -swift-version 5 -target arm64-apple-macos26.0 "$RACINE/Sources/Helper/main.swift" "$RACINE/Sources/Core/EnregistreurProtocole.swift" \
        -o "$HELPER/Contents/MacOS/Enregistreur" >"$INTERM/enregistreur.log" 2>&1 ||
        { cat "$INTERM/enregistreur.log" >&2; echec "la compilation de l'enregistreur de fond a échoué."; }
    cp "$RACINE/Tools/EnregistreurInfo.plist" "$HELPER/Contents/Info.plist"
    # Les dossiers synchronisés (Bureau, iCloud) rajoutent des attributs Finder : on les retire juste avant de signer, avec quelques essais.
    SIGNE=0
    for essai in 1 2 3 4 5; do
        xattr -cr "$HELPER" 2>/dev/null || true
        if codesign --force -s - "$HELPER" >>"$INTERM/enregistreur.log" 2>&1; then SIGNE=1; break; fi
        sleep 1
    done
    [ "$SIGNE" = 1 ] || echec "la signature de l'enregistreur de fond a échoué (dossier synchronisé ? essaie COMPLETE_COURS_BUILD=\$HOME/cc-build ./build.sh ...)."
    mkdir -p "$NOUVELLE/Contents/Resources/Enregistreur"
    ditto "$HELPER" "$NOUVELLE/Contents/Resources/Enregistreur/Enregistreur Cours.app"
    info "Enregistreur Cours.app compilé et embarqué."
fi

# --- Signature et vérifications ----------------------------------------------

etape "Signature (ad hoc) et vérifications"
plutil -lint "$NOUVELLE/Contents/Info.plist" >/dev/null || echec "l'Info.plist du paquet n'est pas un fichier plist valide."
[ -x "$NOUVELLE/Contents/MacOS/$EXE_DECLARE" ] || echec "L'exécutable est absent ou non exécutable."
# codesign refuse les attributs étendus (dossiers synchronisés avec iCloud, Bureau…) : on les retire d'abord.
xattr -cr "$NOUVELLE" 2>/dev/null || true
# Note sécurité : la signature reste ad hoc. Pour une distribution large, passer à une identité Developer ID avec
# « --options runtime » (Hardened Runtime) puis notariser (notarytool) ; non fait ici volontairement.
codesign --force --deep -s - "$NOUVELLE" >"$INTERM/signature.log" 2>&1 ||
    { cat "$INTERM/signature.log" >&2; echec "la signature de l'app a échoué."; }
codesign --verify --deep --strict "$NOUVELLE" 2>&1 || echec "la signature de l'app est invalide."
info "Info.plist valide, exécutable présent, signature ad hoc vérifiée."

# L'ancienne version n'est remplacée qu'une fois la nouvelle entièrement prête.
rm -rf "$APP"
mv "$NOUVELLE" "$APP"
# Les dossiers synchronisés (Bureau, iCloud) rajoutent des attributs Finder après le déplacement : on les retire de nouveau.
xattr -cr "$APP" 2>/dev/null || true
codesign --verify --deep --strict "$APP" 2>&1 || {
    sleep 2; xattr -cr "$APP" 2>/dev/null || true
    codesign --verify --deep --strict "$APP" 2>&1 ||
        avertir "la copie dans $SORTIE reçoit des attributs Finder (dossier synchronisé) : sans importance, l'app est vérifiée avant le déplacement et l'installation la copie proprement. Pour éviter ce message : COMPLETE_COURS_BUILD=\$HOME/cc-build ./build.sh ..."
}
VERSION_APP="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
etape "Terminé en $((SECONDS - DEBUT)) s : $NOM_AFFICHE $VERSION_APP"
info "$APP"

# --- Zip de distribution -----------------------------------------------------
# Le zip contient un dossier « Complete-Cours-<version> » avec l'app et LISEZMOI.txt. Il est ensuite extrait dans un
# dossier temporaire pour vérifier ce que recevra le camarade : structure, plist, architecture, signature, secrets,
# et absence du moteur « mon compte ».

if [ "$ZIPPER" = 1 ]; then
    etape "Création du zip de distribution"
    DIST="$RACINE/Distribution"
    NOM_ZIP="$NOM_APP-$VERSION_APP.zip"
    ZIP="$DIST/$NOM_ZIP"
    [ -f "$DIST/LISEZMOI.txt" ] || echec "Fichier introuvable : $DIST/LISEZMOI.txt"
    DOSSIER_ZIP="$NOM_APP-$VERSION_APP"
    PREPA="$INTERM/zip"
    rm -rf "$PREPA"; mkdir -p "$PREPA/$DOSSIER_ZIP"
    ditto "$APP" "$PREPA/$DOSSIER_ZIP/$NOM_APP.app"
    cp "$DIST/LISEZMOI.txt" "$PREPA/$DOSSIER_ZIP/LISEZMOI.txt"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$PREPA/$DOSSIER_ZIP" "$ZIP" || echec "la création du zip a échoué."

    etape "Vérification du zip extrait"
    VERIF="$INTERM/verif-zip"
    rm -rf "$VERIF"; mkdir -p "$VERIF"
    ditto -x -k "$ZIP" "$VERIF" || echec "le zip ne s'extrait pas."
    EXTRAIT="$VERIF/$DOSSIER_ZIP/$NOM_APP.app"
    [ -d "$EXTRAIT" ] || echec "structure inattendue : $DOSSIER_ZIP/$NOM_APP.app est absent du zip."
    [ -f "$VERIF/$DOSSIER_ZIP/LISEZMOI.txt" ] || echec "LISEZMOI.txt est absent du zip."
    for f in Contents/Info.plist Contents/MacOS/$NOM_EXE Contents/Resources/AppIcon.icns; do
        [ -e "$EXTRAIT/$f" ] || echec "$f est absent de l'app extraite."
    done
    plutil -lint "$EXTRAIT/Contents/Info.plist" >/dev/null || echec "l'Info.plist du zip n'est pas valide."
    ARCHI="$(lipo -info "$EXTRAIT/Contents/MacOS/$NOM_EXE" 2>&1)"
    case "$ARCHI" in *"is architecture: arm64") ;; *) echec "l'exécutable n'est pas arm64 seul : $ARCHI" ;; esac
    codesign --verify --deep --strict "$EXTRAIT" 2>&1 || echec "la signature de l'app extraite du zip est invalide."
    # Aucune clé API ni chemin personnel ne doit se trouver dans l'app.
    if LC_ALL=C grep -rEaq 'sk-ant-[A-Za-z0-9_-]{20,}' "$EXTRAIT"; then echec "une clé API semble présente dans l'app !"; fi
    # Le moteur « mon compte » ne doit JAMAIS être dans la version distribuée.
    if LC_ALL=C grep -aq 'ClaudeCodeEngine' "$EXTRAIT/Contents/MacOS/$NOM_EXE"; then
        echec "le moteur « mon compte » (ClaudeCodeEngine) est présent dans le binaire du zip : refus de créer le zip."
    fi
    if LC_ALL=C grep -rFaq "/Users/" "$EXTRAIT"; then
        avertir "des chemins « /Users/... » apparaissent dans l'exécutable (inoffensif, mais ils révèlent le nom d'utilisateur du Mac qui a compilé)."
    fi
    info "Structure, plist, arm64 ($ARCHI), signature ad hoc, moteur « mon compte » absent : OK."
    info "Zip : $ZIP ($(du -h "$ZIP" | cut -f1))"
fi

# --- Installation dans ~/Applications ----------------------------------------

DESTINATION="$APP"
if [ "$INSTALLER" = 1 ]; then
    etape "Installation dans ~/Applications"
    DOSSIER_INSTALL="${HOME:?la variable HOME est vide}/Applications"
    DESTINATION="$DOSSIER_INSTALL/$NOM_APP.app"
    BROUILLON="$DOSSIER_INSTALL/.$NOM_APP.installation"
    ANCIENNE="$DOSSIER_INSTALL/.$NOM_APP.ancienne"
    if pgrep -x "$NOM_EXE" >/dev/null 2>&1; then
        avertir "$NOM_AFFICHE est ouverte : quitte-la (⌘Q) puis relance-la pour utiliser la nouvelle version."
    fi
    mkdir -p "$DOSSIER_INSTALL"
    rm -rf "$BROUILLON" "$ANCIENNE"
    ditto --norsrc --noextattr "$APP" "$BROUILLON"
    xattr -cr "$BROUILLON" 2>/dev/null || true
    codesign --verify --deep --strict "$BROUILLON" || { rm -rf "$BROUILLON"; echec "la copie de l'app est invalide."; }
    # On met l'ancienne version de côté, on installe la nouvelle, puis seulement on supprime l'ancienne.
    if [ -e "$DESTINATION" ]; then mv "$DESTINATION" "$ANCIENNE"; fi
    if ! mv "$BROUILLON" "$DESTINATION"; then
        if [ -e "$ANCIENNE" ]; then mv "$ANCIENNE" "$DESTINATION"; fi
        echec "impossible d'installer l'app dans $DOSSIER_INSTALL (l'ancienne version est conservée)."
    fi
    rm -rf "$ANCIENNE"
    touch "$DESTINATION"
    # Met à jour tout de suite l'icône et le menu « Ouvrir avec », et retire la copie de build/ de ce menu pour
    # ne pas avoir deux fois « Complète-Cours » (sans importance si cela échoue).
    if [ -x "$LSREGISTER" ]; then
        "$LSREGISTER" -f "$DESTINATION" >/dev/null 2>&1 || true
        "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    fi
    info "Installée : $DESTINATION"
    if [ "$PERSO" = 0 ] && [ -e "$DOSSIER_INSTALL/Complète-Cours.app" ]; then
        avertir "une ancienne copie « Complète-Cours.app » existe encore dans ~/Applications ; supprime-la pour éviter la confusion."
    fi
    if [ "$PERSO" = 1 ] && [ -e "$DOSSIER_INSTALL/Complete-Cours-perso.app" ]; then
        avertir "l'ancienne copie « Complete-Cours-perso.app » (avant le changement de nom en « App Perso ») existe encore dans ~/Applications ; supprime-la pour éviter la confusion."
    fi
    if [ -e "/Applications/$NOM_APP.app" ]; then
        avertir "une autre copie existe dans /Applications ; elle n'est pas modifiée (supprime-la pour éviter la confusion)."
    fi
fi

# --- Lancement ---------------------------------------------------------------

if [ "$LANCER" = 1 ]; then
    etape "Lancement"
    if pgrep -x "$NOM_EXE" >/dev/null 2>&1; then
        avertir "$NOM_AFFICHE est déjà ouverte : quitte-la (⌘Q) pour voir la nouvelle version."
    fi
    open "$DESTINATION"
fi

if [ "$INSTALLER" = 0 ] && [ "$LANCER" = 0 ] && [ "$ZIPPER" = 0 ]; then
    printf '\n%s\n' "Pour l'installer dans ~/Applications :  ./build.sh --install"
fi
