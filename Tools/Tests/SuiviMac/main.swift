import Foundation

// Test des lecteurs « Suivi MacBook » sur des pages ENREGISTRÉES (aucun accès réseau).
// Usage : suivimac <dossier des pages enregistrées>
let dossier = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func lire(_ nom: String) -> String { (try? String(contentsOfFile: "\(dossier)/\(nom).html", encoding: .utf8)) ?? "" }
var echecs = 0
func verifier(_ ok: Bool, _ msg: String) { if !ok { echecs += 1; print("ÉCHEC : \(msg)") } else { print("ok     : \(msg)") } }
func afficher(_ nom: String, _ o: [SuiviOffre]) {
    print("== \(nom) : \(o.count) offre(s)")
    for x in o.sorted(by: { $0.prix < $1.prix }) {
        print("   \(x.puce) \(x.ecran)\" GPU \(x.gpu.map(String.init) ?? "?") \(x.ram)Go/\(x.ssd) \(x.affichage) \(x.couleur) · \(x.clavier) · \(Int(x.prix)) € · \(x.etat.rawValue) · livraison \(x.livraison.rawValue)")
    }
}

let apFR = SuiviLecteurs.apple(lire("apple_fr"), pays: "FR", base: "https://www.apple.com")
afficher("Apple FR", apFR)
verifier(apFR.count >= 10, "Apple FR : au moins 10 offres Max 36 et 48 Go")
verifier(apFR.contains { $0.puce == "M4 Max" && $0.ecran == 16 && $0.prix == 4259 }, "Apple FR : M4 Max 16\" à 4 259 €")
verifier(apFR.contains { $0.puce == "M3 Max" }, "Apple FR : un M3 Max")
verifier(apFR.allSatisfy { $0.livraison == .oui }, "Apple FR : toutes livrables en France")
verifier(apFR.contains { $0.ram == 36 } && apFR.contains { $0.ram == 48 }, "Apple FR : des 36 Go et des 48 Go")
verifier(apFR.filter { $0.ram == 36 }.allSatisfy { $0.gpu == 32 } && apFR.filter { $0.ram == 48 }.allSatisfy { $0.gpu == 40 }, "Apple FR : GPU 32 cœurs en 36 Go, 40 en 48 Go")
for (code, pays) in [("apple_de", "DE"), ("apple_it", "IT"), ("apple_es", "ES"), ("apple_nl", "NL"), ("apple_ie", "IE"), ("apple_at", "AT")] {
    let o = SuiviLecteurs.apple(lire(code), pays: pays, base: "https://www.apple.com")
    afficher("Apple \(pays)", o)
    verifier(o.allSatisfy { $0.livraison == .non }, "Apple \(pays) : jamais « livré en France »")
}
let ld = SuiviLecteurs.ldlc(lire("ldlc")); afficher("LDLC", ld)
verifier(ld.count >= 3 && ld.allSatisfy { $0.puce == "M5 Max" && $0.ecran == 16 }, "LDLC : M5 Max 16\" 48 Go")
let mt = SuiviLecteurs.materiel(lire("materiel")); afficher("Materiel.net", mt)
verifier(mt.count >= 2, "Materiel.net : au moins 2 offres")
let bl = SuiviLecteurs.boulanger(lire("boulanger")); afficher("Boulanger", bl)
verifier(bl.count >= 1 && bl.allSatisfy { $0.clavier == "AZERTY" }, "Boulanger : offres 48 Go, AZERTY")
let al = SuiviLecteurs.alternate(lire("alternate"), rechercheURL: "https://www.alternate.de"); afficher("Alternate.de", al)
verifier(al.count >= 1 && al.allSatisfy { $0.clavier == "QWERTZ" && $0.livraison == .aVerifier }, "Alternate : QWERTZ, livraison à vérifier")
let ms = SuiviLecteurs.macStore24(lire("macstore24")); afficher("mac-store24", ms)
verifier(ms.count == 4 && ms.allSatisfy { $0.ram == 36 && $0.clavier == "QWERTZ" && $0.etat == .reconditionneTiers && $0.livraison == .oui }, "mac-store24 : 4 variantes Max 36 Go lues, QWERTZ, reconditionné")
verifier(ms.contains { $0.puce == "M4 Max" && $0.ecran == 16 && $0.prix == 3299 && $0.ssd == "1 To" && $0.gpu == 32 }, "mac-store24 : M4 Max 16\" 36 Go à 3 299 € (GPU 32 déduit)")

// Sites lus avec WebKit (fiches extraites de pages enregistrées)
func blocs(_ nom: String) -> [SuiviBlocWeb] {
    guard let d = FileManager.default.contents(atPath: "\(dossier)/\(nom).json") else { return [] }
    return (try? JSONDecoder().decode([SuiviBlocWeb].self, from: d)) ?? []
}
let fn = SuiviLecteurs.fnac(blocs("fnac48") + blocs("fnac36")); afficher("Fnac", fn)
verifier(fn.contains { $0.puce == "M5 Max" && $0.ecran == 16 && $0.ram == 48 && $0.prix == 5699 }, "Fnac : M5 Max 16\" 48 Go à 5 699 €")
verifier(fn.filter { $0.ram == 48 }.allSatisfy { $0.gpu == 40 } && fn.filter { $0.ram == 36 }.allSatisfy { $0.gpu == 32 }, "Fnac : GPU 40 cœurs en 48 Go, 32 en 36 Go (et non les cœurs du CPU)")
verifier(fn.contains { $0.ram == 36 } && fn.allSatisfy { $0.livraison == .oui && $0.clavier == "AZERTY" }, "Fnac : des 36 Go, tout livré, AZERTY")
let dt = SuiviLecteurs.darty(blocs("darty48")); afficher("Darty", dt)
verifier(dt.count >= 1 && dt.allSatisfy { $0.puce.hasSuffix("Max") && $0.prix >= 1500 }, "Darty : offres Max avec un prix")
let mm = SuiviLecteurs.mediaMarkt(blocs("mediamarkt48")); afficher("MediaMarkt.de", mm)
verifier(mm.contains { $0.prix == 4969 } && mm.allSatisfy { $0.clavier == "QWERTZ" && $0.livraison == .aVerifier }, "MediaMarkt : prix soldé 4 969 € (pas le prix barré), QWERTZ, livraison à vérifier")

// Sites de reconditionné et places de marché
let rm = SuiviLecteurs.refurbMe(blocs("refurbme_m3") + blocs("refurbme_m4") + blocs("refurbme_m5")); afficher("RefurbMe", rm)
verifier(rm.count >= 5 && rm.allSatisfy { $0.grade != nil && !$0.source.isEmpty && !$0.source.lowercased().contains("apple") }, "RefurbMe : offres avec vendeur et état, sans le Store Apple")
verifier(Set(rm.map(\.source)).count >= 2, "RefurbMe : au moins deux vendeurs différents")
verifier(rm.contains { $0.source == "Back Market" } , "RefurbMe : Back Market présent")
let azfr = SuiviLecteurs.amazon(blocs("amazonfr_m5") + blocs("amazonfr_m4"), pays: "FR"); afficher("Amazon.fr", azfr)
verifier(azfr.count >= 1 && azfr.allSatisfy { $0.source == "Amazon.fr" && $0.clavier == "AZERTY" && $0.prix >= 1500 }, "Amazon.fr : offres Max avec un prix")
let azde = SuiviLecteurs.amazon(blocs("amazonde_m5"), pays: "DE"); afficher("Amazon.de", azde)
verifier(azde.contains { $0.prix == 3899 && $0.ram == 36 && $0.ecran == 14 } && azde.allSatisfy { $0.livraison == .aVerifier && $0.clavier == "QWERTZ" }, "Amazon.de : M5 Max 14\" 36 Go à 3 899 €, livraison à vérifier")
let rd = SuiviLecteurs.rueDuCommerce(blocs("rdc_m4")); afficher("Rue du Commerce (64 Go ignoré)", rd)
verifier(rd.isEmpty, "Rue du Commerce : un 64 Go n'est pas gardé")
var ok: [SuiviOffre] = []
for q in ["m3", "m4", "m5"] { ok += SuiviLecteurs.okamac(lire("okamac_\(q)"), rechercheURL: "https://www.okamac.com") }
afficher("Okamac", ok)
verifier(ok.count >= 1 && ok.allSatisfy { $0.etat == .reconditionneTiers && $0.clavier == "AZERTY" } && ok.contains { $0.grade != nil }, "Okamac : reconditionné, AZERTY, état annoncé quand le vendeur le donne")

// Leboncoin (Paris, 20 km)
let lbc = SuiviLecteurs.leboncoin(blocs("lbc_m3") + blocs("lbc_m4") + blocs("lbc_m5"))
afficher("Leboncoin", lbc)
for x in lbc.prefix(6) { print("      \(x.source) · \(x.ville ?? "?") · \(x.distanceKm.map { String(Int($0)) } ?? "?") km · \(x.grade ?? "-")") }
verifier(lbc.count >= 5, "Leboncoin : au moins 5 annonces Max 36/48 Go")
verifier(lbc.allSatisfy { ($0.distanceKm ?? 0) <= 20 && $0.etat == .occasion && $0.puce.hasSuffix("Max") && [36, 48].contains($0.ram) }, "Leboncoin : toutes à 20 km de Paris ou moins, Max 36/48 Go")
verifier(lbc.contains { $0.vendeurPro == false } && lbc.contains { $0.vendeurPro == true } || lbc.contains { $0.vendeurPro == false }, "Leboncoin : des particuliers repérés")
verifier(lbc.contains { $0.ecran == 0 && $0.ram == 36 }, "Leboncoin : une annonce sans taille d'écran est gardée (écran « ? »), mémoire lue sans « Go »")
verifier(!lbc.contains { $0.titre.lowercased().contains("m2") || $0.titre.lowercased().contains("m5 pro") }, "Leboncoin : pas de M2 ni de M5 Pro")
let azit = SuiviLecteurs.amazon(blocs("amazonfr_m5"), pays: "IT")
verifier(azit.allSatisfy { $0.source == "Amazon.it" } , "Amazon.it : nom du site correct")

// Calculs : score = prix ÷ bande passante ; tranches de prix
let m4 = apFR.first { $0.puce == "M4 Max" && $0.ram == 48 }!
let e = SuiviCalcul.evaluer(m4)
verifier(e.bande == 546 && abs((e.score ?? 0) - 4259.0 / 546.0) < 0.001, "score M4 Max 16\" 48 Go : 4 259 € ÷ 546 Go/s")
var sansGPU = m4; sansGPU.gpu = nil
verifier(SuiviCalcul.evaluer(sansGPU).score == nil, "GPU inconnu : pas de score")

let toutes = (apFR + ld + bl + fn + dt + rm + azfr + azde + ok + lbc).map { SuiviCalcul.evaluer($0) }
let b4 = SuiviCalcul.bornes(3, parTranche: true)
verifier(b4.minimum == 3500 && b4.maximum == 4000, "tranche 4 000 € : de 3 500 à 4 000 €")
verifier(SuiviCalcul.bornes(3, parTranche: false).minimum == 0, "« jusqu'au palier » : à partir de 0")
let dansTranche = SuiviCalcul.meilleurSousBudget(toutes, budget: 4000, ram: 36, minimum: 3500)
verifier(dansTranche != nil && dansTranche!.offre.prix > 3500 && dansTranche!.offre.prix <= 4000, "tranche 3 500–4 000 € en 36 Go : une offre dont le prix est bien dans la tranche")
let t3 = SuiviCalcul.meilleurSousBudget(toutes, budget: 3500, ram: 36, minimum: 3000)
verifier(t3 != nil && t3!.offre.prix > 3000 && t3!.offre.prix <= 3500 && (t3!.bande ?? 0) >= 410, "tranche 3 000–3 500 € en 36 Go : une offre dans la tranche, au moins 410 Go/s")
let a48 = SuiviCalcul.meilleurSousBudget(toutes, budget: 4300, ram: 48)
let moins546 = toutes.filter { $0.bande == 546 && $0.offre.ram == 48 && $0.offre.prix <= 4300 }.map { $0.offre.prix }.min()
verifier(a48?.bande == 546 && a48?.offre.prix == moins546, "jusqu'à 4 300 € en 48 Go : 546 Go/s, et c'est la moins chère de celles-là (\(Int(moins546 ?? 0)) €)")
let rapport = SuiviCalcul.meilleurRapportSousBudget(toutes, budget: 4500, ram: 36, minimum: 4000)
let perf = SuiviCalcul.meilleurSousBudget(toutes, budget: 4500, ram: 36, minimum: 4000)
verifier(rapport != nil && perf != nil && (rapport!.score ?? 1e9) <= (perf!.score ?? 1e9) && (perf!.bande ?? 0) >= (rapport!.bande ?? 0), "tranche 4 000–4 500 € en 36 Go : performances ≥ et rapport ≤ de l'autre")
for n in SuiviCalcul.paliers.indices {
    let b = SuiviCalcul.bornes(n, parTranche: true)
    for ram in [36, 48] {
        let x = SuiviCalcul.meilleurSousBudget(toutes, budget: b.maximum, ram: ram, minimum: b.minimum)
        print("   tranche \(Int(b.minimum))–\(Int(b.maximum)) € · \(ram) Go : \(x.map { "\(SuiviCalcul.nomCourt($0.offre)) — \($0.offre.source) — \(Int($0.offre.prix)) € — \($0.bande ?? 0) Go/s" } ?? "aucune")")
    }
}
print(echecs == 0 ? "\nTOUT EST OK" : "\n\(echecs) échec(s)")
exit(echecs == 0 ? 0 : 1)
