# HANDOFF — reprise du travail par une autre IA

(Mis à jour le 2026-11-24. Projet : app Swift/macOS sans Xcode, variante perso « App Perso ». Réponds à Maé en français, tutoiement.)

## Objectif
Dans « Suivi MacBook IA » (onglet « Bonnes affaires »), ajouter deux cartes demandées par Maé :
- **« Acheter maintenant ou attendre ? »** : tendance des prix à partir de l'historique des relevés.
- **« Valeur de revente (estimation) »** : décote d'une génération de puce à l'autre.

## Déjà fait (compile, installé, testé sur offres fabriquées ; interface jamais ouverte)
- `Sources/App/SuiviMacModeles.swift` : modèles favoris (M4 Max 48, M3 Max 48, M2 Max 64 Go), prix du marché et bonnes affaires, badges de changements, alertes (notification via osascript), historique allégé (1 relevé/jour), **échelle de performance** (`SuiviModeles.echelle`, `SuiviEchelon`, optimum avec regard en avant, courbe `historiqueEchelle`), **vitesse d'une IA locale** (`SuiviVitesse`, mesures llama.cpp M2/M3/M4 Max, `SuiviModeleIA` dense + MoE, `SuiviQuant` 4/8 bits, `tient`).
- `Sources/App/SuiviMacStore.swift`, `SuiviMacView.swift` : onglets « Vue d'ensemble / Mes 3 modèles / Bonnes affaires », sélecteurs IA visée + précision + mémoire, annonces de particuliers Leboncoin exclues par défaut de l'échelle.
- Écoute en direct (Lecture*.swift, LectureDirect.swift), correctif du blocage du rangement automatique (`Library.swift` : progression d'indexation isolée + limitée à 2 maj/s).
- Tests unitaires jetables : `/private/tmp/claude-501/-Users-maelehuidoux/3825b3ea-2088-42ff-aa01-7afca6bdad39/scratchpad/e/main.swift` (à recopier en test durable si utile).

## Reste à faire (dans l'ordre)
1. **Tendance (`SuiviModeles`, calcul pur)** : `struct SuiviTendance { pctParSemaine, jours, points, dernier }` + `verdict` (tropTot si jours < 7 ou points < 4 ; baisse si ≤ −1,5 %/sem ; hausse si ≥ +1,5 % ; sinon stable) ; `static func tendance(_ pts: [SuiviCalcul.Point]) -> SuiviTendance?` par régression linéaire (x = jours depuis le premier point, y = prix ; pct = pente × 7 / moyenne × 100 ; nil si < 2 points ou variance nulle). Séries : `serieMediane` de chaque favori (`store.suivisModeles`) et `store.scoreAuFilDuTemps` (meilleur € par Go/s, tous modèles).
2. **Carte « Acheter maintenant ou attendre ? »** dans `sectionAffaires` (SuiviMacView.swift) : une ligne par favori + une ligne globale, avec jours d'historique, tendance en %/semaine, étiquette (Attends / Stable / Prix en hausse / Trop tôt pour conclure). Dire clairement que l'historique actuel est très court (relevés depuis le 21/11). Ajouter une note « Black Friday le 27 novembre : des promos sont fréquentes à cette période » affichée seulement du 20/11 au 02/12 (information, pas une prédiction).
3. **Décote par génération (calcul pur)** : `SuiviDecote { config, ancien, recent, prixAncien, prixRecent, pourcent }` ; `static func decotes(_ offres: [SuiviOffre]) -> [SuiviDecote]` : offres livrables (`regrouper`, livraison ≠ .non), état reconditionné (Apple ou tiers) seulement, groupées par écran|mémoire|stockage puis par puce ; médiane de prix par puce (≥ 2 offres) ; pour chaque couple de générations consécutives présentes (ordre M2 Max, M3 Max, M4 Max, M5 Max), pourcent = (prixRécent − prixAncien) / prixRécent × 100. `decoteMoyenne` = médiane des pourcents. `reventeEstimee(prix, decote) = prix × (1 − decote/100)`.
4. **Carte « Valeur de revente (estimation) »** : décote moyenne par génération et nombre de couples, tableau des couples (config, M4 → M3 : −x %), et pour l'optimum de l'échelle (`store.echelle(avecParticuliers: false, ram: …).optimum`) + les 3 premières bonnes affaires : prix → revente estimée dans 1 génération → perte. Préciser que c'est une approximation (prix d'occasion d'une génération plus ancienne, pas des reventes réelles).
5. Tests (offres fabriquées) pour `tendance` (série décroissante, croissante, trop courte) et `decotes` (2 générations, 1 seule génération → aucune décote) ; puis `./build.sh --personnel --install`.
6. Proposer à Maé une courte liste numérotée d'améliorations (elle choisit par numéros).

## Fichiers touchés
`Sources/App/SuiviMacModeles.swift`, `SuiviMacView.swift`, `SuiviMacStore.swift` (seulement pour le Suivi). Ne touche PAS à : `Sources/Core/Pipeline.swift`, `Analysis.swift`, `AutoIntake.swift`, `ZonePanel.swift`, ni au mode « éval » de Complète-Cours.

## Pièges / décisions déjà prises
- Compilation : `./build.sh --personnel` (≈ 90 s) ; installation : `--install`. Édition de fichiers Swift par script Python : attention aux apostrophes dans les chaînes (écrire le script dans un fichier, pas en ligne de commande). `sed -i` sur macOS demande `''`.
- Historique : `~/Library/Application Support/fr.complete-cours.app.perso/SuiviMac/historique.json` (≈ 4 relevés au 24/11, du 21/11 au 23/11 ; copie avant allègement : `historique-avant-allegement.json`). Ne pas l'écraser.
- Les clés d'offres commencent par le nom de la source (`boulanger|…`, `refurbme|…`, `amazon-DE|…`).
- Le M5 Max n'a aucune mesure de vitesse fiable : toujours marqué « ≈ » (estimation).
- Aucun MacBook Pro n'existe en puce Ultra : l'app prévient (notification) si un apparaît.
- Rien n'est commité ; ne commit pas sans demande de Maé.

## Comment vérifier que c'est fini
`./build.sh --personnel --install` compile sans erreur ; tests ci-dessus verts ; ouvrir App Perso › Suivi MacBook IA › Bonnes affaires : les deux nouvelles cartes s'affichent (avec « trop tôt pour conclure » tant que l'historique est court).

## Consigne pour la nouvelle IA
Lis ce fichier en entier, ne refais pas ce qui est « déjà fait », continue au point 1 de « Reste à faire ».
