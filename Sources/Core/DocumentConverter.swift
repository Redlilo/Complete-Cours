import Foundation
import AppKit

/// Convertit un document Word (ou Pages…) en PDF, pour que le moteur de l'app (qui ne lit que des PDF) puisse le compléter.
/// Le PDF est écrit à côté du document (« Séance 1.docx » → « Séance 1.pdf »), l'original n'est jamais modifié.
/// Word d'abord, puis Pages ; sans l'un ni l'autre, un message clair.
enum DocumentConverter {
    enum Failure: LocalizedError {
        case noApp
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .noApp: return "Pour compléter un document Word, il faut Microsoft Word ou Pages sur ce Mac. Exporte-le en PDF et remets-le dans le même dossier."
            case .failed(let why): return "La conversion en PDF a échoué : \(why)"
            }
        }
    }

    /// PDF de ce document : celui qui existe déjà à côté (plus récent que le document), sinon il est créé.
    static func pdf(for document: URL) async throws -> URL {
        let out = document.deletingPathExtension().appendingPathExtension("pdf")
        let fm = FileManager.default
        if fm.fileExists(atPath: out.path), let a = modified(out), let b = modified(document), a >= b { return out }
        // jamais d'écrasement d'un PDF plus récent que le Word : on garde son nom et on écrit « (converti) »
        let target = fm.fileExists(atPath: out.path) ? uniqueName(for: out) : out
        let apps: [(name: String, path: String, script: (URL, URL) -> String)] = [
            ("Microsoft Word", "/Applications/Microsoft Word.app", wordScript),
            ("Pages", "/Applications/Pages.app", pagesScript),
        ]
        var lastError = ""
        var tried = false
        for app in apps where fm.fileExists(atPath: app.path) {
            tried = true
            do {
                try await run(app.script(document, target))
                if fm.fileExists(atPath: target.path) { return target }
                lastError = "\(app.name) n'a pas créé le PDF."
            } catch {
                lastError = "\(app.name) : \(error.localizedDescription)"
            }
        }
        throw tried ? Failure.failed(lastError) : Failure.noApp
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func uniqueName(for url: URL) -> URL {
        let base = url.deletingPathExtension()
        var n = 1
        var candidate = URL(fileURLWithPath: base.path + " (converti).pdf")
        while FileManager.default.fileExists(atPath: candidate.path) {
            n += 1
            candidate = URL(fileURLWithPath: base.path + " (converti \(n)).pdf")
        }
        return candidate
    }

    private static func esc(_ url: URL) -> String {
        url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func wordScript(_ doc: URL, _ out: URL) -> String {
        """
        tell application "Microsoft Word"
            set theDoc to open POSIX file "\(esc(doc))" with read only
            save as theDoc file name "\(esc(out))" file format format PDF
            close theDoc saving no
        end tell
        """
    }

    private static func pagesScript(_ doc: URL, _ out: URL) -> String {
        """
        tell application "Pages"
            set theDoc to open POSIX file "\(esc(doc))"
            export theDoc to POSIX file "\(esc(out))" as PDF
            close theDoc saving no
        end tell
        """
    }

    /// Lance le script AppleScript hors du fil principal (Word peut mettre quelques secondes à répondre).
    private static func run(_ source: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source]
            let err = Pipe()
            p.standardError = err; p.standardOutput = Pipe()
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw Failure.failed(msg.isEmpty ? "code \(p.terminationStatus)" : msg)
            }
        }.value
    }
}
