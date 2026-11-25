import SwiftUI

// « Fonctionnement » : schémas 3 (les moteurs) et 4 (dépôt automatique).

struct FoncMoteurs: View {
    let numero: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FoncEntete(numero: numero, titre: "Les moteurs d'IA",
                       intro: "Un moteur est l'IA qui écrit les réponses. Tu le choisis dans Réglages › Moteur ; tout le reste (trouver les trous, écrire dans le PDF) se fait toujours sur ton Mac.")
            FoncCase(titre: "Réglages › Moteur", detail: "Le choix est gardé (UserDefaults). Une phrase t'explique ce qui manque si le moteur n'est pas prêt.", fichier: "EngineKind · EngineStatus · EngineFactory", teinte: .gris, symbole: "gearshape")
            FoncRangee(moteurColonnes) {
                FoncCase(titre: "Apple Intelligence", detail: "Sur le Mac, gratuit, hors ligne. Il ne lit que le texte de la page (pas l'image), une page à la fois, et sa mémoire est petite.", fichier: "AppleEngine.swift (FoundationModels)", teinte: .vert, symbole: "apple.logo")
                FoncCase(titre: "Claude avec ta clé API", detail: "Il lit l'image et le texte de chaque page (3 pages en même temps). Payé à l'usage. Modèles : Opus 5.5, Sonnet 5.5, Haiku 5.5 ; Opus 5.5 au départ.", fichier: "ClaudeEngine.swift · Keychain.swift", teinte: .orange, symbole: "key")
                #if COMPTE_PERSO
                FoncCase(titre: "Claude « mon compte »", detail: "Pas de clé : l'app lance le programme officiel claude en mode texte, avec ton abonnement. Aucun outil, dossier de travail vide effacé après.", fichier: "ClaudeCodeEngine.swift", teinte: .violet, symbole: "person.crop.circle")
                #endif
            }
            FoncTitre(texte: "Ce qui reste sur le Mac, ce qui part")
            FoncRangee(2, branches: false) {
                FoncCase(titre: "Reste sur le Mac", detail: "Détection des zones, règles de type, OCR, index de recherche, écriture dans le PDF, ta clé (trousseau), Apple Intelligence en entier.", teinte: .vert, symbole: "lock.shield")
                FoncCase(titre: "Part chez Anthropic", detail: "Seulement quand tu demandes : les pages (image et texte) à compléter ; un début de page pour ranger ; le texte d'un cours pour sa fiche ; la page et les exemples pour un schéma.", teinte: .orange, symbole: "paperplane")
            }
            FoncTitre(texte: "Qui peut faire quoi")
            FoncCase(titre: "Compléter : les trois moteurs. Le reste : Claude seulement.",
                     detail: "Fiches, évaluations, rangement (Analyser, dépôt automatique) et fiche d'un cours écouté ont besoin d'une réponse structurée : Apple Intelligence ne sait pas, l'app te le dit.",
                     fichier: "StructuredGenerator · AnalysisEngine.generator", teinte: .gris, symbole: "list.bullet.clipboard")
            FoncTitre(texte: "Opus 5.5 et les schémas électriques")
            FoncCase(titre: "Les schémas utilisent toujours Opus 5.5",
                     detail: "Jamais un autre modèle, jamais Apple Intelligence, aucun repli. Il faut ta clé API" + foncSuffixeSchemas + " Opus 5.5 est aussi le modèle choisi au départ pour compléter, mais là tu peux en changer.",
                     fichier: "SchemaEngine.swift", teinte: .orange, symbole: "bolt.horizontal")
            #if COMPTE_PERSO
            FoncTitre(texte: "OmniRoute (côté Claude Code seulement)")
            FoncCase(titre: "Un relais local pour l'outil Claude Code",
                     detail: "OmniRoute est réglé dans Claude Code, l'outil de développement, pas dans cette app. Le moteur à clé API parle directement à api.anthropic.com. Pour « mon compte », l'app retire les variables ANTHROPIC_* de l'environnement avant de lancer claude.",
                     fichier: "ClaudeEngine.defaultBaseURL · sanitizedEnvironment", teinte: .violet, symbole: "arrow.triangle.branch")
            #endif
            FoncNote(texte: "Les moteurs Claude n'écrivent dans aucun journal ta clé, tes pages ou les réponses. Les erreurs sont notées en texte seulement (schéma 9).")
                .padding(.top, 8)
        }
    }

    private var moteurColonnes: Int {
        #if COMPTE_PERSO
        return 3
        #else
        return 2
        #endif
    }
}

let foncSuffixeSchemas: String = {
    #if COMPTE_PERSO
    return " ou ton compte Claude."
    #else
    return "."
    #endif
}()

// MARK: - 4. Dépôt automatique

struct FoncDepot: View {
    let numero: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FoncEntete(numero: numero, titre: "Le dépôt automatique",
                       intro: "L'app surveille un dossier (Téléchargements par défaut) et range toute seule les nouveaux PDF de cours. C'est désactivé tant que tu ne l'allumes pas (Bibliothèque › Dépôt automatique…).")
            FoncCase(titre: "1. Un PDF arrive dans le dossier surveillé", detail: "Premier niveau du dossier seulement. L'app attend que le fichier soit stable (3 s) et ignore les téléchargements en cours (.crdownload, .part…). Chaque fichier est traité une seule fois.", fichier: "FolderWatcher.swift", teinte: .bleu, symbole: "tray.and.arrow.down")
            FoncFlecheCentre()
            FoncCase(titre: "2. Filtre vie privée, sur ton Mac", detail: "Un nom ou un début de page qui ressemble à une pièce personnelle (IBAN, e-mail, téléphone, facture, billet, contrat…) : le fichier reste où il est et n'est jamais envoyé.", fichier: "PrivacyGate", teinte: .rouge, symbole: "hand.raised")
            FoncFlecheCentre()
            FoncRangee(2) {
                FoncCase(titre: "Évaluation", detail: "Reconnue par le nom ou l'en-tête : rangée d'après son nom, son contenu n'est jamais lu ni envoyé.", teinte: .gris)
                FoncCase(titre: "Cours", detail: "Le nom et un court extrait de la première page partent vers l'IA.", teinte: .orange)
            }
            FoncFusion(n: 2)
            FoncCase(titre: "3. L'IA répond : est-ce un cours ? dans quel dossier ?", detail: "Elle choisit parmi les dossiers qui existent. Il faut un moteur Claude. Un nom de scan (« Scan2026… », « IMG_… ») est remplacé, un nom que tu as choisi est gardé.", fichier: "AutoIntakeProcessor", teinte: .orange, symbole: "sparkles")
            FoncRangee(4) {
                FoncCase(titre: "Rangé", detail: "Déplacé dans le bon dossier.", teinte: .vert)
                FoncCase(titre: "Pas de dossier", detail: "Il reste où il est… sauf si l'option ci-dessous est cochée.", teinte: .gris)
                FoncCase(titre: "Pas un cours", detail: "Il reste, on n'y touche plus.", teinte: .gris)
                FoncCase(titre: "IA indisponible", detail: "Il attend ; bouton « Réessayer ».", teinte: .rouge)
            }
            FoncTitre(texte: "L'option « Créer un dossier si aucun ne convient »")
            FoncCase(titre: "Un nouveau sous-dossier, jamais une nouvelle matière", detail: "Exemple : un cours « Chantier 7 » dans Atelier Professionnel reçoit son propre sous-dossier. Sans l'option, seul un dossier déjà existant est permis.", fichier: "autoIntakeCreerDossiers", teinte: .violet, symbole: "folder.badge.plus")
            FoncTitre(texte: "Après le rangement")
            FoncCase(titre: "Journal des rangements", detail: "Chaque déplacement est écrit (d'où, vers où, quand). Il survit au redémarrage.", fichier: "CourseLedger · journal.json", teinte: .gris, symbole: "list.bullet.rectangle")
            FoncFlecheCentre()
            FoncRangee(2) {
                FoncCase(titre: "Notification", detail: "Nom du fichier et dossier, avec le bouton « Annuler le rangement ». Si les notifications sont refusées : un bandeau dans l'app.", fichier: "AutoIntake · AutoIntakeBanner", teinte: .bleu)
                FoncCase(titre: "Historique", detail: "« Historique des rangements » : annuler un fichier ou tout, plus tard.", fichier: "MoveHistory", teinte: .bleu)
            }
            FoncNote(texte: "Annuler remet le fichier à sa place d'origine ; si quelque chose empêche de le faire, l'app explique pourquoi et ne touche à rien. Rien n'est jamais supprimé.")
                .padding(.top, 8)
        }
    }
}
