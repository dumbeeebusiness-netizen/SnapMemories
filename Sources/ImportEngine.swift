import Foundation
import CoreLocation
import ZIPFoundation

/// Erledigt die schwere Arbeit (Entpacken, Herunterladen, Overlay, Import) ausserhalb des UI-Threads.
actor ImportEngine {
    private var archives: [URL: Archive] = [:]
    private let workDir: URL
    private let session: URLSession

    init() {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("SnapImport", isDirectory: true)
        try? FileManager.default.removeItem(at: workDir)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config)
    }

    func scan(_ urls: [URL]) throws -> ScanResult {
        archives.removeAll()
        return try ExportScanner.scan(urls: urls)
    }

    func reset() {
        archives.removeAll()
    }

    /// Bereitet ein Memory vor und legt es mit Originaldatum im Album ab.
    func process(_ item: MemoryItem, albumID: String, burnOverlay: Bool) async throws {
        let dir = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var main: URL
        var overlay: URL? = nil

        switch item.source {
        case .local(let m, let o):
            main = try materialize(m, into: dir)
            if burnOverlay, let o { overlay = try? materialize(o, into: dir) }
        case .localBundle(let ref):
            let zip = try materialize(ref, into: dir)
            let unpacked = try unpackBundle(zip, into: dir)
            main = unpacked.0
            overlay = unpacked.1
        case .remote(let direct, let legacy):
            let file = try await download(direct: direct, legacy: legacy, into: dir)
            if file.pathExtension == "zip" {
                let unpacked = try unpackBundle(file, into: dir)
                main = unpacked.0
                overlay = unpacked.1
            } else {
                main = file
            }
        }

        main = try Self.fixExtension(main)
        let ext = main.pathExtension.lowercased()
        let kind: MediaKind = ["mp4", "mov", "m4v"].contains(ext) ? .video : .photo

        // Text/Sticker-Overlay ins Foto einbrennen (bei Videos wird nur das Original importiert)
        if kind == .photo, burnOverlay, let overlay {
            let merged = dir.appendingPathComponent("merged.jpg")
            if (try? OverlayRenderer.merge(main: main, overlay: overlay, to: merged)) != nil {
                main = merged
            }
        }

        var location: CLLocation?
        if let lat = item.latitude, let lon = item.longitude {
            location = CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                  altitude: 0, horizontalAccuracy: 50, verticalAccuracy: -1, timestamp: item.date)
        }

        try await PhotoLibrary.importAsset(file: main, kind: kind, date: item.date,
                                           location: location, albumID: albumID)
    }

    // MARK: - Dateien bereitstellen

    /// Kopiert die Datei in den App-eigenen Temp-Ordner (Fotos darf nur von dort zuverlässig lesen).
    private func materialize(_ ref: FileRef, into dir: URL) throws -> URL {
        let dest = dir.appendingPathComponent(ref.fileName)
        switch ref {
        case .file(let url):
            guard FileManager.default.fileExists(atPath: url.path) else { throw ImportError.fileNotFound(ref.fileName) }
            try FileManager.default.copyItem(at: url, to: dest)
        case .zipEntry(let archiveURL, let path):
            let archive = try archive(for: archiveURL)
            guard let entry = archive[path] else { throw ImportError.fileNotFound(ref.fileName) }
            _ = try archive.extract(entry, to: dest)
        }
        return dest
    }

    private func archive(for url: URL) throws -> Archive {
        if let a = archives[url] { return a }
        let a = try Archive(url: url, accessMode: .read)
        archives[url] = a
        return a
    }

    /// Verschachtelte ZIP (Memories mit Overlay) entpacken.
    private func unpackBundle(_ zip: URL, into dir: URL) throws -> (URL, URL?) {
        let archive = try Archive(url: zip, accessMode: .read)
        var main: URL?
        var overlay: URL?
        for entry in archive where entry.type == .file && !entry.path.contains("__MACOSX") {
            let name = (entry.path as NSString).lastPathComponent
            let dest = dir.appendingPathComponent("b-" + name)
            if name.lowercased().contains("overlay") {
                _ = try archive.extract(entry, to: dest)
                overlay = dest
            } else if main == nil {
                _ = try archive.extract(entry, to: dest)
                main = dest
            }
        }
        guard let main else { throw ImportError.fileNotFound(zip.lastPathComponent) }
        return (main, overlay)
    }

    // MARK: - Download (nur wenn der Export keine Dateien enthält)

    private func download(direct: URL?, legacy: URL?, into dir: URL) async throws -> URL {
        var lastError: Error = ImportError.noDownloadLink

        // Neuere Exporte: direkter GET-Link
        for url in [direct, legacy].compactMap({ $0 }) {
            do { return try await fetchFile(URLRequest(url: url), into: dir, depth: 0) }
            catch { lastError = error }
        }

        // Ältere Exporte: POST liefert eine temporäre Download-Adresse als Text
        if let legacy, var comps = URLComponents(url: legacy, resolvingAgainstBaseURL: false) {
            let query = comps.percentEncodedQuery
            comps.query = nil
            if let base = comps.url {
                var req = URLRequest(url: base)
                req.httpMethod = "POST"
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.httpBody = query?.data(using: .utf8)
                do { return try await fetchFile(req, into: dir, depth: 0) }
                catch { lastError = error }
            }
        }
        throw lastError
    }

    private func fetchFile(_ request: URLRequest, into dir: URL, depth: Int) async throws -> URL {
        var req = request
        req.setValue("mem-dmd", forHTTPHeaderField: "X-Snap-Route-Tag")
        let (tmp, response) = try await session.download(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if [401, 403, 404, 410].contains(http.statusCode) { throw ImportError.linkExpired }
            throw ImportError.http(http.statusCode)
        }
        let file = dir.appendingPathComponent("download-\(depth)")
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: tmp, to: file)

        let ext = Self.sniffExtension(file)
        if ext == "bin" {
            // Antwort ist evtl. eine weitere URL (Text) – dann dieser folgen
            if depth < 2,
               let text = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               text.hasPrefix("http"), let next = URL(string: text) {
                return try await fetchFile(URLRequest(url: next), into: dir, depth: depth + 1)
            }
            throw ImportError.unknownFileType("Download")
        }
        let named = file.appendingPathExtension(ext)
        try FileManager.default.moveItem(at: file, to: named)
        return named
    }

    // MARK: - Dateityp anhand der ersten Bytes erkennen

    static func fixExtension(_ url: URL) throws -> URL {
        let real = sniffExtension(url)
        guard real != "bin", real != url.pathExtension.lowercased() else { return url }
        if real == "jpg" && url.pathExtension.lowercased() == "jpeg" { return url }
        let fixed = url.deletingPathExtension().appendingPathExtension(real)
        try FileManager.default.moveItem(at: url, to: fixed)
        return fixed
    }

    static func sniffExtension(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "bin" }
        defer { try? h.close() }
        let b = [UInt8]((try? h.read(upToCount: 12)) ?? Data())
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpg" }
        if b.count >= 4, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b.count >= 4, b[0] == 0x50, b[1] == 0x4B, b[2] == 0x03, b[3] == 0x04 { return "zip" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "webp" }
        if b.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {   // "ftyp"
            let brand = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            if ["heic", "heix", "mif1", "msf1"].contains(brand) { return "heic" }
            if brand.hasPrefix("qt") { return "mov" }
            return "mp4"
        }
        return "bin"
    }
}
