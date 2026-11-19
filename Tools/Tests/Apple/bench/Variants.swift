import Foundation
import FoundationModels

// Variantes comparées par le banc d'essai. Les variantes « de production » appellent AppleEngine ;
// les autres sont les pistes écartées (gardées pour pouvoir refaire la mesure).

func allVariants() -> [Variant] {
    var v: [Variant] = []
    let mot: Set<String> = ["mot"]
    let redac: Set<String> = ["definition", "question"]

    // --- mots à compléter ---
    v.append(Variant(name: "mot.direct", types: mot) { c in try await AppleEngine.motDirect(zoneInput(c)) })
    v.append(Variant(name: "mot.phrase", types: mot) { c in try await AppleEngine.motPhrase(zoneInput(c)) })
    v.append(Variant(name: "mot.explication", types: mot) { c in try await AppleEngine.motExplain(zoneInput(c)) })
    v.append(Variant(name: "mot.vote3", types: mot) { c in try await AppleEngine.fillWord(zoneInput(c)) })
    v.append(Variant(name: "mot.direct+orth", types: mot) { c in
        guard let w = try await AppleEngine.motDirect(zoneInput(c)) else { return nil }
        return await Spelling.correct(w)
    })
    v.append(Variant(name: "mot.breve", types: mot) { c in
        let input = zoneInput(c)
        let text = AppleText.cloze(before: input.before, after: input.after)
        let raw = try await AppleEngine.ask { _ in
            AppleEngine.PromptSpec(instructions: AppleEngine.motInstructions,
                                   prompt: "Cours : « \(c.document) »\nTexte : « \(text) »\nMot manquant :", maxTokens: 24)
        }
        return raw.map { AppleText.cleanWord($0, before: input.before) }
    })
    v.append(Variant(name: "mot.anglais", types: mot) { c in
        let input = zoneInput(c)
        let text = AppleText.cloze(before: input.before, after: input.after)
        let instr = "You help a French vocational high-school student fill in the blanks of his course sheets (electricity, networks, physics and chemistry, maths, French, history and geography, economics). Reply in French with only the missing word or words, spelled correctly and agreeing with the sentence. No sentence, no explanation."
        let raw = try await AppleEngine.ask { _ in
            AppleEngine.PromptSpec(instructions: instr, shots: AppleEngine.motShots,
                                   prompt: "Cours : « \(c.document) »\nTexte : « \(text) »\nMot manquant :", maxTokens: 24)
        }
        return raw.map { AppleText.cleanWord($0, before: input.before) }
    })

    // --- définitions et questions ---
    v.append(Variant(name: "redac.prod", types: redac) { c in
        try await AppleEngine.writeAnswer(zoneInput(c), kind: c.type == "definition" ? .definition : .question)
    })
    // première version : consigne brève, sans exemples, sans contrôle de la longueur
    v.append(Variant(name: "redac.v1", types: redac) { c in
        let input = zoneInput(c)
        let limit = max(input.capacity, 20)
        let consigne = c.type == "definition" ? "Donne la définition en une ou deux phrases." : "Réponds en une à trois phrases."
        let raw = try await AppleEngine.ask { _ in
            let prompt = "Cours : « \(input.document) »\nTexte de la fiche juste avant la zone à remplir : « \(AppleText.tail(input.before, 650)) »\n\(consigne) \(limit) caractères au maximum.\nRéponse :"
            return AppleEngine.PromptSpec(instructions: AppleEngine.redacInstructions, prompt: prompt, maxTokens: min(max(limit / 3 + 12, 30), 220))
        }
        return raw.map(AppleText.cleanSentence)
    })

    // --- champs d'identité, calculs, conversions (sans modèle) ---
    v.append(Variant(name: "champ.regles", types: ["champ"]) { c in
        let student = c.profilVide == true ? StudentProfile() : fakeStudent
        switch AppleRules.field(before: c.avant, student: student, todayText: fakeToday) {
        case .text(let t)?: return t
        case .ignore?: return ignoredAnswer
        case nil: return ""
        }
    })
    v.append(Variant(name: "calcul.regles", types: mot) { c in
        AppleMath.calculation(before: c.avant) ?? AppleMath.conversion(before: c.avant, after: c.apres)
    })

    // --- zones à ne pas remplir ---
    let allTypes: Set<String> = ["mot", "definition", "question", "ignorer"]
    v.append(Variant(name: "gate.modele", types: allTypes, isGate: true) { c in
        let r = try await AppleEngine.isCourseAnswer(zoneInput(c))
        return r == false ? ignoredAnswer : "à remplir"
    })
    v.append(Variant(name: "gate.les-deux", types: allTypes, isGate: true) { c in
        if AppleRules.isNotACourseAnswer(before: c.avant, after: c.apres) { return ignoredAnswer }
        let r = try await AppleEngine.isCourseAnswer(zoneInput(c))
        return r == false ? ignoredAnswer : "à remplir"
    })
    v.append(Variant(name: "gate.modele-filtre", types: allTypes, isGate: true) { c in
        let input = zoneInput(c)
        guard AppleText.endsLikeALabel(input.before) else { return "à remplir" }
        let r = try await AppleEngine.isCourseAnswer(input)
        return r == false ? ignoredAnswer : "à remplir"
    })
    v.append(Variant(name: "gate.mots-cles", types: allTypes, isGate: true) { c in
        AppleRules.isNotACourseAnswer(before: c.avant, after: c.apres) ? ignoredAnswer : "à remplir"
    })
    return v
}
