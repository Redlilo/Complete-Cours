import Foundation

// Fabrique les PDF de test (texte, tourné, rogné, vide) dans le dossier donné, avec les mêmes générateurs que la
// suite App (Tools/Tests/App/TestPDFs.swift). Aucune donnée réelle. Usage : genpdf <dossier>
@main
struct GenPDF {
    static func main() {
        _ = TestPDFs.generate(in: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."))
    }
}
