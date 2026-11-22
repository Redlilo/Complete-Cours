import Foundation

/// Nom de l'app tel qu'il apparaît dans les fenêtres et les messages :
/// « App Perso » pour la variante personnelle (build.sh --personnel), « Complète-Cours » pour la version distribuée.
enum AppIdentity {
    static var nom: String {
        #if COMPTE_PERSO
        return "App Perso"
        #else
        return "Complète-Cours"
        #endif
    }
}
