# Complète-Cours — architecture

Application macOS **native** (SwiftUI + PDFKit, pas de web). Pour un élève de Seconde pro (MTNE), elle complète des
PDF de cours : elle trouve les zones d'un PDF (fiche à trous, questions ouvertes, définitions, tableaux,
formulaires), une IA écrit les réponses, et seules les réponses aux questions ouvertes peuvent être humanisées.
Définitions et textes à trous restent exacts. L'élève relit/corrige, puis exporte une copie complétée. Le document
source n'est jamais modifié.

Tout le texte visible par l'utilisateur (interface, erreurs, prompts) est en **français**.

## Contraintes techniques

- Mac Apple Silicon, **macOS 26.5**, uniquement les *Command Line Tools* (pas de Xcode, pas de SwiftPM, pas
  d'Interface Builder). On compile avec `swiftc` : Swift 6.3 en **mode langage Swift 5**.
- Commande de base : `swiftc -O -swift-version 5 -target arm64-apple-macos26.0 <fichiers.swift> -o <sortie>`
  (ajouter `-parse-as-library` pour une cible contenant `@main`).
- Frameworks : SwiftUI, AppKit, PDFKit, Vision, CoreGraphics/CoreText, FoundationModels (IA locale Apple),
  Security (trousseau). Rien d'externe (aucune dépendance Swift/Python à installer).
- Pas de dépôt git. Dossier du projet : `~/Desktop/Projets/Complete-Cours/`.
- **Jamais** d'appel réseau réel dans les tests (sauf `127.0.0.1`). Jamais de clé API ou de donnée personnelle
  écrite dans le code, les logs ou les fichiers de test.
- Fichiers temporaires : dans le dossier *scratchpad* de la session (indiqué dans ton brief), pas dans `/tmp`.

## Organisation du code

```
Sources/Core/       (module partagé, compilé avec l'app et avec les outils de test)
  Models.swift          Zone, ZoneKind, WritingLine, WritingStyle, CoursError            [Claude principal]
  Engine.swift          CONTRATS : PageRequest, ZoneAnswer, HumanizeItem, EngineError, CompletionEngine,
                        StudentProfile                                                    [Claude principal]
  Prompts.swift         prompts français + schémas JSON                                  [Claude principal]
  Pipeline.swift        CoursPipeline.analyze / .complete, AnswerCleaner, HumanizeGuard   [Claude principal]
  Markers.swift         MarkedImage : image de page avec numéros de zones                 [Claude principal]
  PageImaging.swift, TextLayer.swift, OCR.swift, PixelZones.swift, ZoneDetector.swift
                        détection des zones (champs de formulaire, pointillés du texte, lignes/cadres
                        repérés dans l'image, OCR des scans)                              [Claude principal]
  ClaudeEngine.swift    moteur Claude (API Messages, HTTP direct, images)                 [agent « claude »]
  AppleEngine.swift     moteur Apple Intelligence (FoundationModels, texte seul)          [agent « apple »]
  ClaudeCodeEngine.swift  moteur « Claude (mon compte) » : tout le fichier est sous #if COMPTE_PERSO (absent de la version distribuée)
  AnswerRenderer.swift  écriture des réponses dans le PDF + export                        [agent « rendu »]
Sources/App/        l'application SwiftUI                                                [agent « interface »]
Tools/Harness/      outil CLI de test de la détection (voir plus bas)                    [Claude principal]
Tools/Tests/<x>/    tests propres à chaque agent
build.sh, Resources/, Distribution/LISEZMOI.txt, README.md   empaquetage .app, icône, doc                          [agent « paquet »]
```

**Règle de propriété : ne modifie que les fichiers de ta zone.** Si tu as besoin d'un changement dans un
fichier d'un autre, ne le fais pas : décris-le précisément dans ton rapport final (fichier, ligne, changement).
Les fichiers « Claude principal » peuvent être modifiés pendant que tu travailles : si la compilation échoue
à cause d'eux, attends 30 secondes et recommence ; ne les « répare » pas.
Compile **dans ton propre dossier de sortie** (`build/<ton-nom>/`), jamais dans `build/harness` ni `build/*.app`.

## Modèle de données (résumé — lire Models.swift et Engine.swift pour le détail)

- `Zone` : un trou à remplir. `page` (index 0), `number` (1…n sur la page, = repère ⟦n⟧ dans le texte et numéro
  dessiné sur l'image), `id` (unique dans le document), `source` (formulaire / texte / ligne / cadre / manuel),
  `lines: [WritingLine]` (zones « lignes » : pointillés, soulignés) **ou** `box: CGRect` (cadre, case, champ),
  `contextBefore/After` (texte voisin), `kind` (`mot`, `definition`, `question`, `ignorer`), `answer` (texte final),
  `rawAnswer` (avant humanisation), `humanized`, `enabled`, `overflow`, `error`.
- Coordonnées : **espace page PDF** (points, origine en bas à gauche). Une `WritingLine` est une ligne sur
  laquelle on écrit : `y` = hauteur de la ligne à gauche (`x0`), `yEnd` = hauteur à droite (`x1`) ; elles diffèrent
  pour un scan penché (l'écriture doit alors suivre la pente). Le texte s'écrit **au-dessus** de la ligne.
- Seules les pages sans rotation (`/Rotate 0`) sont analysées pour l'instant.
- `kind.isHumanizable` : seulement `.question`. Les `.definition` et `.mot` ne sont jamais réécrits.

## Comment la détection fonctionne (pour comprendre les données)

1. Champs de formulaire PDF (widgets texte) **vides** → `source = .formulaire`, `box` exacte.
2. Pointillés / underscores dans le texte (couche texte du PDF) → `source = .texte`, `lines`.
3. Lignes, pointillés et cadres vides repérés dans l'image de la page (scans, traits dessinés) → `.ligne` / `.cadre`.
4. Pages scannées : OCR (Vision) seulement si le moteur n'a pas la vision.
5. Le texte de la page est reconstruit avec des repères ⟦n⟧ à la place des trous.

## Outils de test

- `Tools/Harness/main.swift` : `build/harness zones <fichier.pdf> <dossier_sortie> [pages: 1,2] [--ocr] [--blank]`
  écrit une image annotée par page et liste les zones. `--blank` retire les annotations FreeText (les anciennes
  réponses) pour simuler la feuille vierge. Compilation :
  `swiftc -O -swift-version 5 -target arm64-apple-macos26.0 Sources/Core/*.swift Tools/Harness/main.swift -o build/harness`
- PDF de test réels (dossier de l'élève, **lecture seule**, ne jamais les modifier ni les copier hors du scratchpad) :
  `~/Desktop/Cours/…`. Bons exemples :
  - `Économie-Gestion/Mission 1 - Présenter un secteur d'activité (Safran).pdf` : texte + pointillés `……`
    (déjà complété en bleu par endroits)
  - `Co-intervention/Portail - Séance 1 - Découvrir Copilot et charte IA.pdf` (page 2) : formulaire à champs
  - `Français/Objet d'étude 1 - S'informer/Séance 4 - Les fake news.pdf` (avec `--blank`, `--ocr`) : scan penché,
    lignes, tableau
  - `Maths/Cours/Séquence 1 - Statistiques à une variable.pdf` (avec `--blank`) : scan, cadres et tableau
  - `Physique-Chimie/Cours/Le pH.pdf` : scan, lignes pâles
  - `_Originaux avant completion/Atelier Professionnel/Chantier 5/Seance 1.pdf` : scan vierge d'origine
- Ne jamais ouvrir ni traiter les fichiers d'évaluation (dossiers `Eval`, `Évaluations`, fichiers « Contrôle… »,
  « eval… »).

## Style de code

Swift clair, commentaires en français courts et utiles, pas de code mort. Pas de `print` de débogage laissé dans
`Sources/` (utiliser `Tools/` pour les tests). Erreurs destinées à l'utilisateur : phrases françaises complètes
et utiles (que s'est-il passé, que faire).
