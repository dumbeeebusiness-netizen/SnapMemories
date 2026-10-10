import Foundation
import ZIPFoundation

/// Liest einen Snapchat-Export (ZIP-Dateien, entpackter Ordner oder nur memories_history.json/.html)
/// und baut daraus eine chronologische Liste von Memories.
enum ExportScanner {

    // MARK: - Zwischenformate

    struct MetaEntry {
        let date: Date
        let kind: MediaKind
        let latitude: Double?
        let longitude: Double?
        let mid: String?
        let directURL: URL?
        let legacyURL: URL?
    }

    struct LocalMedia {
        let key: String          // ID aus dem Dateinamen (klein geschrieben)
        let day: String          // yyyy-MM-dd aus dem Dateinamen
        var main: FileRef?
        var overlay: FileRef?
        var bundle: FileRef?
        var kind: MediaKind
    }

    // MARK: - Einstieg

    static func scan(urls: [URL]) throws -> ScanResult {
        var meta: [MetaEntry] = []
        var locals: [String: LocalMedia] = [:]
        var foundMetaFile = false
        var warnings: [String] = []

        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                scanFolder(url, meta: &meta, locals: &locals, foundMeta: &foundMetaFile)
            } else if url.pathExtension.lowercased() == "zip" {
                do {
                    try scanZip(url, meta: &meta, locals: &locals, foundMeta: &foundMetaFile)
                } catch {
                    warnings.append("\(url.lastPathComponent) ist beschädigt oder unvollständig – bitte nochmals herunterladen.")
                }
            } else {
                let name = url.lastPathComponent.lowercased()
                if let data = try? Data(contentsOf: url) {
                    if name.hasSuffix(".json") { meta += parseJSON(data); foundMetaFile = true }
                    if name.hasSuffix(".html") { meta += parseHTML(data); foundMetaFile = true }
                }
            }
        }

        // Doppelte Metadaten (z. B. JSON und HTML im selben Export) entfernen
        var seen = Set<String>()
        meta = meta.filter { e in
            let k = e.mid ?? "\(e.date.timeIntervalSince1970)-\(e.kind.rawValue)"
            return seen.insert(k).inserted
        }

        if !foundMetaFile {
            warnings.append("Keine memories_history.json/.html gefunden – das Datum stammt nur aus dem Dateinamen (ohne Uhrzeit).")
        }
        let items = match(meta: meta, locals: locals)
        if items.isEmpty {
            warnings.append("Keine Memories gefunden. Hast du beim Export «Export your Memories» aktiviert?")
        }
        return ScanResult(items: items.sorted { $0.date < $1.date }, warnings: warnings)
    }

    // MARK: - Ordner & ZIP durchsuchen

    private static func scanFolder(_ folder: URL, meta: inout [MetaEntry],
                                   locals: inout [String: LocalMedia], foundMeta: inout Bool) {
        guard let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let url as URL in en {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let name = url.lastPathComponent
            let lower = name.lowercased()
            if lower == "memories_history.json", let d = try? Data(contentsOf: url) {
                meta += parseJSON(d); foundMeta = true
            } else if lower == "memories_history.html", let d = try? Data(contentsOf: url) {
                meta += parseHTML(d); foundMeta = true
            } else {
                addLocal(name: name, ref: .file(url), locals: &locals)
            }
        }
    }

    private static func scanZip(_ zipURL: URL, meta: inout [MetaEntry],
                                locals: inout [String: LocalMedia], foundMeta: inout Bool) throws {
        let archive = try Archive(url: zipURL, accessMode: .read)
        for entry in archive where entry.type == .file {
            let path = entry.path
            if path.contains("__MACOSX") { continue }
            let name = (path as NSString).lastPathComponent
            let lower = name.lowercased()
            if lower == "memories_history.json" || lower == "memories_history.html" {
                var data = Data()
                _ = try archive.extract(entry) { data.append($0) }
                if lower.hasSuffix(".json") { meta += parseJSON(data) } else { meta += parseHTML(data) }
                foundMeta = true
            } else {
                addLocal(name: name, ref: .zipEntry(archive: zipURL, path: path), locals: &locals)
            }
        }
    }

    /// Dateinamen wie «2023-05-01_8A1F…-main.jpg», «…-overlay.png» oder «2023-05-01_8A1F….zip»
    private static let fileNameRegex = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2})_(.+?)(?:-(main|overlay))?\.([A-Za-z0-9]+)$"#)

    private static func addLocal(name: String, ref: FileRef, locals: inout [String: LocalMedia]) {
        let range = NSRange(name.startIndex..., in: name)
        guard let m = fileNameRegex.firstMatch(in: name, range: range),
              let dayR = Range(m.range(at: 1), in: name),
              let idR = Range(m.range(at: 2), in: name),
              let extR = Range(m.range(at: 4), in: name) else { return }
        let day = String(name[dayR])
        let key = String(name[idR]).lowercased()
        let ext = String(name[extR]).lowercased()
        let role = Range(m.range(at: 3), in: name).map { String(name[$0]) }

        let videoExt = ["mp4", "mov", "m4v"]
        let photoExt = ["jpg", "jpeg", "png", "heic", "webp"]
        guard videoExt.contains(ext) || photoExt.contains(ext) || ext == "zip" else { return }

        var lm = locals[key] ?? LocalMedia(key: key, day: day, kind: .photo)
        if ext == "zip" {
            lm.bundle = ref
        } else if role == "overlay" {
            lm.overlay = ref
        } else {
            lm.main = ref
            lm.kind = videoExt.contains(ext) ? .video : .photo
        }
        locals[key] = lm
    }

    // MARK: - Metadaten parsen

    static func parseJSON(_ data: Data) -> [MetaEntry] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var rows: [[String: Any]] = []
        if let dict = obj as? [String: Any] {
            if let a = dict["Saved Media"] as? [[String: Any]] {
                rows = a
            } else {
                for (_, v) in dict {
                    if let a = v as? [[String: Any]], a.first?["Date"] != nil { rows = a; break }
                }
            }
        } else if let a = obj as? [[String: Any]] {
            rows = a
        }

        return rows.compactMap { r in
            guard let ds = r["Date"] as? String, let date = parseDate(ds) else { return nil }
            let type = ((r["Media Type"] as? String) ?? "").lowercased()
            let (lat, lon) = parseLocation(r["Location"] as? String)
            let direct = (r["Media Download Url"] as? String).flatMap(URL.init(string:))
            let legacy = (r["Download Link"] as? String).flatMap(URL.init(string:))
            return MetaEntry(date: date,
                             kind: type.contains("video") ? .video : .photo,
                             latitude: lat, longitude: lon,
                             mid: mid(from: direct) ?? mid(from: legacy),
                             directURL: direct, legacyURL: legacy)
        }
    }

    /// Fallback für Exporte, die nur memories_history.html enthalten.
    static func parseHTML(_ data: Data) -> [MetaEntry] {
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        let rowRegex = try! NSRegularExpression(pattern: #"<tr[^>]*>(.*?)</tr>"#, options: [.dotMatchesLineSeparators, .caseInsensitive])
        let dateRegex = try! NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC"#)
        let urlRegex = try! NSRegularExpression(pattern: #"https://[^'"\s<>]+"#)
        let locRegex = try! NSRegularExpression(pattern: #"Latitude, Longitude:\s*(-?[\d.]+),\s*(-?[\d.]+)"#)

        var result: [MetaEntry] = []
        let ns = html as NSString
        for row in rowRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let cell = ns.substring(with: row.range(at: 1))
            let cns = cell as NSString
            let full = NSRange(location: 0, length: cns.length)
            guard let dm = dateRegex.firstMatch(in: cell, range: full),
                  let date = parseDate(cns.substring(with: dm.range)) else { continue }
            let url = urlRegex.firstMatch(in: cell, range: full)
                .map { cns.substring(with: $0.range).replacingOccurrences(of: "&amp;", with: "&") }
                .flatMap(URL.init(string:))
            var lat: Double?, lon: Double?
            if let lm = locRegex.firstMatch(in: cell, range: full) {
                lat = Double(cns.substring(with: lm.range(at: 1)))
                lon = Double(cns.substring(with: lm.range(at: 2)))
                if lat == 0 && lon == 0 { lat = nil; lon = nil }
            }
            let isVideo = cell.lowercased().contains(">video<")
            result.append(MetaEntry(date: date, kind: isVideo ? .video : .photo,
                                    latitude: lat, longitude: lon, mid: mid(from: url),
                                    directURL: url, legacyURL: url))
        }
        return result
    }

    private static let dateFormats = ["yyyy-MM-dd HH:mm:ss 'UTC'", "yyyy-MM-dd HH:mm:ss z", "yyyy-MM-dd'T'HH:mm:ssZ"]

    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for fmt in dateFormats {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s)
    }

    private static func parseLocation(_ s: String?) -> (Double?, Double?) {
        guard let s, let colon = s.lastIndex(of: ":") else { return (nil, nil) }
        let parts = s[s.index(after: colon)...].split(separator: ",")
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let lat = parts[0], let lon = parts[1], !(lat == 0 && lon == 0) else { return (nil, nil) }
        return (lat, lon)
    }

    private static func mid(from url: URL?) -> String? {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return c.queryItems?.first { $0.name == "mid" }?.value?.lowercased()
    }

    // MARK: - Metadaten mit Dateien verknüpfen

    private static func match(meta: [MetaEntry], locals: [String: LocalMedia]) -> [MemoryItem] {
        var items: [MemoryItem] = []
        var used = Set<String>()
        var unmatched: [MetaEntry] = []

        func source(of lm: LocalMedia) -> ItemSource? {
            if let main = lm.main { return .local(main: main, overlay: lm.overlay) }
            if let bundle = lm.bundle { return .localBundle(bundle) }
            return nil
        }

        // 1) Exakt über die Snapchat-ID
        for e in meta {
            if let mid = e.mid, let lm = locals[mid], !used.contains(mid), let src = source(of: lm) {
                used.insert(mid)
                items.append(MemoryItem(id: mid, date: e.date, kind: e.kind, latitude: e.latitude,
                                        longitude: e.longitude, source: src, dateIsApproximate: false))
            } else {
                unmatched.append(e)
            }
        }

        // 2) Ersatzweise über Tag + Typ (Reihenfolge nach Uhrzeit)
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = TimeZone(identifier: "UTC")
        dayFmt.dateFormat = "yyyy-MM-dd"

        var byDay: [String: [LocalMedia]] = [:]
        for lm in locals.values where !used.contains(lm.key) {
            byDay[lm.day, default: []].append(lm)
        }
        for k in byDay.keys { byDay[k]?.sort { $0.key < $1.key } }

        var stillUnmatched: [MetaEntry] = []
        for e in unmatched.sorted(by: { $0.date < $1.date }) {
            let day = dayFmt.string(from: e.date)
            if var list = byDay[day],
               let idx = list.firstIndex(where: { !used.contains($0.key) && ($0.kind == e.kind || $0.main == nil) }),
               let src = source(of: list[idx]) {
                let lm = list.remove(at: idx)
                byDay[day] = list
                used.insert(lm.key)
                items.append(MemoryItem(id: lm.key, date: e.date, kind: e.kind, latitude: e.latitude,
                                        longitude: e.longitude, source: src, dateIsApproximate: false))
            } else {
                stillUnmatched.append(e)
            }
        }

        // 3) Lokale Dateien ohne Metadaten: Datum aus dem Dateinamen (12:00 UTC)
        for lm in locals.values where !used.contains(lm.key) {
            guard let src = source(of: lm), let d = dayFmt.date(from: lm.day) else { continue }
            items.append(MemoryItem(id: lm.key, date: d.addingTimeInterval(12 * 3600), kind: lm.kind,
                                    latitude: nil, longitude: nil, source: src, dateIsApproximate: true))
        }

        // 4) Metadaten ohne Datei: nur per Download verfügbar
        for e in stillUnmatched where e.directURL != nil || e.legacyURL != nil {
            let id = e.mid ?? "\(Int(e.date.timeIntervalSince1970))-\(e.kind.rawValue)"
            items.append(MemoryItem(id: id, date: e.date, kind: e.kind, latitude: e.latitude,
                                    longitude: e.longitude,
                                    source: .remote(directURL: e.directURL, legacyURL: e.legacyURL),
                                    dateIsApproximate: false))
        }
        return items
    }
}
