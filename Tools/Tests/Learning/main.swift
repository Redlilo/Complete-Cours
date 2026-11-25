import Foundation

// Tests de la mémoire des corrections (ZoneLearning) : signature stable, enregistrement, application,
// fichier abîmé, écriture atomique, jamais d'évaluation. Aucun réseau, dossier temporaire à chaque essai.

var failures = 0, total = 0
func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    total += 1
    if cond { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)  \(detail())") }
}

func tempDir() -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("learning-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func zone(_ id: Int, before: String, after: String = "", width: CGFloat = 200, source: ZoneSource = .texte) -> Zone {
    var z = Zone(id: id, page: 0, number: id, source: source, lines: [WritingLine(x0: 40, x1: 40 + width, y: 600)])
    z.contextBefore = before; z.contextAfter = after
    return z
}

// 1. signature : indépendante du document, stable, sans chiffres ni contenu long
do {
    let z = zone(1, before: "Page 3 sur 12 — Lycée Jean Moulin, année 2026/2027, tous droits réservés")
    let s1 = ZoneSignature(zone: z, documentName: "Fiche TP 04 - Onduleur (complétée).pdf")
    let s2 = ZoneSignature(zone: z, documentName: "Fiche TP 12 - Onduleur")
    check(s1.key == s2.key, "signature : même modèle de document sans numéro ni marque « complétée »", "\(s1.key) / \(s2.key)")
    check(s1.model == "fiche tp onduleur", "nom du modèle sans numéro", s1.model)
    check(ZoneSignature(zone: z, documentName: "Fiche TP 04 - Onduleur").key == s1.key, "signature : déterministe")
    check(s1.neighbor.count <= ZoneSignature.neighborLength && !s1.neighbor.contains(where: { $0.isNumber }), "texte voisin court et sans chiffres", s1.neighbor)
    check(s1.neighbor == "tous droits reserves" || s1.neighbor.hasSuffix("droits reserves"), "texte voisin = fin de la consigne, sans accents", s1.neighbor)
    let other = ZoneSignature(zone: z, documentName: "Cours Réseaux")
    check(other.key != s1.key, "signature : un autre modèle de document donne une autre signature")
    let wider = ZoneSignature(zone: zone(1, before: z.contextBefore, width: 500), documentName: "Fiche TP 04 - Onduleur")
    check(!wider.matches(s1), "signature : une autre largeur ne correspond pas")
    let near = ZoneSignature(zone: zone(1, before: z.contextBefore, width: 206), documentName: "Fiche TP 04 - Onduleur")
    check(near.matches(s1), "signature : largeur à 1 cran près = même zone")
    check(ZoneSignature(zone: zone(1, before: "x", source: .ligne), documentName: "a").key != ZoneSignature(zone: zone(1, before: "x", source: .texte), documentName: "a").key, "signature : la source compte")
    check(ZoneSignature(zone: zone(1, before: "", after: ""), documentName: "a").isLearnable == false, "sans texte voisin : pas mémorisable")
    check(ZoneSignature(zone: zone(1, before: "", after: "Résistance électrique"), documentName: "a").isLearnable, "texte après seulement : mémorisable")
}

// 2. enregistrer, relire, appliquer
do {
    let dir = tempDir()
    let mem = ZoneLearning(directory: dir)
    check(mem.count == 0, "mémoire vide au départ")
    let footer = zone(1, before: "Document de travail — usage interne", width: 480)
    let label = zone(2, before: "Schéma de l'installation :", width: 150)
    let typed = zone(3, before: "Cite un appareil de protection", width: 230)
    let added = zone(4, before: "Remarques et observations", width: 300)
    mem.recordIgnored(footer, documentName: "Fiche TP 04 - Onduleur")
    mem.recordKind(.definition, for: typed, documentName: "Fiche TP 04 - Onduleur")
    mem.recordConfirmed(added, documentName: "Fiche TP 04 - Onduleur")
    check(mem.count == 3, "3 corrections retenues", "\(mem.count)")
    check(FileManager.default.fileExists(atPath: mem.fileURL.path), "fichier écrit")

    // un autre jour : la mémoire est relue depuis le fichier
    let again = ZoneLearning(directory: dir)
    check(again.count == 3, "rechargée depuis le fichier", "\(again.count)")
    var zones = [zone(10, before: "Document de travail — usage interne", width: 482),   // pied de page (à 2 pt près)
                 zone(11, before: "Schéma de l'installation :", width: 150),             // jamais corrigé
                 zone(12, before: "Cite un appareil de protection", width: 230),
                 zone(13, before: "Remarques et observations", width: 300)]
    zones[3].confidence = 0.4
    let applied = again.apply(to: &zones, documentName: "Fiche TP 07 - Onduleur (complétée)")
    check(zones[0].kind == .ignorer && !zones[0].enabled, "pied de page : ignoré comme d'habitude")
    check(zones[1].kind == .question && zones[1].enabled, "zone jamais corrigée : intacte (kind \(zones[1].kind))")
    check(zones[2].kind == .definition, "type préféré appliqué", "\(zones[2].kind)")
    check(zones[3].confidence >= 0.9 && zones[3].enabled, "zone ajoutée à la main d'habitude : confiance relevée")
    check(applied.count == 3 && applied.first(where: { $0.zoneID == 10 })?.trace == "Ignorée comme d'habitude", "trace visible « Ignorée comme d'habitude »", "\(applied)")
    check(applied.contains { $0.zoneID == 12 && $0.trace.contains("comme d'habitude") }, "trace du type préféré")

    // autre modèle de document : rien ne s'applique
    var elsewhere = [zone(20, before: "Document de travail — usage interne", width: 480)]
    check(again.apply(to: &elsewhere, documentName: "Cours Réseaux").isEmpty && elsewhere[0].kind == .question, "autre modèle de document : aucune correction appliquée")

    // la dernière correction l'emporte : ignorer puis rétablir avec un type
    again.recordKind(.mot, for: footer, documentName: "Fiche TP 04 - Onduleur")
    var z2 = [zone(30, before: "Document de travail — usage interne", width: 480)]
    _ = again.apply(to: &z2, documentName: "Fiche TP 05 - Onduleur")
    check(z2[0].kind == .mot && z2[0].enabled && again.count == 3, "dernière correction retenue, pas de doublon", "\(z2[0].kind) \(again.count)")

    // les zones dessinées à la main ne sont pas touchées
    var manual = [zone(40, before: "Remarques et observations", width: 300, source: .manuel)]
    manual[0].confidence = 0.3
    check(again.apply(to: &manual, documentName: "Fiche TP 05 - Onduleur").isEmpty, "zone manuelle : laissée")

    // oublier
    again.forgetAll()
    check(again.count == 0 && !FileManager.default.fileExists(atPath: again.fileURL.path), "oublier : mémoire et fichier vidés")
    check(ZoneLearning(directory: dir).count == 0, "oublier : rien au rechargement")
    var after = [zone(50, before: "Document de travail — usage interne", width: 480)]
    check(again.apply(to: &after, documentName: "Fiche TP 05 - Onduleur").isEmpty, "oublier : plus rien n'est appliqué")
    try? FileManager.default.removeItem(at: dir)
}

// 3. fichier abîmé ou partiellement abîmé
do {
    let dir = tempDir()
    let file = dir.appendingPathComponent(ZoneLearning.fileName)
    try? Data("{ ceci n'est pas du JSON".utf8).write(to: file)
    let mem = ZoneLearning(directory: dir)
    check(mem.count == 0 && mem.recoveredFromCorruption, "fichier illisible : mémoire vide, pas de plantage")
    check(FileManager.default.fileExists(atPath: file.appendingPathExtension("corrompu").path), "fichier illisible mis de côté (.corrompu)")
    mem.recordIgnored(zone(1, before: "Pied de page"), documentName: "Fiche A")
    check(ZoneLearning(directory: dir).count == 1, "après corruption : on peut de nouveau mémoriser")

    // une entrée abîmée parmi de bonnes : seule la mauvaise est sautée
    let good = ZoneLearning(directory: dir).allEntries[0]
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let goodObj = try! JSONSerialization.jsonObject(with: enc.encode(good))
    let mixed: [String: Any] = ["version": 1, "entries": [goodObj, ["signature": 5], ["action": "bizarre"], "texte"] as [Any]]
    try! JSONSerialization.data(withJSONObject: mixed).write(to: file)
    let mem2 = ZoneLearning(directory: dir)
    check(mem2.count == 1 && !mem2.recoveredFromCorruption, "entrées abîmées sautées, bonne entrée gardée", "\(mem2.count)")
    // action inconnue d'une version future : sautée aussi
    var future = good; future.action = "kind:inconnu"
    let fobj = try! JSONSerialization.jsonObject(with: enc.encode(future))
    try! JSONSerialization.data(withJSONObject: ["version": 9, "entries": [fobj]] as [String: Any]).write(to: file)
    check(ZoneLearning(directory: dir).count == 0, "action inconnue : ignorée")
    try? FileManager.default.removeItem(at: dir)
}

// 4. écriture atomique : pas de fichier temporaire qui traîne, contenu toujours valide, accès en parallèle
do {
    let dir = tempDir()
    let mem = ZoneLearning(directory: dir)
    DispatchQueue.concurrentPerform(iterations: 40) { i in
        mem.recordIgnored(zone(i, before: "Zone numéro \(String(UnicodeScalar(UInt8(97 + i % 26))))\(String(UnicodeScalar(UInt8(97 + (i / 3) % 26))))", width: CGFloat(100 + i * 25)), documentName: "Fiche B")
    }
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    check(files == [ZoneLearning.fileName], "un seul fichier dans le dossier (pas de temporaire)", "\(files)")
    check(ZoneLearning(directory: dir).count == mem.count && mem.count > 10, "écritures en parallèle : fichier valide et complet", "\(mem.count)")
    try? FileManager.default.removeItem(at: dir)
}

// 5. jamais d'évaluation ; pas de contenu
do {
    let dir = tempDir()
    let mem = ZoneLearning(directory: dir)
    let z = zone(1, before: "Question 3 du contrôle")
    check(!mem.record(.ignore, for: z, documentName: "Contrôle chapitre 2"), "évaluation (nom) : rien n'est retenu")
    check(!mem.record(.ignore, for: z, documentName: "Fiche A", path: ["Cours", "Evaluations", "Fiche A.pdf"]), "évaluation (dossier) : rien n'est retenu")
    check(mem.count == 0, "mémoire toujours vide")
    check(mem.record(.ignore, for: z, documentName: "Fiche A", path: ["Cours", "Electricite", "Fiche A.pdf"]), "cours normal : retenu")
    var inEval = [zone(2, before: "Question 3 du contrôle")]
    check(mem.apply(to: &inEval, documentName: "DS 3", path: []).isEmpty, "évaluation : rien n'est appliqué")
    check(!mem.record(.ignore, for: zone(3, before: ""), documentName: "Fiche A"), "sans texte voisin : pas mémorisé")
    let raw = (try? String(contentsOf: mem.fileURL, encoding: .utf8)) ?? ""
    check(!raw.contains("answer") && !raw.contains("rawAnswer") && !raw.lowercased().contains("réponse"), "le fichier ne contient aucune réponse")
    let long = zone(4, before: String(repeating: "Un très long texte de consigne qui ne doit pas être gardé en entier. ", count: 20))
    mem.recordIgnored(long, documentName: "Fiche A")
    check(mem.allEntries.allSatisfy { $0.signature.neighbor.count <= ZoneSignature.neighborLength }, "texte voisin tronqué dans le fichier")
    try? FileManager.default.removeItem(at: dir)
}

// 6. plafond
do {
    let dir = tempDir()
    let mem = ZoneLearning(directory: dir)
    for i in 0..<(ZoneLearning.maxEntries + 30) {
        mem.recordIgnored(zone(i, before: "Consigne \(String(repeating: "x", count: i % 20)) \(String(UnicodeScalar(UInt8(97 + i % 26))))\(String(UnicodeScalar(UInt8(97 + (i / 26) % 26))))", width: CGFloat(40 + (i % 7) * 60)), documentName: "Modèle \(String(UnicodeScalar(UInt8(97 + i % 5))))")
    }
    check(mem.count <= ZoneLearning.maxEntries, "plafond d'entrées respecté", "\(mem.count)")
    try? FileManager.default.removeItem(at: dir)
}

// attaque : largeurs absurdes (NaN, infinie, énorme) : jamais de plantage
do {
    let dir = tempDir(), mem = ZoneLearning(directory: dir)
    for w in [CGFloat.nan, .infinity, -.infinity, 1e300, -1e300] {
        let z = zone(900, before: "Complète la phrase suivante avec le bon mot", width: w)
        _ = mem.record(.confirm, for: z, documentName: "Cours Maths")
        var zs = [z]; _ = mem.apply(to: &zs, documentName: "Cours Maths")
    }
    check(true, "largeurs NaN / infinie / énorme : pas de plantage")
    try? FileManager.default.removeItem(at: dir)
}

print("\n\(total - failures)/\(total) contrôles réussis")
exit(failures == 0 ? 0 : 1)
