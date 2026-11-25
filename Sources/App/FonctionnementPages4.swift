import SwiftUI

// « Fonctionnement » : schémas 7 (Suivi MacBook IA, version perso), 8 (données et vie privée) et 9 (diagnostic).

#if COMPTE_PERSO
struct FoncSuiviMac: View {
    let numero: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FoncEntete(numero: numero, titre: "Suivi MacBook IA",
                       intro: "Version perso seulement. L'app relève les prix des MacBook Pro à puce Max chez \(SuiviSource.toutes.count) sources, garde l'historique et te prévient quand une bonne offre apparaît. Aucune IA n'est nécessaire pour le relevé.")
            FoncTitre(texte: "Trois façons de lancer un relevé")
            FoncRangee(3, branches: false) {
                FoncCase(titre: "À la main", detail: "Bouton « Vérifier les prix maintenant ».", fichier: "SuiviMacStore", teinte: .violet, symbole: "hand.tap")
                FoncCase(titre: "Au lancement", detail: "Quand tu ouvres l'app (réglage, activé au départ).", fichier: "releveAuLancement", teinte: .violet, symbole: "power")
                FoncCase(titre: "Tous les jours à 9 h", detail: "Une tâche launchd lance « App Perso --suivi-releve » sans fenêtre.", fichier: "fr.suivi-macbook-ia · SuiviMacCLI", teinte: .violet, symbole: "clock")
            }
            FoncNote(texte: "L'app ne crée pas cette tâche de 9 h : elle vérifie seulement qu'elle est chargée (Diagnostic) et te le dit sinon (Mac éteint ou en veille à 9 h : pas de relevé).")
                .padding(.top, 4)
            FoncFusion(n: 3)
            FoncCase(titre: "Le relevé : \(SuiviSource.toutes.count) sources en même temps", detail: "Apple reconditionné (plusieurs pays), LDLC, Materiel.net, Boulanger, Fnac, Darty, MediaMarkt, Amazon, Leboncoin, Kleinanzeigen, Okamac… Une page qui échoue n'arrête pas les autres ; la source n'est en erreur que si aucune de ses pages n'a pu être lue.", fichier: "SuiviReleveur.releverTout · SuiviMacSources", teinte: .bleu, symbole: "network")
            FoncRangee(2) {
                FoncCase(titre: "Lecture simple", detail: "Le texte de la page est lu par une fonction qui en tire les offres : MacBook Pro puce Max, 36, 48 ou 64 Go (le 64 Go sert au M2 Max suivi).", fichier: "SuiviLecteurs", teinte: .bleu)
                FoncCase(titre: "Lecture par WebKit", detail: "Pour les sites qui bloquent la lecture simple : page chargée dans une fenêtre invisible, comme une visite normale. Un test « robot » fait échouer ce site seulement.", fichier: "SuiviMacWebKit", teinte: .bleu)
            }
            FoncFusion(n: 2)
            FoncCase(titre: "Historique", detail: "Un relevé par jour (les relevés du jour sont fusionnés) ; au-delà de 90 jours, un par semaine. Une copie est faite avant d'alléger, un fichier illisible est mis de côté.", fichier: "SuiviMac/historique.json", teinte: .gris, symbole: "tray.full")
            FoncFlecheCentre(legende: "calculs sans réseau")
            FoncRangee(3) {
                FoncCase(titre: "Notes", detail: "Note de rentabilité : prix face au marché (médiane du même modèle) et bande passante face aux offres au même prix. Les offres trop basses sont marquées suspectes.", fichier: "SuiviMacModeles · SuiviMacAnalyse", teinte: .vert)
                FoncCase(titre: "Tranches", detail: "Meilleure offre pour l'IA locale sous 2 500, 3 000, 3 500, 4 000 et 4 500 €, pour 36 et 48 Go.", fichier: "SuiviCalcul.paliers", teinte: .vert)
                FoncCase(titre: "Mes 3 modèles", detail: "Trois modèles favoris suivis de près (réglables). Au départ : M4 Max 48 Go, M3 Max 48 Go, M2 Max 64 Go.", fichier: "SuiviModele.parDefaut", teinte: .vert)
            }
            FoncFlecheCentre(legende: "après chaque relevé, même celui de 9 h")
            FoncCase(titre: "Alertes (notifications du Mac)", detail: "Un de tes 3 modèles baisse (seuil réglable, 5 % au départ) ; une puce Ultra apparaît sur un MacBook Pro ; une nouvelle meilleure offre dans une tranche. Envoyées avec osascript, donc sans l'app ouverte.", fichier: "SuiviAlertesMac", teinte: .orange, symbole: "bell")
            FoncNote(texte: "Tu peux aussi saisir à la main une offre d'occasion, et demander à l'IA des Réglages une analyse du marché. Les erreurs de relevé vont dans le journal des bugs (« Suivi MacBook », « Suivi MacBook (9 h) »).")
                .padding(.top, 8)
        }
    }
}
#endif

// MARK: - 8. Données et vie privée

struct FoncDonnees: View {
    let numero: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FoncEntete(numero: numero, titre: "Données et vie privée",
                       intro: "Tout ce que l'app retient est sur ton Mac. Voici où, et ce que ça contient.")
            FoncRangee(2, branches: false) {
                FoncCase(titre: "Trousseau du Mac", detail: "Ta clé API Claude, et rien d'autre. Elle n'est jamais affichée ni écrite dans un fichier ou un journal.", fichier: "Keychain.swift", teinte: .rouge, symbole: "key")
                FoncCase(titre: "Réglages (UserDefaults)", detail: "Moteur, modèle, humanisation, style d'écriture, aplatir, nom / prénom / classe, dossier des cours, dépôt automatique, onglet des Réglages" + foncReglagesPerso + ".", fichier: "Preferences.swift · Pref", teinte: .bleu, symbole: "slider.horizontal.3")
            }
            .padding(.bottom, 8)
            FoncCase(titre: "Dossier de l'app (Application Support/<identifiant de l'app>)", detail: "Le « journal » (rangements annulables, complétions, résumés des cours avec leurs 450 premiers caractères), la mémoire de tes corrections de zones (forme du trou, mot voisin tronqué, jamais de réponse), l'état du dépôt automatique, les cours écoutés (Lecture.json : texte, fiches, voix du prof en 256 nombres), les exemples de schémas (images), la mémoire des fiches de révision, l'historique des bugs" + foncDonneesPerso + ".",
                     fichier: "journal.json · ZoneLearning.json · depot-automatique.json · Lecture.json · schemas-exemples/ · Revision/ · historique-bugs.json", teinte: .bleu, symbole: "externaldrive")
                .padding(.bottom, 8)
            FoncRangee(2, branches: false) {
                FoncCase(titre: "Index de recherche", detail: "Le texte des pages de tes cours (OCR des 4 premières pages d'un scan), pour chercher un mot. 100 % local, jamais d'IA.", fichier: "Application Support/Complete-Cours/ContentIndex.json", teinte: .bleu, symbole: "magnifyingglass")
                FoncCase(titre: "Temporaire", detail: "Les morceaux audio du cours, effacés dès que leur texte existe.", fichier: "LectureModel", teinte: .gris, symbole: "clock.arrow.circlepath")
            }
            FoncTitre(texte: "Jamais")
            FoncRangee(3, branches: false) {
                FoncCase(titre: "Évaluations", detail: "Jamais lues pour l'index, jamais envoyées, jamais mémorisées.", teinte: .rouge, symbole: "nosign")
                FoncCase(titre: "PDF d'origine", detail: "Jamais modifié. Les doublons vont à la Corbeille, jamais supprimés pour de bon.", teinte: .rouge, symbole: "doc.badge.ellipsis")
                FoncCase(titre: "Son du cours", detail: "Jamais envoyé : la transcription se fait sur le Mac.", teinte: .rouge, symbole: "mic.slash")
            }
            FoncTitre(texte: "Ce qui part vers Anthropic, et seulement sur ta demande")
            FoncCase(titre: "Pages à compléter, début de page pour ranger, texte relu d'un cours, page d'un schéma", detail: "Avec Apple Intelligence : rien ne part, mais il ne fait pas tout (schéma 3). Le dépôt automatique ne lit pas les pièces personnelles (schéma 4).", teinte: .orange, symbole: "paperplane")
            FoncNote(texte: "Le journal des bugs garde seulement le texte des erreurs : jamais le contenu d'un cours ni d'un document. Il remplace le nom de ton dossier personnel par « ~ » et garde les 300 dernières erreurs. L'index de recherche, lui, contient du texte de cours : il est seulement sur ton Mac.")
                .padding(.top, 8)
        }
    }
}

let foncReglagesPerso: String = {
    #if COMPTE_PERSO
    return ", réglages du moteur « mon compte », du Suivi MacBook (modèles favoris, alertes)"
    #else
    return ""
    #endif
}()

let foncDonneesPerso: String = {
    #if COMPTE_PERSO
    return " et l'historique du Suivi MacBook (SuiviMac/)"
    #else
    return ""
    #endif
}()

// MARK: - 9. Diagnostic

struct FoncDiagnostic: View {
    let numero: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FoncEntete(numero: numero, titre: "Diagnostic et historique des bugs",
                       intro: "Quand quelque chose ne marche pas, Réglages › Diagnostic dit quoi, pourquoi, et que faire. Rien n'y part sur Internet.")
            FoncRangee(2, branches: false) {
                FoncCase(titre: "Vérifications (bouton « Relancer »)", detail: "Dossier des cours, moteur choisi (configuration seulement, sans appel réseau), dictée en français, micro, dépôt automatique, index de recherche, dossier de données, espace disque, bugs des dernières 24 h" + foncDiagPerso + ".", fichier: "BackendDiagnostic.lancer", teinte: .vert, symbole: "checkmark.circle")
                FoncCase(titre: "Historique des bugs", detail: "Chaque erreur de l'app est notée : date, d'où elle vient, message. La même erreur répétée dans l'heure n'ajoute qu'une ligne (×N).", fichier: "BugJournal.swift", teinte: .orange, symbole: "ladybug")
            }
            FoncTitre(texte: "Les trois états d'une vérification")
            FoncRangee(3, branches: false) {
                FoncCase(titre: "OK", detail: "Tout va bien (ou réglage choisi par toi).", teinte: .vert, symbole: "checkmark.circle.fill")
                FoncCase(titre: "Attention", detail: "À surveiller : micro pas encore demandé, peu d'espace disque…", teinte: .orange, symbole: "exclamationmark.triangle.fill")
                FoncCase(titre: "Problème", detail: "Il faut agir : dossier introuvable, moteur non prêt, dictée absente…", teinte: .rouge, symbole: "xmark.octagon.fill")
            }
            FoncTitre(texte: "D'où viennent les bugs notés")
            FoncCase(titre: "Complétion · Schémas · Dépôt automatique · Écoute · Écoute (cours) · Écoute en direct" + foncSourcesBugsPerso,
                     detail: "Seul le texte de l'erreur est gardé (jamais le contenu d'un cours), 300 caractères au plus, et les 300 dernières erreurs.", teinte: .gris, symbole: "list.bullet")
            FoncFlecheCentre(legende: "pour chaque bug : cause probable et remède")
            FoncCase(titre: "Conseil automatique", detail: "D'après les mots de l'erreur : limite d'utilisation atteinte, pas de réseau, accès refusé par macOS, micro, dictée absente, clé API refusée, dossier déplacé, disque plein, réponse illisible de l'IA.", fichier: "BugJournal.conseil(pour:)", teinte: .vert, symbole: "lightbulb")
            FoncFlecheCentre()
            FoncRangee(2, branches: false) {
                FoncCase(titre: "Copier le rapport", detail: "Vérifications + historique en texte, pour le montrer à quelqu'un.", teinte: .bleu, symbole: "doc.on.doc")
                FoncCase(titre: "Vider l'historique", detail: "Efface la liste des bugs (rien d'autre).", teinte: .gris, symbole: "trash")
            }
            FoncNote(texte: "Un fichier de données abîmé n'est jamais écrasé en silence : il est mis de côté (« .corrompu ») et l'app repart de zéro.")
                .padding(.top, 8)
        }
    }
}

let foncDiagPerso: String = {
    #if COMPTE_PERSO
    return ", dernier relevé du Suivi MacBook et tâche de 9 h"
    #else
    return ""
    #endif
}()

let foncSourcesBugsPerso: String = {
    #if COMPTE_PERSO
    return " · Analyse du suivi · Suivi MacBook · Suivi MacBook (9 h)"
    #else
    return ""
    #endif
}()
