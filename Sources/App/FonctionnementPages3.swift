import SwiftUI

// « Fonctionnement » : schémas 5 (écouter un cours) et 6 (schémas électriques).

struct FoncEcoute: View {
    let numero: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FoncEntete(numero: numero, titre: "Écouter un cours",
                       intro: "Tu appuies sur « Commencer le cours », tu poses le Mac, et à la fin tu reçois une fiche. Le son ne quitte jamais ton Mac : seul le texte, après ta relecture, part vers l'IA.")
            FoncCase(titre: "1. Le micro", detail: "macOS demande l'autorisation la première fois. Pause possible. L'écoute s'arrête toute seule après 10 min de silence ou 2 h.", fichier: "LectureRecorder · LectureAudio.swift", teinte: .bleu, symbole: "mic")
            FoncRangee(2) {
                FoncCase(titre: "Texte en direct (à l'écran)", detail: "Le moteur de dictée de macOS 26 écrit au fil de l'eau, en français, sur le Mac. Sert à l'affichage : rien n'est gardé.", fichier: "LectureDirect · SpeechAnalyzer", teinte: .bleu)
                FoncCase(titre: "Morceaux enregistrés", detail: "Le son est coupé en morceaux de 10 min. Chacun est transcrit sur le Mac, puis le fichier audio est effacé.", fichier: "LectureModel.recevoirMorceau", teinte: .bleu)
            }
            FoncRangee(2, branches: false) {
                VStack(spacing: 0) {
                    FoncFlecheCentre(legende: "option (activée) : toutes les 2 min environ, si assez de nouveau texte")
                        .padding(.bottom, 4)
                    FoncCase(titre: "Analyse en direct par l'IA", detail: "Un point rapide pendant le cours (celle des Réglages).", fichier: "LectureAnalyseSerie", teinte: .orange, symbole: "sparkles")
                }
                VStack(spacing: 0) {
                    FoncFlecheCentre(legende: "texte définitif")
                        .padding(.bottom, 4)
                    FoncCase(titre: "Corrections et voix", detail: "Liste « faux = juste », mots proches du lexique. Qui parle : prof, élève ? ou incertain.", fichier: "LectureTexte.corriger · LectureVoix", teinte: .vert, symbole: "person.wave.2")
                }
            }
            FoncNote(texte: "Voix : la voix qui parle le plus aux premiers cours est retenue comme celle du prof (256 nombres, pas de son). Jamais d'empreinte d'élève. Le calcul passe par l'outil optionnel voice.py ; sans lui, seul le sens du texte aide.")
                .padding(.top, 6)
            FoncFlecheCentre(legende: "bouton « Terminer »")
            FoncCase(titre: "2. Fin du cours", detail: "L'app attend les derniers morceaux (délai maximal : elle ne bloque jamais) et fait l'analyse finale.", fichier: "LectureFin.swift", teinte: .gris, symbole: "stop.circle")
            FoncFlecheCentre()
            FoncCase(titre: "3. Tu relis", detail: "Tu décoches les phrases à ne pas envoyer : elles ne partent jamais chez l'IA.", fichier: "statut « À relire »", teinte: .violet, symbole: "checklist")
            FoncFlecheCentre(legende: "les prénoms de la classe deviennent « un élève »")
            FoncCase(titre: "4. L'IA trie puis écrit la fiche", detail: "Elle ne renvoie que les numéros des phrases à retirer (bavardage, remarques à un élève) : le texte du prof n'est jamais réécrit. Puis fiche, puis seconde passe qui vérifie que chaque définition, formule et devoir est bien dans le cours. Il faut un moteur Claude.", fichier: "LecturePipeline.traiter · LecturePrompts", teinte: .orange, symbole: "sparkles")
            FoncRangee(2) {
                FoncCase(titre: "Fiche prête", detail: "Résumé, devoirs, définitions, formules, « à vérifier ». Copier, enregistrer, ou en faire une fiche de révision.", fichier: "LectureFiche", teinte: .vert)
                FoncCase(titre: "En attente", detail: "Limite atteinte ou pas de connexion : nouvel essai tout seul dans 10 min. Le texte est gardé.", teinte: .rouge)
            }
            FoncNote(texte: "Tout est gardé dans Lecture.json (Application Support). Si l'app est fermée en plein cours, le cours redevient « à relire » au prochain lancement.")
                .padding(.top, 8)
        }
    }
}

// MARK: - 6. Schémas électriques

/// Petit dessin d'une grille avec un interrupteur et une lampe reliés par un fil (illustration, pas un vrai schéma).
struct FoncGrilleDemo: View {
    @Environment(\.foncPalette) private var p

    var body: some View {
        Canvas { ctx, taille in
            let cols = 12, rangs = 5
            let u = min(taille.width / CGFloat(cols), taille.height / CGFloat(rangs))
            let largeur = u * CGFloat(cols), hauteur = u * CGFloat(rangs)
            let x0 = (taille.width - largeur) / 2
            var grille = Path()
            for i in 0...cols { grille.move(to: CGPoint(x: x0 + CGFloat(i) * u, y: 0)); grille.addLine(to: CGPoint(x: x0 + CGFloat(i) * u, y: hauteur)) }
            for j in 0...rangs { grille.move(to: CGPoint(x: x0, y: CGFloat(j) * u)); grille.addLine(to: CGPoint(x: x0 + largeur, y: CGFloat(j) * u)) }
            ctx.stroke(grille, with: .color(p.trait(.gris).opacity(0.35)), lineWidth: 0.6)

            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x0 + x * u, y: y * u) }
            let encre = p.trait(.bleu)
            // fil du haut et du bas
            var fil = Path()
            fil.move(to: pt(2, 0.6)); fil.addLine(to: pt(2, 1.2))
            fil.move(to: pt(2, 3.2)); fil.addLine(to: pt(2, 4.4)); fil.addLine(to: pt(10, 4.4)); fil.addLine(to: pt(10, 3.6))
            fil.move(to: pt(2, 0.6)); fil.addLine(to: pt(10, 0.6)); fil.addLine(to: pt(10, 1.4))
            ctx.stroke(fil, with: .color(encre), lineWidth: 1.6)
            // interrupteur (lame inclinée)
            var inter = Path()
            inter.move(to: pt(2, 1.2)); inter.addLine(to: pt(2.9, 2.9))
            inter.move(to: pt(2, 2.9)); inter.addLine(to: pt(2, 3.2))
            ctx.stroke(inter, with: .color(encre), lineWidth: 1.6)
            // lampe (cercle barré)
            let c = pt(10, 2.5)
            let r = u * 1.1
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(encre), lineWidth: 1.6)
            var croix = Path()
            let d = r * 0.7
            croix.move(to: CGPoint(x: c.x - d, y: c.y - d)); croix.addLine(to: CGPoint(x: c.x + d, y: c.y + d))
            croix.move(to: CGPoint(x: c.x - d, y: c.y + d)); croix.addLine(to: CGPoint(x: c.x + d, y: c.y - d))
            ctx.stroke(croix, with: .color(encre), lineWidth: 1.6)
            var fils2 = Path()
            fils2.move(to: pt(10, 1.4)); fils2.addLine(to: CGPoint(x: c.x, y: c.y - r))
            fils2.move(to: CGPoint(x: c.x, y: c.y + r)); fils2.addLine(to: pt(10, 3.6))
            ctx.stroke(fils2, with: .color(encre), lineWidth: 1.6)
        }
        .frame(height: 100)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(p.fond(.gris)))
        .accessibilityLabel("Illustration : une grille sur laquelle un interrupteur et une lampe sont placés et reliés par des fils.")
    }
}

struct FoncSchemas: View {
    let numero: Int
    @Environment(\.foncPalette) private var p
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FoncEntete(numero: numero, titre: "Les schémas électriques",
                       intro: "Pour une zone « Schéma électrique », l'IA ne dessine pas : elle choisit des symboles normalisés, dit où les poser sur une grille et comment les relier. C'est l'app qui trace, donc les symboles sont toujours justes.")
            FoncCase(titre: "1. Tu marques la zone", detail: "Tu changes le type de la zone en « Schéma électrique » (ou tu ajoutes une zone à la main, ⇧⌘N). Ce n'est jamais deviné par l'IA, et jamais traité comme du texte.", fichier: "ZoneKind.schema · ZoneRow", teinte: .violet, symbole: "person.fill.checkmark")
            FoncFlecheCentre()
            FoncCase(titre: "2. Des exemples (facultatif)", detail: "Réglages › Schémas : jusqu'à \(SchemaExemples.maximum) pages de cours où le schéma est déjà juste. À chaque demande, 3 au plus sont montrés : ceux dont le titre ressemble au cours, puis les plus récents.", fichier: "SchemaExemples.swift · SchemaViews.swift", teinte: .gris, symbole: "photo.on.rectangle")
            FoncFlecheCentre()
            FoncCase(titre: "3. La demande envoyée à Opus 5.5", detail: "Trois choses : la page entière avec les numéros de zones, le cadre du schéma sous une grille numérotée, la consigne voisine (+ les exemples).", fichier: "SchemaGrille · SchemaService.construireDemande", teinte: .orange, symbole: "paperplane")
            FoncFlecheCentre(legende: "Opus 5.5 uniquement, une zone après l'autre")
            FoncCase(titre: "4. Opus répond en JSON, sur la grille", detail: "Pas de pixels : une liste de symboles (type, position, rotation 0/90/180/270, repère comme Q1 ou KM1), de fils (de → vers, avec des points de passage) et de textes, plus une phrase de remarque.", fichier: "SchemaElectrique · SchemaContract.swift", teinte: .orange, symbole: "curlybraces")
            FoncGrilleDemo().padding(.top, 8)
            Text("{ \"symboles\": [ { \"id\": \"Q1\", \"type\": \"interrupteur\", \"x\": 2, \"y\": 2, \"label\": \"Q1\" } ], \"fils\": [ { \"de\": \"Q1.b\", \"vers\": \"3.5,2\" } ] }")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.discret)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            FoncFlecheCentre(legende: "lecture tolérante, puis tout est ramené dans la grille")
            FoncCase(titre: "5. Dessin vectoriel", detail: "\(SchemaSymbolType.allCases.count) symboles du catalogue (phase, disjoncteur, interrupteur, va-et-vient, lampe, contacteur, moteur, transformateur, voltmètre…), norme CEI 60617 (NF EN 60617), tracés en vectoriel dans le cadre de la zone.", fichier: "SchemaSymbols · SchemaRenderer", teinte: .vert, symbole: "bolt.horizontal")
            FoncRangee(2) {
                FoncCase(titre: "Schéma dessiné", detail: "Miniature et remarque dans la liste des zones. « Redessiner » pour recommencer.", fichier: "Zone.schema · SchemaThumbnail", teinte: .vert)
                FoncCase(titre: "Erreur sur cette zone", detail: "Réponse illisible, réseau, rien dessiné… : message sur la zone, le schéma précédent est gardé, les autres zones continuent.", fichier: "Zone.error", teinte: .rouge)
            }
            FoncFusion(n: 2)
            FoncCase(titre: "6. Export toujours aplati", detail: "Le schéma est intégré à la page du PDF, quel que soit le réglage « Aplatir ».", fichier: "SchemaAnnotation.aplatir", teinte: .gris, symbole: "square.and.arrow.up")
            FoncNote(texte: "Sans clé API" + foncSansCompte + ", la fonction est indisponible et l'app te l'explique. Confidentialité : la page du cours et les exemples sont envoyés à Anthropic seulement au moment où tu demandes un schéma.")
                .padding(.top, 8)
        }
    }
}

let foncSansCompte: String = {
    #if COMPTE_PERSO
    return " ni compte Claude"
    #else
    return ""
    #endif
}()
