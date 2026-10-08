import Foundation

enum MediaKind: String, Codable, Sendable {
    case photo, video
}

/// Verweis auf eine Datei – entweder in einem Ordner oder als Eintrag in einer ZIP-Datei.
enum FileRef: Hashable, Sendable {
    case file(URL)
    case zipEntry(archive: URL, path: String)

    var fileName: String {
        switch self {
        case .file(let url): return url.lastPathComponent
        case .zipEntry(_, let path): return (path as NSString).lastPathComponent
        }
    }
}

/// Woher die eigentliche Foto-/Videodatei kommt.
enum ItemSource: Sendable {
    /// Datei liegt im Export (optional mit separatem Overlay-PNG).
    case local(main: FileRef, overlay: FileRef?)
    /// Verschachtelte ZIP im Export, die main + overlay enthält.
    case localBundle(FileRef)
    /// Nur ein Download-Link im Export (ältere Exporte).
    case remote(directURL: URL?, legacyURL: URL?)
}

struct MemoryItem: Identifiable, Sendable {
    /// Stabiler Schlüssel (Snapchat-ID) – damit nichts doppelt importiert wird.
    let id: String
    var date: Date
    var kind: MediaKind
    var latitude: Double?
    var longitude: Double?
    var source: ItemSource
    /// true, wenn die Uhrzeit nur aus dem Dateinamen geschätzt wurde.
    var dateIsApproximate: Bool

    var isRemote: Bool {
        if case .remote = source { return true }
        return false
    }
}

struct ScanResult: Sendable {
    var items: [MemoryItem]
    var warnings: [String]
}

enum ImportError: LocalizedError {
    case fileNotFound(String)
    case noDownloadLink
    case linkExpired
    case http(Int)
    case unknownFileType(String)
    case overlayFailed
    case photoAccessDenied
    case albumCreationFailed

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let n): return "Datei nicht gefunden: \(n)"
        case .noDownloadLink: return "Kein Download-Link vorhanden"
        case .linkExpired: return "Download-Link abgelaufen – bitte neuen Export bei Snapchat anfordern"
        case .http(let code): return "Download fehlgeschlagen (HTTP \(code))"
        case .unknownFileType(let n): return "Unbekannter Dateityp: \(n)"
        case .overlayFailed: return "Overlay konnte nicht eingebrannt werden"
        case .photoAccessDenied: return "Kein Vollzugriff auf Fotos. Bitte in Einstellungen › SnapMemories › Fotos auf «Voller Zugriff» stellen."
        case .albumCreationFailed: return "Album konnte nicht erstellt werden"
        }
    }
}
