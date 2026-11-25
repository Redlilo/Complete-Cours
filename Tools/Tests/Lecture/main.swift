import Foundation
setvbuf(stdout, nil, _IONBF, 0)

// Tests de « Écouter un cours » (Sources/Core/Lecture.swift) : texte, fiche, stockage. Aucun micro, aucun réseau.
var echecs = 0, total = 0
func verifie(_ condition: Bool, _ nom: String) {
    total += 1
    if !condition { echecs += 1; print("ÉCHEC : \(nom)") }
}

// Prénoms
let r = LectureReglages()
verifie(LectureTexte.retirerPrenoms("Lucas, range ton téléphone. lucas aussi.", prenoms: ["Lucas"]) == "un élève, range ton téléphone. un élève aussi.", "prénom remplacé, casse ignorée")
verifie(LectureTexte.retirerPrenoms("Lucasfilm et Lucas-Marie", prenoms: ["Lucas"]).contains("Lucasfilm"), "mot plus long conservé")
verifie(LectureTexte.retirerPrenoms("Léa et Léandre", prenoms: ["Léa"]) == "un élève et Léandre", "mot entier seulement")
verifie(LectureTexte.retirerPrenoms("Bonjour", prenoms: ["", "  "]) == "Bonjour", "prénoms vides ignorés")

// Corrections
verifie(LectureTexte.corriger("la loi dôme et l'empère", reglages: r) == "la loi d'Ohm et l'ampère", "liste faux=juste")
var lex = LectureReglages(); lex.corrections = []; lex.lexique = ["résistance", "intensité"]
verifie(LectureTexte.corriger("la résistence", reglages: lex) == "la résistance", "mot proche du lexique corrigé")
verifie(LectureTexte.corriger("la résistance", reglages: lex) == "la résistance", "mot exact inchangé")
verifie(LectureTexte.corriger("la table", reglages: lex) == "la table", "mot sans rapport inchangé")
verifie(LectureTexte.ressemblance("ampère", "empère") > 0.8, "ressemblance ampère/empère")
verifie(LectureTexte.ressemblance("", "") == 1, "ressemblance de deux vides")

// Découpage
let long = (0..<400).map { "Phrase numéro \($0) du cours." }.joined(separator: " ")
let morceaux = LectureTexte.decouper(long, taille: 2000)
verifie(morceaux.count > 1 && morceaux.allSatisfy { $0.count <= 2100 }, "morceaux de taille raisonnable")
verifie(morceaux.joined().replacingOccurrences(of: " ", with: "") == long.replacingOccurrences(of: " ", with: ""), "rien de perdu au découpage")
verifie(LectureTexte.decouper("   ").isEmpty, "texte vide : aucun morceau")

// Phrases horodatées
let mots = [LectureMot(texte: "Bonjour", debut: 1.0, duree: 0.4), LectureMot(texte: "à", debut: 1.5, duree: 0.1), LectureMot(texte: "tous", debut: 1.7, duree: 0.3),
            LectureMot(texte: "Aujourd'hui", debut: 5.0, duree: 0.5)]
let ph = LectureTexte.phrases(depuis: mots, decalage: 600)
verifie(ph.count == 2, "une pause coupe la phrase")
verifie(ph.first?.texte == "Bonjour à tous" && ph.first?.debut == 601.0, "décalage du morceau ajouté")
verifie(abs((ph.first?.fin ?? 0) - 602.0) < 0.001, "fin de phrase")
verifie(LectureTexte.phrases(depuis: [], decalage: 0).isEmpty, "aucun mot, aucune phrase")

// Réponse de l'IA
let bon = "Voici : {\"titre\":\"Loi d'Ohm\",\"resume\":\"## U\\n- U = R × I\",\"devoirs\":[{\"quoi\":\"Exercice 3\",\"pour\":\"mardi\"}],\"definitions\":[{\"terme\":\"Volt\",\"def\":\"unité\"}],\"formules\":[{\"formule\":\"U = R × I\",\"unite\":\"V\"}],\"a_verifier\":[]} merci"
let f = LectureFiche.depuis(json: bon, titreParDefaut: "x")
verifie(f.titre == "Loi d'Ohm" && f.devoirs.first?.pour == "mardi" && f.definitions.first?.definition == "unité" && f.formules.count == 1, "fiche lue malgré le texte autour")
let mauvais = LectureFiche.depuis(json: "pas du json", titreParDefaut: "Cours du 20/11")
verifie(mauvais.titre == "Cours du 20/11" && !mauvais.aVerifier.isEmpty, "réponse illisible : fiche prudente")
let faux = LectureFiche.depuis(json: "{\"titre\":\"T\",\"devoirs\":\"Aucun\",\"definitions\":[1,2],\"a_verifier\":5}", titreParDefaut: "x")
verifie(faux.titre == "T" && faux.devoirs.isEmpty && faux.definitions.isEmpty && faux.aVerifier.isEmpty, "champs mal typés ignorés")

// Schémas : objets stricts
func strict(_ s: [String: Any]) -> Bool {
    guard (s["type"] as? String) == "object", let p = s["properties"] as? [String: Any], let req = s["required"] as? [String] else { return false }
    return (s["additionalProperties"] as? Bool) == false && Set(req) == Set(p.keys)
}
verifie(strict(LecturePrompts.ficheSchema) && strict(LecturePrompts.verificationSchema), "schémas stricts (fiche, vérification)")
verifie(((LecturePrompts.triSchema["properties"] as? [String: Any])?["retirer"] as? [String: Any])?["type"] as? String == "array", "schéma du tri : liste de numéros")
verifie(LecturePrompts.triNumerote("[0] abc", lexique: ["VLAN"]).contains("VLAN") && LecturePrompts.fiche("abc", matiere: "Maths", prof: "", jour: "vendredi").contains("Maths"), "prompts remplis")

// Stockage
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lecture-test-\(UUID().uuidString).json")
defer { try? FileManager.default.removeItem(at: tmp) }
let store = LectureStore(url: tmp)
verifie(store.charger().cours.isEmpty, "fichier absent : base vide")
var base = LectureBase()
var c1 = LectureCours(titre: "Ohm", matiere: "Électricité", prof: "M. Test", statut: .pret)
c1.fiche = f; c1.traiteLe = Date().addingTimeInterval(-30 * 86400); c1.phrases = [LecturePhrase(debut: 0, fin: 1, texte: "secret")]
var c2 = LectureCours(titre: "En cours", matiere: "Maths", prof: "", statut: .enregistrement)
var c3 = LectureCours(titre: "Traitement", matiere: "Maths", prof: "", statut: .traitement); c3.phrases = [LecturePhrase(debut: 0, fin: 1, texte: "a")]
base.cours = [c1, c2, c3]; base.reglages.prenoms = ["Lucas"]
store.sauver(base)
var relu = store.charger()
verifie(relu.cours.count == 3 && relu.reglages.prenoms == ["Lucas"] && relu.cours[0].fiche?.titre == "Loi d'Ohm", "aller-retour de la base")
let permsLecture = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.posixPermissions] as? Int) ?? -1
verifie(permsLecture == 0o600, "Lecture.json en 0600 (obtenu \(String(permsLecture, radix: 8)))")
verifie(relu.cours[1].statut == .erreur, "enregistrement interrompu sans texte : erreur")
verifie(relu.cours[2].statut == .enAttente, "traitement interrompu : remis en attente")
LectureStore.nettoyer(&relu)
verifie(relu.cours[0].phrases.isEmpty && relu.cours[0].fiche != nil, "texte brut effacé après 7 jours, fiche gardée")

// Agenda
let ag = LectureTexte.agenda(relu.cours)
verifie(ag.count == 1 && ag[0].devoir.quoi == "Exercice 3", "agenda des devoirs")


// Tri par numéros : réponse de l'IA et garde-fous
let rep = LectureTexte.retraits(json: "ok {\"retirer\":[{\"n\":2,\"motif\":\"discipline\"},{\"n\":\"5\",\"motif\":\"\"},{\"x\":1}]}")
verifie(rep.count == 2 && rep[0].n == 2 && rep[0].motif == "discipline" && rep[1].n == 5, "numéros à retirer lus (entier ou texte), entrées invalides ignorées")
verifie(LectureTexte.retraits(json: "pas du json").isEmpty && LectureTexte.retraits(json: "{\"retirer\":5}").isEmpty, "réponse illisible : rien n'est retiré")
let ph10 = ["Bonjour à tous.", "Lucas, range ton téléphone.", "La tension est égale à la résistance multipliée par l'intensité, donc nous allons voir un exemple.",
            "Pour mardi vous ferez l'exercice trois page quarante-deux, notez-le dans votre cahier.", "Madame je peux sortir ?", "Euh oui.", "Voilà.", "Reprenons.", "Ok.", "Bien."]
let res = LecturePipeline.appliquerRetraits(textes: ph10, retraits: [(1, "discipline"), (4, "élève"), (3, "à tort"), (42, "hors morceau")], morceau: Array(0..<10), lexique: [])
verifie(res.retires[1] == "discipline" && res.retires[4] == "élève", "remarque et question d'élève retirées")
verifie(res.retires[3] == nil, "la consigne de devoirs du prof n'est jamais retirée")
verifie(res.retires[42] == nil && res.retires.count == 2 && res.alerte == nil, "numéro hors du morceau ignoré")
let tropFort = LecturePipeline.appliquerRetraits(textes: ph10, retraits: (0..<9).map { ($0, "") }, morceau: Array(0..<10), lexique: [])
verifie(tropFort.retires.isEmpty && tropFort.alerte != nil, "l'IA veut tout retirer : tri ignoré et signalé")
verifie(LecturePipeline.appliquerRetraits(textes: ["a", "b"], retraits: [(0, ""), (1, "")], morceau: [0, 1], lexique: []).retires.count == 2, "petit morceau : le garde-fou ne s'applique pas")

// Vérification de la fiche
let ficheV = LectureFiche(titre: "T", resume: "", devoirs: [LectureDevoir(quoi: "Exercice 3", pour: "mardi")],
                          definitions: [LectureDefinition(terme: "Volt", definition: "unité"), LectureDefinition(terme: "Ohm", definition: "unité R")],
                          formules: [LectureFormule(formule: "U = R × I", unite: "V")], aVerifier: [])
let notes = LecturePipeline.notesDeVerification("{\"non_soutenus\":[{\"type\":\"definition\",\"numero\":2,\"raison\":\"jamais dite\"},{\"type\":\"formule\",\"numero\":1,\"raison\":\"unité ajoutée\"},{\"type\":\"devoir\",\"numero\":9,\"raison\":\"x\"}]}", fiche: ficheV)
verifie(notes.count == 2 && notes[0].contains("Ohm") && notes[1].contains("U = R × I"), "éléments non soutenus transformés en notes, numéro invalide ignoré")
verifie(LecturePipeline.notesDeVerification("n'importe quoi", fiche: ficheV).isEmpty, "vérification illisible : aucune note")
verifie(LecturePrompts.verification(cours: "cours", fiche: ficheV).contains("2. Ohm"), "prompt de vérification numéroté")

// Dates des devoirs (le cours a lieu un vendredi 20 novembre 2026)
var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Paris")!
let vendredi = cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 10))!
func jourDe(_ d: Date?) -> Int? { d.map { cal.component(.day, from: $0) } }
verifie(jourDe(LectureTexte.dateDuDevoir("mardi", depuis: vendredi, calendrier: cal)) == 24, "« mardi » : mardi 24")
verifie(jourDe(LectureTexte.dateDuDevoir("jeudi prochain", depuis: vendredi, calendrier: cal)) == 26, "« jeudi prochain » : jeudi 26")
verifie(jourDe(LectureTexte.dateDuDevoir("Vendredi", depuis: vendredi, calendrier: cal)) == 27, "même jour de la semaine : la semaine suivante")
verifie(jourDe(LectureTexte.dateDuDevoir("demain", depuis: vendredi, calendrier: cal)) == 21 && jourDe(LectureTexte.dateDuDevoir("après-demain", depuis: vendredi, calendrier: cal)) == 22, "demain, après-demain")
verifie(jourDe(LectureTexte.dateDuDevoir("dans 3 jours", depuis: vendredi, calendrier: cal)) == 23, "dans 3 jours")
verifie(LectureTexte.dateDuDevoir("la prochaine fois", depuis: vendredi, calendrier: cal) == nil && LectureTexte.dateDuDevoir("", depuis: vendredi, calendrier: cal) == nil, "pas de date calculable : nil")
var cA = LectureCours(titre: "A", matiere: "Maths", prof: "", statut: .pret)
cA.fiche = LectureFiche(titre: "A", resume: "", devoirs: [LectureDevoir(quoi: "Plus tard", pour: "jeudi", date: cal.date(byAdding: .day, value: 9, to: vendredi)),
                                                          LectureDevoir(quoi: "Bientôt", pour: "mardi", date: cal.date(byAdding: .day, value: 2, to: vendredi)),
                                                          LectureDevoir(quoi: "Sans date", pour: "un jour", date: nil)], definitions: [], formules: [], aVerifier: [])
let ordre = LectureTexte.agenda([cA], aujourdhui: vendredi).map(\.devoir.quoi)
verifie(ordre == ["Bientôt", "Plus tard", "Sans date"], "agenda : le plus proche d'abord, sans date à la fin")

// Corrections apprises à la relecture
verifie(LectureTexte.corrections(entre: "la loi dôme et l'empère", et: "la loi dôme et l'ampère") == ["l'empère=l'ampère"] || LectureTexte.corrections(entre: "la loi dôme et l'empère", et: "la loi dôme et l'ampère") == ["empère=ampère"], "un mot changé : correction retenue")
verifie(LectureTexte.corrections(entre: "la résistence", et: "la résistance") == ["résistence=résistance"], "mot corrigé : retenu sans ponctuation")
verifie(LectureTexte.corrections(entre: "a b c", et: "a b c d").isEmpty && LectureTexte.corrections(entre: "un deux trois quatre", et: "x y z w").isEmpty, "réécriture : rien n'est retenu")
verifie(LectureTexte.corrections(entre: "même phrase", et: "même phrase").isEmpty, "phrase inchangée : rien")

// Voix du prof : apprentissage et étiquettes
func vec(_ graine: UInt64, base: [Float]? = nil, bruit: Float = 0.03) -> [Float] {
    var x = graine &* 6364136223846793005 &+ 1442695040888963407
    var v = (0..<256).map { _ -> Float in
        x = x &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: x >> 11) % 2000) / 1000 - 1
    }
    if let b = base { v = zip(b, v).map { $0 + $1 * bruit } }
    let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return v.map { $0 / n }
}
let voixProf = vec(1), voixEleve1 = vec(2), voixEleve2 = vec(3)
verifie(LectureVoix.cosinus(voixProf, voixProf) > 0.999 && abs(LectureVoix.cosinus(voixProf, voixEleve1)) < 0.4, "cosinus : même voix / voix différentes")
verifie(LectureVoix.qui(score: 0.9) == .prof && LectureVoix.qui(score: 0.72) == .incertain && LectureVoix.qui(score: 0.5) == .autre, "seuils prof / incertain / élève")
verifie(LectureVoix.cosinus([], []) == 0 && LectureVoix.cosinus([1, 0], [1]) == 0, "cosinus : cas vides")

var premier: [LectureVoix.Candidat] = (0..<20).map { LectureVoix.Candidat(vecteur: vec(UInt64(100 + $0), base: voixProf), duree: 5) }
premier += (0..<4).map { LectureVoix.Candidat(vecteur: vec(UInt64(200 + $0), base: voixEleve1), duree: 3) } + (0..<3).map { LectureVoix.Candidat(vecteur: vec(UInt64(300 + $0), base: voixEleve2), duree: 3) }
let appris = LectureVoix.apprendre(candidats: premier, existante: nil)
verifie(appris != nil && LectureVoix.cosinus(appris!.vecteur, voixProf) > 0.9, "la voix dominante est retenue comme celle du prof")
verifie(abs((appris?.secondes ?? 0) - 100) < 0.001, "secondes retenues = seulement celles du prof")
verifie(premier.filter { LectureVoix.qui(score: LectureVoix.cosinus($0.vecteur, appris!.vecteur)) == .prof }.count == 20, "20 phrases du prof reconnues")
verifie(premier.filter { LectureVoix.qui(score: LectureVoix.cosinus($0.vecteur, appris!.vecteur)) == .autre }.count == 7, "7 phrases d'élèves repérées")
verifie(LectureVoix.apprendre(candidats: Array(premier.prefix(4)), existante: nil) == nil, "trop peu de voix (20 s) : rien n'est retenu")
let eleves: [LectureVoix.Candidat] = (0..<10).map { LectureVoix.Candidat(vecteur: vec(UInt64(400 + $0), base: voixEleve1), duree: 4) } + (0..<4).map { LectureVoix.Candidat(vecteur: vec(UInt64(500 + $0), base: voixProf), duree: 5) }
verifie(LectureVoix.apprendre(candidats: eleves, existante: nil)?.secondes == 40, "sans indice sur ce qui est dit, la voix la plus présente est retenue")
let peu: [LectureVoix.Candidat] = (0..<8).map { LectureVoix.Candidat(vecteur: vec(UInt64(600 + $0), base: voixProf), duree: 5) } + (0..<20).map { LectureVoix.Candidat(vecteur: vec(UInt64(700 + $0), base: vec(UInt64(900 + $0 % 5))), duree: 5) }
verifie(LectureVoix.apprendre(candidats: peu, existante: nil) == nil, "le prof ne parle pas assez (moins de 40 % du temps) : rien n'est retenu")
// fusion avec une voix déjà connue
let ancienne = LectureEmpreinte(vecteur: voixProf, secondes: 300, maj: Date())
let suite = (0..<20).map { LectureVoix.Candidat(vecteur: vec(UInt64(1000 + $0), base: voixProf), duree: 5) }
let fusion = LectureVoix.apprendre(candidats: suite, existante: ancienne)
verifie(fusion != nil && abs(fusion!.secondes - 400) < 0.001 && LectureVoix.cosinus(fusion!.vecteur, voixProf) > 0.95, "même voix : l'empreinte est affinée (300 s + 100 s)")
let autreVoix = (0..<20).map { LectureVoix.Candidat(vecteur: vec(UInt64(1200 + $0), base: voixEleve1), duree: 5) }
verifie(LectureVoix.apprendre(candidats: autreVoix, existante: ancienne) == nil, "une autre voix dominante (remplaçant) ne change pas l'empreinte")
verifie(LectureVoix.apprendre(candidats: [], existante: nil) == nil, "aucun candidat : rien")


// Ce qui est dit
let lexTest = ["résistance", "disjoncteur"]
let prof1 = LectureTexte.indiceProf("Pour mardi vous ferez l'exercice trois page quarante-deux, notez bien la formule dans votre cahier.", lexique: lexTest)
let prof2 = LectureTexte.indiceProf("La résistance se mesure en ohms et l'intensité en ampères, donc nous allons voir un exemple.", lexique: lexTest)
let eleve1 = LectureTexte.indiceProf("Madame, je peux aller aux toilettes ?")
let eleve2 = LectureTexte.indiceProf("Euh oui.")
verifie(prof1 >= 0.8 && prof2 >= 0.75, "consigne et explication : très probablement le prof")
verifie(eleve1 <= 0.15 && eleve2 <= 0.3, "« madame, je peux… » et phrase courte : très probablement un élève")
verifie(LectureTexte.indiceProf("", lexique: []) == 0.5 && LectureTexte.indiceProf("Voilà le circuit en série.") > 0.3, "texte vide : on ne sait pas")
verifie(LectureVoix.decider(score: 0.9, indice: 0.5) == .prof && LectureVoix.decider(score: 0.4, indice: 0.5) == .autre, "voix claire : la voix décide")
verifie(LectureVoix.decider(score: 0.72, indice: 0.9) == .prof && LectureVoix.decider(score: 0.72, indice: 0.1) == .autre && LectureVoix.decider(score: 0.72, indice: 0.5) == .incertain, "voix incertaine : ce qui est dit tranche")
verifie(LectureVoix.decider(score: 0.5, indice: 0.9) == .incertain, "consigne du prof avec une voix différente : jamais écartée toute seule")
verifie(LectureVoix.decider(score: 0.9, indice: 0.05) == .incertain, "voix du prof mais paroles d'élève : à vérifier")
verifie(LectureVoix.decider(score: nil, indice: prof1) == .prof && LectureVoix.decider(score: nil, indice: eleve1) == .autre && LectureVoix.decider(score: nil, indice: 0.5) == .incertain, "sans voix mesurable : le texte décide prudemment")
// le texte aide à retrouver le prof quand un élève parle beaucoup
let bavard = (0..<12).map { LectureVoix.Candidat(vecteur: vec(UInt64(2000 + $0), base: voixEleve2), duree: 6, indice: 0.1) }
          + (0..<10).map { LectureVoix.Candidat(vecteur: vec(UInt64(2100 + $0), base: voixProf), duree: 6, indice: 0.9) }
let grace = LectureVoix.apprendre(candidats: bavard, existante: nil)
verifie(grace != nil && LectureVoix.cosinus(grace!.vecteur, voixProf) > 0.9, "un élève bavard (72 s) ne prend pas la place du prof (60 s qui parle comme un prof)")
verifie(LectureVoix.apprendre(candidats: bavard.map { var c = $0; c.indice = 0.5; return c }, existante: nil).map { LectureVoix.cosinus($0.vecteur, voixEleve2) > 0.9 } == true, "…alors que sans indice, la voix la plus présente l'emporterait")

// Stockage des voix et des étiquettes
let tmpVoix = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lecture-voix-\(UUID().uuidString).json")
defer { try? FileManager.default.removeItem(at: tmpVoix) }
let storeVoix = LectureStore(url: tmpVoix)
var baseVoix = LectureBase()
baseVoix.voix = ["M. Test": appris!]
var cv = LectureCours(titre: "Voix", matiere: "Maths", prof: "M. Test", statut: .aRelire)
var phraseEleve = LecturePhrase(debut: 0, fin: 3, texte: "euh")
phraseEleve.qui = .autre; phraseEleve.score = 0.31; phraseEleve.garder = false
cv.phrases = [phraseEleve]
baseVoix.cours = [cv]
storeVoix.sauver(baseVoix)
let reluVoix = storeVoix.charger()
verifie(reluVoix.voix?["M. Test"]?.vecteur.count == 256 && reluVoix.cours[0].phrases[0].qui == .autre && reluVoix.cours[0].phrases[0].garder == false, "voix et étiquettes conservées après relecture du fichier")
verifie(LectureStore(url: URL(fileURLWithPath: "/nonexistent/x.json")).charger().voix == nil, "ancienne base sans voix : lisible")

// attaque : réponses d'analyse en direct invalides ou entourées de texte
verifie(LectureAnalyseDirect.depuis(json: "") == nil && LectureAnalyseDirect.depuis(json: "{") == nil && LectureAnalyseDirect.depuis(json: "[1,2]") == nil, "analyse directe : JSON invalide -> nil, sans plantage")
verifie(LectureAnalyseDirect.depuis(json: "Voici {sans JSON} puis {\"resume\":\"ok\",\"points\":[null,1,\"p\"]}")?.points == ["p"], "analyse directe : accolades avant le JSON")
verifie(LectureAnalyseDirect.depuis(json: String(repeating: "{", count: 50000)) == nil, "analyse directe : 50 000 accolades")

// Fin du cours : derniers morceaux et analyse finale (faux moteurs, aucun micro)
let idCours = UUID()
verifie(LectureFin.cours(deMorceau: URL(fileURLWithPath: "/tmp/ecoute-\(idCours.uuidString)/morceau_0003.caf")) == idCours, "morceau : cours retrouvé par son dossier")
verifie(LectureFin.cours(deMorceau: URL(fileURLWithPath: "/tmp/autre/morceau_0001.caf")) == nil && LectureFin.cours(deMorceau: URL(fileURLWithPath: "/tmp/ecoute-pasunid/m.caf")) == nil, "morceau : dossier inconnu -> nil")

@MainActor func testsFin() async {
    func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
    // Un dernier morceau arrive au moment de terminer : on l'attend et son texte est bien là
    let a = LectureAttente()
    var textes: [String] = []
    a.suivre(idCours, { await pause(150); textes.append("dernier morceau") })
    verifie(a.nombre(idCours) == 1, "attente : morceau compté tout de suite")
    let fini = await a.attendreFin(idCours, delaiMax: .seconds(5))
    verifie(fini && textes == ["dernier morceau"] && a.nombre(idCours) == 0, "attente : le dernier morceau est transcrit avant la fin")
    // Rien à attendre : retour immédiat
    let t0 = ContinuousClock.now
    verifie(await a.attendreFin(UUID(), delaiMax: .seconds(5)) && ContinuousClock.now - t0 < .milliseconds(200), "attente : aucun morceau -> pas d'attente")
    // Morceau bloqué : le délai maximal rend la main (« Terminer » ne bloque jamais), et le morceau finit quand même ensuite
    let b = LectureAttente()
    var tardif = false, apresAppele = false
    b.suivre(idCours, { await pause(700); tardif = true }, apres: { apresAppele = true })
    let t1 = ContinuousClock.now
    let finiB = await b.attendreFin(idCours, delaiMax: .milliseconds(200))
    verifie(!finiB && ContinuousClock.now - t1 < .milliseconds(600) && b.nombre(idCours) == 1, "attente : délai maximal respecté, morceau toujours suivi")
    await pause(900)
    verifie(tardif && apresAppele && b.nombre(idCours) == 0, "attente : le morceau en retard finit et prévient (« apres »)")
    // Deux cours : les morceaux ne se mélangent pas
    let c = LectureAttente(); let autre = UUID()
    c.suivre(autre, { await pause(300) })
    verifie(await c.attendreFin(idCours, delaiMax: .milliseconds(100)) && c.nombre(autre) == 1 && c.total == 1, "attente : un autre cours n'est pas attendu")
    await pause(400)

    // Analyse finale : jamais sautée parce qu'une autre tourne
    var textesVus: [String] = []
    var contenu = "début"
    let s = LectureAnalyseSerie(executer: { textesVus.append(contenu); await pause(200) })
    verifie(s.demander() && s.enCours, "analyse : démarre")
    await pause(30)   // l'analyse a lu le texte de départ
    verifie(!s.demander() && s.lancees == 1, "analyse ordinaire : ignorée si une tourne déjà")
    contenu = "début + fin du cours"
    s.demanderFinale(); s.demanderFinale(); s.demanderFinale()
    verifie(s.enAttente && s.lancees == 1, "analyse finale : mise en attente pendant la précédente")
    await pause(700)
    verifie(s.lancees == 2 && !s.enCours && !s.enAttente && textesVus == ["début", "début + fin du cours"], "analyse finale : lancée après la précédente (une seule fois), avec le texte final")
    // Moteur au repos : la finale part tout de suite
    s.demanderFinale()
    verifie(s.enCours && s.lancees == 3, "analyse finale : immédiate si rien ne tourne")
    await pause(300)
    // Rien à analyser
    let vide = LectureAnalyseSerie(aAnalyser: { false }, executer: { })
    vide.demanderFinale()
    verifie(vide.lancees == 0 && !vide.enCours, "analyse : rien à analyser -> rien lancé")
    // Une analyse qui échoue (le faux moteur ne fait rien) libère quand même la suivante
    var appels = 0
    let f = LectureAnalyseSerie(executer: { appels += 1; await pause(50) })
    f.demander(); f.demanderFinale()
    await pause(300)
    verifie(appels == 2 && !f.enCours, "analyse : la finale part même après une analyse terminée sans résultat")
    // Nouveau cours : la demande en attente de l'ancien est annulée
    let g = LectureAnalyseSerie(executer: { await pause(100) })
    g.demander(); g.demanderFinale(); g.reinitialiser()
    await pause(300)
    verifie(g.lancees == 1, "analyse : réinitialisation annule la finale en attente")
}
await testsFin()


// ---- Vocabulaire, nettoyage, recollage, noms (LectureVocabulaire / LectureNettoyage) ----
let rv = LectureReglages()
verifie(LectureTexte.corriger("il faut un télé rupteur et un disjoncteur différentielle", reglages: rv) == "il faut un télérupteur et un disjoncteur différentiel", "vocabulaire : télé rupteur, différentielle")
verifie(LectureTexte.corriger("trois kilo watts heure en tri phasé", reglages: rv) == "trois kilowattheure en triphasé", "vocabulaire : unités collées")
verifie(LectureTexte.corriger("le v lan et le rj 45", reglages: rv) == "le VLAN et le RJ45", "vocabulaire : réseau")
verifie(LectureTexte.corriger("un conducteur de phase", reglages: rv) == "un conducteur de phase", "conducteur jamais changé en contacteur")
verifie(LectureTexte.corriger("la resistance et la tension", reglages: rv) == "la résistance et la tension", "accent oublié rétabli")
verifie(LectureTexte.corriger("le sectionneur et le contacteur", reglages: rv) == "le sectionneur et le contacteur", "mot juste inchangé")
let francais = "Aujourd'hui nous allons voir comment on organise le travail de la classe. Le professeur explique la consigne, puis chacun écrit dans son cahier. Ensuite on corrige ensemble les exercices du chapitre précédent et on prépare la prochaine séance avec les documents distribués. Un élève demande une explication supplémentaire sur la conclusion du paragraphe et la réponse arrive rapidement, avec un exemple concret tiré de la vie quotidienne des habitants du quartier."
verifie(LectureTexte.corriger(francais, reglages: rv) == francais, "texte français courant : aucune fausse correction")
// contextualStrings
let cs = LectureVocabulaire.contextualStrings(reglages: { var x = LectureReglages(); x.prenoms = ["Léa"]; return x }(), matiere: "Électricité", prof: "M. Dupont")
verifie(cs.contains("télérupteur") && cs.contains("Dupont") && cs.contains("Léa") && !cs.contains("M.") && cs.count <= 400 && Set(cs.map { $0.lowercased() }).count == cs.count, "contextualStrings : termes, prénoms, prof, sans doublon")
// noms
verifie(LectureTexte.retirerPrenoms("Léa, range ton téléphone. LEA aussi, et lea.", prenoms: ["Léa"]) == "un élève, range ton téléphone. un élève aussi, et un élève.", "prénom : accents et casse ignorés")
verifie(LectureTexte.retirerPrenoms("Hélène et Helene", prenoms: ["helene"]) == "un élève et un élève", "prénom saisi sans accent")
verifie(LectureTexte.retirerPrenoms("Merci Monsieur Dupont, Mme Martin et M. Durand-Petit. Madame, je peux ?", prenoms: []) == "Merci le prof, le prof et le prof. Madame, je peux ?", "Madame/Monsieur/M. + nom")
verifie(LectureTexte.retirerPrenoms("Madame Je ne comprends pas", prenoms: []) == "Madame Je ne comprends pas", "Madame + mot courant gardé")
verifie(LectureTexte.retirerPrenoms("Dupont a dit que le petit est là", prenoms: [], prof: "M. Dupont") == "le prof a dit que le petit est là", "nom du prof saisi")
verifie(LectureTexte.retirerPrenoms("c'est un petit schéma", prenoms: [], prof: "Mme Petit") == "c'est un petit schéma", "nom du prof : mot courant en minuscule gardé")
verifie(LectureTexte.motsDuNomDeProf("Mme Dupont-Martin") == ["Dupont-Martin"], "mots du nom du prof")
let envoye = LecturePipeline.retirerPrenomsEtCorriger("Bonjour monsieur Durand. Léa, assieds-toi.", { var x = LectureReglages(); x.prenoms = ["Léa"]; return x }(), prof: "M. Durand")
verifie(!envoye.contains("Durand") && !envoye.contains("Léa") && envoye.contains("le prof") && envoye.contains("un élève"), "texte envoyé à l'IA sans nom ni prénom")
verifie(!LecturePrompts.fiche("abc", matiere: "Maths", prof: "M. Durand", jour: "lundi").contains("Durand"), "prompt de la fiche : nom du prof absent")
// répétitions, bruit
verifie(LectureTexte.retirerRepetitions("le le le le courant passe") == "le courant passe", "répétition d'un mot")
verifie(LectureTexte.retirerRepetitions("on va voir on va voir on va voir la tension") == "on va voir la tension", "répétition d'un groupe de mots")
verifie(LectureTexte.retirerRepetitions("très très bien") == "très très bien", "deux fois : gardé")
verifie(LectureTexte.estBruit("Sous-titrage ST' 501") && LectureTexte.estBruit("...") && !LectureTexte.estBruit("la tension est de 230 volts"), "bruit inventé reconnu")
func ph(_ d: Double, _ f: Double, _ t: String, qui: LectureQui? = nil) -> LecturePhrase { LecturePhrase(debut: d, fin: f, texte: t, qui: qui) }
let net = LectureTexte.nettoyer([ph(0, 2, "Sous-titrage Société Radio-Canada"), ph(3, 6, "la tension est de 230 volts."), ph(7, 10, "la tension est de 230 volts."), ph(12, 13, "ok"), ph(14, 15, "ok")])
verifie(net.map(\.texte) == ["la tension est de 230 volts.", "ok", "ok"], "nettoyer : inventée retirée, phrase redite fusionnée, courtes gardées")
// recollage
let coupe = LectureTexte.recoller([ph(0, 3, "Le courant traverse la"), ph(3.8, 6, "résistance et chauffe."), ph(8, 10, "Ensuite on mesure.")])
verifie(coupe.count == 2 && coupe[0].texte == "Le courant traverse la résistance et chauffe." && coupe[0].fin == 6, "recoller : phrase coupée par une pause")
verifie(LectureTexte.recoller([ph(0, 3, "Il est midi."), ph(3.5, 5, "ensuite on part")]).count == 2, "recoller : phrase finie jamais collée")
verifie(LectureTexte.recoller([ph(0, 3, "On voit que"), ph(10, 12, "la tension")]).count == 2, "recoller : longue pause jamais collée")
verifie(LectureTexte.recoller([ph(0, 3, "On voit que", qui: .prof), ph(3.5, 5, "je sais pas", qui: .autre)]).count == 2, "recoller : deux voix jamais collées")
verifie(LectureTexte.recoller([ph(0, 3, "c'est l'"), ph(3.2, 5, "ampère")])[0].texte == "c'est l'ampère", "recoller : apostrophe sans espace")
let deux = LectureTexte.recoller(coupe)
verifie(deux.map(\.texte) == coupe.map(\.texte), "recoller : idempotent")
// deux morceaux, finis dans le désordre, phrase coupée entre les deux
let m1 = [ph(0, 5, "début du cours."), ph(590, 600, "on additionne les")]
let m2 = [ph(600.5, 605, "intensités dans chaque branche.")]
let tout = LectureTexte.inserer(m1, dans: LectureTexte.inserer(m2, dans: []))
verifie(tout.map(\.texte) == ["début du cours.", "on additionne les intensités dans chaque branche."], "morceaux : ordre du temps et phrase recollée entre deux morceaux")

print(echecs == 0 ? "PASS : \(total) vérifications" : "FAIL : \(echecs) échec(s) sur \(total)")
exit(echecs == 0 ? 0 : 1)
