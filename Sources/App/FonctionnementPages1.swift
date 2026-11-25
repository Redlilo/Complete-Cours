import SwiftUI

// « Fonctionnement » : schémas 1 (vue d'ensemble) et 2 (parcours d'un PDF).

struct FoncVueEnsemble: View {
    let numero: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FoncEntete(numero: numero, titre: "Vue d'ensemble",
                       intro: "L'app lit un PDF de cours, trouve les trous, fait écrire les réponses par une IA, puis te laisse tout relire. Voici les écrans, dans l'ordre de la barre de gauche.")
            FoncTitre(texte: "Les écrans")
            FoncCase(titre: "Bibliothèque  (⌘1)",
                     detail: "Tous tes cours rangés comme sur le disque. Recherche dans le contenu, « Analyser », « Doublons », « Ranger les originaux vides ».",
                     fichier: "Library.swift · LibraryTree · ContentIndex", teinte: .bleu, symbole: "books.vertical")
            FoncRangee(4) {
                FoncCase(titre: "Compléter un cours (⌘2)", detail: "Remplit les trous et les questions.", fichier: "ContentView · CoursModel", teinte: .vert, symbole: "wand.and.stars")
                FoncCase(titre: "Fiches de révision (⌘3)", detail: "Fiche, cartes, entraînement.", fichier: "RevisionView", teinte: .vert, symbole: "graduationcap")
                FoncCase(titre: "Évaluations (⌘4)", detail: "Corrigé d'une éval déjà notée.", fichier: "EvaluationsView", teinte: .vert, symbole: "checkmark.seal")
                FoncCase(titre: "Écouter un cours (⌘5)", detail: "Micro, texte, fiche.", fichier: "LectureView · LectureModel", teinte: .vert, symbole: "waveform")
            }
            #if COMPTE_PERSO
            FoncTitre(texte: "Écrans de la version perso seulement")
            FoncRangee(2, branches: false) {
                FoncCase(titre: "Suivi MacBook IA (⌘6)", detail: "Prix des MacBook Pro Max pour l'IA locale.", fichier: "SuiviMacView", teinte: .violet, symbole: "laptopcomputer")
                FoncCase(titre: "Atlas des skills (⌘7)", detail: "Page HTML de mes skills et outils.", fichier: "AtlasView · Resources/Perso", teinte: .violet, symbole: "map")
            }
            #endif
            FoncTitre(texte: "Ce qui sert à tous les écrans")
            FoncRangee(2, branches: false) {
                FoncCase(titre: "Le moteur d'IA", detail: "Choisi dans Réglages › Moteur : Apple Intelligence ou Claude" + foncSuffixeCompte + ".", fichier: "EngineKind · EngineFactory", teinte: .orange, symbole: "cpu")
                FoncCase(titre: "Schémas électriques", detail: "Un type de zone dans « Compléter » : l'IA dessine, l'app trace.", fichier: "Schema*.swift", teinte: .orange, symbole: "bolt.horizontal")
            }
            .padding(.bottom, 8)
            FoncRangee(3, branches: false) {
                FoncCase(titre: "Dépôt automatique", detail: "Range tout seul les nouveaux PDF de Téléchargements. Désactivé au départ.", fichier: "AutoIntake · FolderWatcher", teinte: .gris, symbole: "tray.and.arrow.down")
                FoncCase(titre: "Réglages  (⌘,)", detail: "Moteur, Écriture, Élève, Schémas, Fonctionnement, Diagnostic.", fichier: "SettingsView", teinte: .gris, symbole: "gearshape")
                FoncCase(titre: "Diagnostic", detail: "Vérifie le « back » et garde l'historique des bugs.", fichier: "Diagnostic · BugJournal", teinte: .gris, symbole: "stethoscope")
            }
            FoncTitre(texte: "Légende")
            FoncLegende(elements: [(.bleu, "ton dossier de cours"), (.vert, "les écrans de travail"), (.orange, "l'IA et ses moteurs"), (.gris, "outils et réglages")]
                        + foncLegendePerso)
            FoncNote(texte: "Les noms en petit (en gris) sont les fichiers du code, pour les curieux. Les menus ont aussi des raccourcis : ⌘R compléter, ⌘O ouvrir, ⇧⌘N ajouter une zone à la main.")
                .padding(.top, 8)
        }
    }
}

/// Suite de phrase pour le moteur : seulement dans la version perso.
let foncSuffixeCompte: String = {
    #if COMPTE_PERSO
    return " (clé ou mon compte)"
    #else
    return " (avec ta clé)"
    #endif
}()

let foncLegendePerso: [(FoncTeinte, String)] = {
    #if COMPTE_PERSO
    return [(.violet, "écrans de la version perso")]
    #else
    return []
    #endif
}()

// MARK: - 2. Parcours d'un PDF

struct FoncParcoursPDF: View {
    let numero: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FoncEntete(numero: numero, titre: "Le parcours d'un PDF",
                       intro: "De l'ouverture du PDF à l'export. Ton PDF d'origine n'est jamais modifié : tout se passe sur une copie.")
            FoncCase(titre: "A. Ouvrir le PDF", detail: "Il est lu page par page.", fichier: "CoursPipeline.openDocument · Pipeline.swift", teinte: .bleu, symbole: "doc")
            FoncFlecheCentre(legende: "chaque page est analysée seule (en parallèle)")
            FoncCase(titre: "B. Trouver les trous (détection)", detail: "Quatre façons de repérer une zone, puis ce que ça donne :", teinte: .bleu, symbole: "viewfinder")
            FoncRangee(4) {
                FoncCase(titre: "Formulaire", detail: "Champs de texte vides du PDF.", fichier: "ZoneDetector", teinte: .bleu)
                FoncCase(titre: "Texte", detail: "Pointillés, soulignés, ( ) vides, « libellé : ».", fichier: "TextLayer", teinte: .bleu)
                FoncCase(titre: "Pixels", detail: "Lignes, pointillés et cadres vides vus dans l'image.", fichier: "PixelZones → ligne, cadre", teinte: .bleu)
                FoncCase(titre: "OCR", detail: "Lit un scan sans texte, seulement si l'IA ne voit pas les images.", fichier: "OCR.swift (Vision)", teinte: .bleu)
            }
            FoncFlecheCentre(legende: "chaque zone a un score de confiance de 0 à 1")
            FoncCase(titre: "C. Mémoire de tes corrections", detail: "Une zone que tu avais ignorée, ajoutée ou dont tu avais changé le type est reconnue. On ne garde que la forme du trou et un bout de texte voisin, jamais de réponse.", fichier: "ZoneLearning.swift", teinte: .gris, symbole: "brain")
            FoncFlecheCentre()
            FoncCase(titre: "D. Choisir le type de chaque zone", detail: "Mot à compléter, définition ou question ouverte. Les règles locales (mots comme « définis », « explique », largeur du trou) proposent un type avec une certitude.", fichier: "ZoneKindRules.swift", teinte: .vert, symbole: "list.bullet.rectangle")
            FoncRangee(3) {
                FoncCase(titre: "Règle sûre (≥ 0,8)", detail: "Le type est imposé, l'IA ne peut pas le changer.", teinte: .vert)
                FoncCase(titre: "Règle pas sûre", detail: "L'IA décide, avec le type proposé comme indication.", teinte: .orange)
                FoncCase(titre: "Ton choix", detail: "Si tu changes un type, il gagne toujours.", teinte: .violet)
            }
            FoncFlecheCentre(legende: "option : l'IA vérifie les zones douteuses")
            FoncCase(titre: "E. Tu relis la liste des zones", detail: "Cocher, ignorer, changer le type, ajouter une zone à la main, ou marquer « Schéma électrique ».", fichier: "ZonePanel · ZoneRow", teinte: .violet, symbole: "person.fill.checkmark")
            FoncFlecheCentre(legende: "bouton « Compléter » (⌘R)")
            FoncCase(titre: "F. L'IA écrit les réponses", detail: "Une demande par page (30 zones au plus ; plusieurs pages en même temps selon le moteur). Chaque réponse est nettoyée avant d'être gardée. Une page en erreur n'arrête pas les autres.", fichier: "CoursPipeline.complete · AnswerCleaner", teinte: .orange, symbole: "sparkles")
            FoncFlecheCentre()
            FoncCase(titre: "G. Humanisation (réglage, activé au départ)", detail: "Seules les questions ouvertes sont réécrites, par lots de 10, pour sonner comme un élève. Si la réécriture change un nombre, une unité, le sens ou la longueur, on garde la réponse d'origine. Mots et définitions restent exacts.", fichier: "HumanizeGuard · Pipeline.swift", teinte: .orange, symbole: "person.wave.2")
            FoncFlecheCentre(legende: "zones « schéma » : Opus 5.5, une par une")
            #if COMPTE_PERSO
            FoncCase(titre: "H. Vérification par Opus (version perso, option)", detail: "Avec le moteur « mon compte » et l'option activée (désactivée au départ), Opus relit chaque page remplie. Il signale les zones vides ou incohérentes ; l'app affiche « N zone(s) à revoir ». Il n'écrit rien dans le PDF.", fichier: "VerificationPass.swift", teinte: .violet, symbole: "checkmark.shield")
            FoncFlecheCentre()
            #endif
            FoncCase(titre: "I. Les réponses sont écrites sur l'aperçu", detail: "Texte bleu (ou noir, ou manuscrit) au-dessus des lignes, ou valeur du champ de formulaire. Tu peux tout corriger, régénérer une zone, annuler.", fichier: "AnswerRenderer.apply", teinte: .vert, symbole: "pencil.line")
            FoncFlecheCentre(legende: "Enregistrer le PDF complété (⌘S)")
            FoncRangee(2) {
                FoncCase(titre: "PDF aplati (réglage, oui au départ)", detail: "Le texte fait partie de la page : impossible de l'effacer ailleurs.", fichier: "SchemaAnnotation.aplatir", teinte: .vert)
                FoncCase(titre: "PDF non aplati", detail: "Les réponses restent des annotations modifiables dans Aperçu.", fichier: "AnswerRenderer.export", teinte: .gris)
            }
            FoncNote(texte: "Un schéma électrique est toujours aplati à l'export. Le lot « Compléter la sélection » (Bibliothèque) fait le même parcours sans fenêtre et écrit « Cours (complétée).pdf » à côté de l'original.")
                .padding(.top, 8)
        }
    }
}
