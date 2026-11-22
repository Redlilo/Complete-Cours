# Complète-Cours

Application Mac (macOS 26 ou plus récent, puce Apple) qui complète tes PDF de cours : fiches avec pointillés,
définitions, questions ouvertes, tableaux et formulaires.

1. Tu ouvres un PDF de cours.
2. L'app **trouve les zones à remplir** et les numérote sur la page.
3. Une IA **écrit les réponses**.
4. Les textes à trous et les définitions restent exacts ; seules les réponses aux questions ouvertes peuvent être humanisées.
5. Tu relis et corriges, puis tu enregistres une copie complétée.

Tout est en français. Ton PDF d'origine n'est jamais modifié : le résultat est enregistré dans un nouveau fichier.

## Installation

Il faut seulement les outils de ligne de commande d'Apple, pas Xcode : `xcode-select --install` si tu ne les as pas.

```
cd ~/Desktop/Projets/Complete-Cours
./build.sh --install
```

Le script compile l'app, fabrique `build/Complete-Cours.app`, la signe, puis la copie dans `~/Applications` en
remplaçant l'ancienne version (`/Applications` n'est pas touché). Compte environ une minute.

| Commande | Effet |
|---|---|
| `./build.sh` | compile et crée `build/Complete-Cours.app`, sans l'installer |
| `./build.sh --install` | idem, puis installe dans `~/Applications` |
| `./build.sh --personnel` | variante **personnelle** avec le moteur « Claude (mon compte) » : app `Complete-Cours-perso.app` (« Complète-Cours (perso) »), à ne pas distribuer ; combinable avec `--install` et `--run`, incompatible avec `--zip` |
| `./build.sh --zip` | idem, puis crée `Distribution/Complete-Cours-<version>.zip` (app + `LISEZMOI.txt`) et vérifie le zip extrait |
| `./build.sh --run` | idem, puis lance l'app (avec `--install` : lance la copie installée) |
| `./build.sh --clean` | supprime l'app et les fichiers intermédiaires de `build/` |
| `./build.sh --aide` | affiche l'aide |

Pour mettre l'app à jour, relance `./build.sh --install` (quitte d'abord l'app avec ⌘Q si elle est ouverte).
Pour la désinstaller, glisse-la de `~/Applications` à la corbeille ; pour tout effacer, supprime aussi
`~/Library/Preferences/fr.complete-cours.app.plist` et l'élément « complete-cours » du Trousseau d'accès (ta clé).

### Donner l'app à un camarade

`./build.sh --zip` fabrique un zip pour un autre Mac Apple Silicon sous macOS 26 ou plus, sans rien à compiler pour lui.
L'app est signée « ad hoc » mais **non notarisée** (pas de compte développeur payant) : macOS la bloque au premier
lancement et il faut l'autoriser une fois. Les démarches sont expliquées dans `Distribution/LISEZMOI.txt`, qui est
aussi placé dans le zip. Chacun utilise **sa propre clé API** : aucune clé n'est dans l'app. Le zip ne contient jamais
le moteur « Claude (mon compte) » (`--zip` vérifie son absence dans le binaire et refuse sinon).

## Premier lancement

1. Ouvre **Complète-Cours** : Spotlight (⌘Espace), ou `open ~/Applications/Complete-Cours.app`. Tu peux la garder dans
   le Dock (clic droit sur son icône, Options, Garder dans le Dock).
2. macOS peut demander l'autorisation d'accéder au dossier **Bureau** (ou Documents, Téléchargements) : accepte, c'est
   là que sont tes cours.
3. Ouvre les **Réglages** (⌘,) et choisis le moteur d'écriture (voir ci-dessous). Tu y règles aussi le style d'écriture
   (bleu imprimé, noir imprimé ou manuscrit), l'humanisation, et ton nom, prénom et classe pour les champs d'identité.

## Choisir le moteur : Claude ou Apple Intelligence

| | **Claude** | **Apple Intelligence** |
|---|---|---|
| Prix | payant à l'usage (clé API) | gratuit |
| Internet | nécessaire | non, tout se passe sur ton Mac |
| Précision | la meilleure : l'IA voit l'image de la page (schémas, tableaux, scans) | moins précise : elle ne lit que le texte de la page (les scans sont lus par la reconnaissance de texte du Mac) |
| Vitesse | plusieurs pages à la fois | une page à la fois, plus lent |
| Ce qui quitte ton Mac | voir ci-dessous | rien |

**Claude.** Il faut une clé API, qui est différente d'un abonnement claude.ai (Pro ou Max ne donnent **pas** de
clé API) : elle se crée sur console.anthropic.com, et l'usage est facturé sur des crédits que tu achètes (règle une limite
de dépense mensuelle dans la console). Colle-la dans Réglages, onglet
*Moteur* : elle est rangée dans le **trousseau** de ton Mac et nulle part ailleurs (ni fichier, ni préférences, ni
journal). Tu peux choisir le modèle : *Opus* est le plus précis (choisi par défaut), *Sonnet* coûte environ deux fois
moins cher, *Haiku* est le moins cher mais moins précis.

**Ce qui est envoyé à Anthropic** (seulement avec Claude, directement de ton Mac vers `api.anthropic.com` en HTTPS,
sans serveur intermédiaire) :

- pour chaque page qui contient des zones : l'**image de la page** (avec les numéros des zones dessinés dessus), le
  **texte** de la page, le nom du fichier (sans `.pdf`), le numéro de la page et la date du jour ;
- ton **nom, prénom et classe**, seulement si tu les as écrits dans les Réglages (ils servent uniquement à remplir les
  champs d'identité) ;
- pour l'humanisation : les réponses aux questions ouvertes, avec la consigne qui les précède ;
- pour **ranger et analyser tes cours** (« Ajouter », « Analyser », dépôt automatique) : le **nom** du fichier et les
  **450 premiers caractères de sa première page**, jamais le PDF entier. Les **évaluations** (nom, dossier ou en-tête
  qui les annonce) ne sont jamais lues par l'IA : elles sont rangées d'après leur nom seulement. Le dépôt automatique
  ignore en plus ce qui ressemble à une pièce personnelle (facture, IBAN, e-mail, passeport…) ;
- pour les **fiches de révision, cartes mémoire et questions** : le texte (et l'image) des pages du cours ouvert, plus ta
  consigne libre si tu en écris une.

Le fichier PDF lui-même n'est pas envoyé, mais ce qui est écrit sur ses pages à compléter l'est. Évite donc les
documents qui contiennent des informations personnelles que tu ne veux pas partager. Ta clé n'est envoyée qu'à
Anthropic, pour s'identifier.

**Apple Intelligence.** Il faut un Mac compatible, avec Apple Intelligence activée (voir Dépannage). Si elle est
prête, c'est le moteur proposé au départ. Rien ne sort de ton Mac.

## Les parties de l'app (⌘1 à ⌘5)

- **Mes cours** : tous tes PDF rangés comme dans ton dossier `Cours`, avec vignettes, aperçu, « Reprendre où tu étais »,
  recherche par nom **et dans le contenu** (index local), **Ajouter** un cours (lu puis rangé tout seul, annulable),
  **Analyser** (propose de ranger/renommer et de compléter les cours qui ont encore des trous), **Doublons** (lit tous
  les PDF et met à la Corbeille, après ta validation, ce qui est identique ou presque), **Ranger les originaux vides**
  (menu « … » ou menu *Cours* : le PDF vide d'un cours complété va dans `_Originaux avant completion`, même
  arborescence), **Historique des rangements** (annuler un rangement, même après un redémarrage) et **Dépôt
  automatique** d'un dossier surveillé (désactivé tant que tu ne l'actives pas ; notification avec « Annuler »).
- **Compléter un cours** : voir *Utilisation* ci-dessous. L'interrupteur « Humaniser les réponses aux questions » est en
  haut du panneau, avec le ton *Style élève* ou *Précis*.
- **Fiches de révision** : fiche de synthèse (consigne libre possible), cartes mémoire (retournables, export PDF
  imprimable) et questions d'entraînement corrigées.
- **Évaluations** : corrigé d'une évaluation **déjà rendue et notée**, pour comprendre tes erreurs. L'app ne complète
  jamais une évaluation. Le bilan montre les questions fausses en premier, et « Cartes à partir de mes erreurs » en fait des
  cartes mémoire sans appel à l'IA.
- **Écouter un cours** (⌘5) : enregistre le cours, retire les remarques aux élèves, fait la fiche (copiable ou en PDF).

La fiche, les cartes, les questions et le corrigé d'un PDF sont gardés : en le rouvrant, tu les retrouves sans
nouvel appel à l'IA (tant que le PDF n'a pas changé).

Rien n'est supprimé définitivement : les doublons vont à la Corbeille, les rangements se défont depuis l'historique.

## Utilisation

1. **Ouvre un PDF** : ⌘O, ou glisse-le sur la fenêtre ou sur l'icône du Dock, ou clic droit sur un PDF dans le
   Finder, *Ouvrir avec*, Complète-Cours. L'app n'est jamais choisie comme lecteur par défaut : ton lecteur
   habituel reste celui du double-clic.
2. **Les zones sont cherchées** automatiquement : champs de formulaire, pointillés et soulignés dans le texte, lignes
   et cases vides dessinées ou scannées. Elles sont numérotées sur l'aperçu et listées. Tu peux en ignorer, changer
   leur type (mot à compléter, définition, question ouverte) ou en ajouter une en dessinant un rectangle sur la page.
3. **Compléter** (⌘R) : l'IA écrit les réponses, avec une barre de progression. Tu peux annuler : les réponses
   déjà obtenues sont gardées. Pour refaire une seule zone, utilise *Régénérer* (ou *Réessayer* si elle a échoué).
4. **Relis et corrige.** Modifie le texte directement dans la liste : l'aperçu suit. Les réponses qui ne rentrent pas
   dans leur zone sont signalées. Relis toujours : l'IA peut se tromper, et c'est toi qui rends le travail.
5. **Enregistre** (⌘S) : l'app crée un PDF complété, sous un nouveau nom. Le PDF d'origine n'est jamais remplacé.

## L'humanisation

Après avoir écrit les réponses, l'app peut **réécrire les réponses aux questions ouvertes avec des mots plus simples et
plus naturels**, comme tu les écrirais toi-même (phrases courtes, pas de formules d'IA). Les **définitions** et les
**mots à compléter** (textes à trous, valeurs, unités, cases à cocher) ne sont **jamais réécrits** : ils restent exacts.

Un garde-fou refuse toute réécriture qui change un nombre, qui devient beaucoup trop longue ou trop courte, ou qui
ajoute du balisage : l'app garde alors la réponse d'origine. Dans la liste, une réponse humanisée peut être remplacée
par son texte d'origine. Tu peux couper l'humanisation dans les Réglages.

## Limites connues

- **Pages tournées** : seules les pages à l'endroit sont analysées. Pour une page tournée, l'app l'indique ; remets-la à
  l'endroit dans Aperçu (Outils, Pivoter), enregistre, puis rouvre le PDF.
- **Scans très penchés, froissés, très pâles ou de mauvaise qualité** : des lignes ou des cases peuvent être manquées ou
  mal placées. Ajoute alors les zones à la main (dessine un rectangle sur la page).
- **PDF protégés par un mot de passe** : non lus. Ouvre-les dans Aperçu et exporte une copie sans mot de passe.
- Dans l'écran « Compléter », un seul PDF à la fois ; pour plusieurs cours, utilise « Analyser » dans « Mes cours »
  (complétion en lot, avec estimation du coût avant de lancer).
- Les questions qui demandent une information sur toi (stage, entreprise, avis personnel) sont ignorées : l'IA ne peut
  pas les connaître, écris-les toi-même.
- Avec Apple Intelligence, les schémas et les images ne sont pas vus, seulement le texte.

## Mode `--selftest`

L'exécutable peut être lancé **sans fenêtre et sans aucune question** (les confirmations sont acceptées d'office), pour
vérifier de bout en bout qu'une version fraîchement compilée fonctionne : analyse d'un PDF, complétion, enregistrement.
Il sert aux tests, pas au travail de tous les jours :

```
~/Applications/Complete-Cours.app/Contents/MacOS/Complete-Cours --selftest
```

## Dépannage

**« Je n'arrive pas à ouvrir un PDF du Bureau. »** Réglages Système, *Confidentialité et sécurité*, *Fichiers et
dossiers* : coche *Bureau* (et *Documents*, *Téléchargements* si besoin) pour Complète-Cours. Si tu avais refusé la
demande la première fois, c'est ici qu'on la corrige. L'app est signée localement : après une mise à jour, macOS peut
redemander l'autorisation.

**« Le trousseau demande une autorisation, ou refuse l'accès à la clé. »** Si macOS demande d'autoriser
Complète-Cours à utiliser le trousseau, choisis *Toujours autoriser*. Si le trousseau est verrouillé, déverrouille-le
(ferme puis rouvre ta session). Pour repartir de zéro : dans *Trousseau d'accès*, cherche « complete-cours », supprime
l'élément, puis colle de nouveau ta clé dans les Réglages.

**« La clé Claude est refusée. »** Vérifie qu'elle est complète (sans espace), qu'elle vient bien d'un compte API (pas de
l'abonnement claude.ai) et qu'il reste des crédits sur ce compte.

**« Apple Intelligence n'est pas disponible. »** Ouvre Réglages Système, *Apple Intelligence et Siri*, active-la puis
laisse macOS finir de télécharger ses modèles (cela peut prendre un moment). Il faut un Mac compatible et une langue
prise en charge. Sinon, choisis Claude dans les Réglages.

**« `./build.sh` : permission refusée. »** Lance `bash build.sh --install`, ou `chmod +x build.sh` une fois.

**« swiftc est introuvable » ou « les outils de ligne de commande sont trop anciens ».** Installe-les ou mets-les à
jour : `xcode-select --install`, ou Réglages Système, Général, Mise à jour de logiciels.

**« macOS bloque l'app (non notarisée). »** Ouvre l'app une fois (elle est bloquée), puis Réglages Système,
*Confidentialité et sécurité*, section *Sécurité*, *Ouvrir quand même*. Autre méthode :
`xattr -dr com.apple.quarantine /Applications/Complete-Cours.app`. Une app compilée sur le Mac même n'est pas concernée.

## Pour aller plus loin

`ARCHITECTURE.md` décrit le code (cœur dans `Sources/Core`, interface dans `Sources/App`), les outils de test de
`Tools/` et les contraintes (compilation avec `swiftc` seul, mode langage Swift 5). `Resources/Info.plist` décrit l'app
pour macOS, et `Tools/make_icon.swift` dessine l'icône (`build.sh` la refait quand ce fichier change).

## Tests

`Tools/run_all_tests.sh` compile et lance toutes les suites de `Tools/Tests/` (une ligne PASS ou FAIL par suite, code de
sortie non nul en cas d'échec ; journaux dans `build/tests/`). `--avec-apple` ajoute le banc d'essai Apple Intelligence
(lent), et on peut nommer des suites : `Tools/run_all_tests.sh Pipeline Renderer`. Aucun test n'appelle le réseau (le moteur
Claude est testé contre un faux serveur local).
