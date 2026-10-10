import SwiftUI
import UIKit

@MainActor
final class ImportViewModel: ObservableObject {
    enum Phase { case idle, scanning, ready, importing, finished }

    @Published var phase: Phase = .idle
    @Published var items: [MemoryItem] = []
    @Published var warnings: [String] = []
    @Published var pickedNames: [String] = []
    @Published var log: [String] = []
    @Published var done = 0
    @Published var total = 0
    @Published var currentLabel = ""
    @Published private(set) var importedIDs: Set<String>

    @Published var albumName = UserDefaults.standard.string(forKey: "albumName") ?? "Snapchat Memories" {
        didSet { UserDefaults.standard.set(albumName, forKey: "albumName") }
    }
    @Published var burnOverlays = UserDefaults.standard.object(forKey: "burnOverlays") as? Bool ?? true {
        didSet { UserDefaults.standard.set(burnOverlays, forKey: "burnOverlays") }
    }
    @Published var downloadMissing = false

    private let engine = ImportEngine()
    private var accessedURLs: [URL] = []
    private var task: Task<Void, Never>?
    private static let importedKey = "importedIDs"

    init() {
        importedIDs = Set(UserDefaults.standard.stringArray(forKey: Self.importedKey) ?? [])
    }

    // MARK: - Kennzahlen

    var photoCount: Int { items.filter { $0.kind == .photo }.count }
    var videoCount: Int { items.filter { $0.kind == .video }.count }
    var remoteCount: Int { items.filter(\.isRemote).count }
    var localCount: Int { items.count - remoteCount }
    var alreadyImported: Int { items.filter { importedIDs.contains($0.id) }.count }
    var approximateCount: Int { items.filter(\.dateIsApproximate).count }
    var firstDate: Date? { items.first?.date }
    var lastDate: Date? { items.last?.date }

    var pending: [MemoryItem] {
        items.filter { !importedIDs.contains($0.id) && (downloadMissing || !$0.isRemote) }
    }

    // MARK: - Export laden

    @Published var downloadedExports: [URL] = ExportStore.zips()
    private var scanGeneration = 0

    var downloadedSizeText: String {
        ByteCountFormatter.string(fromByteCount: ExportStore.totalSize(), countStyle: .file)
    }

    /// Wird vom eingebauten Snapchat-Browser nach jedem fertigen Download aufgerufen.
    func didDownloadExport(_ file: URL) {
        downloadedExports = ExportStore.zips()
        guard phase != .importing else { return }
        load(downloadedExports)
    }

    func loadDownloadedExports() {
        downloadedExports = ExportStore.zips()
        guard !downloadedExports.isEmpty else { return }
        load(downloadedExports)
    }

    func deleteDownloadedExports() {
        ExportStore.deleteAll()
        downloadedExports = []
        items = []
        pickedNames = []
        warnings = []
        phase = .idle
        Task { await engine.reset() }
    }

    func load(_ urls: [URL]) {
        stopAccessing()
        for url in urls where url.startAccessingSecurityScopedResource() {
            accessedURLs.append(url)
        }
        pickedNames = urls.map(\.lastPathComponent)
        phase = .scanning
        items = []
        warnings = []
        log = []
        scanGeneration += 1
        let generation = scanGeneration

        Task {
            do {
                let result = try await engine.scan(urls)
                guard generation == scanGeneration else { return }
                items = result.items
                warnings = result.warnings
                // Ohne Dateien im Export bleibt nur der Download über die Links
                downloadMissing = localCount == 0 && remoteCount > 0
                phase = .ready
            } catch {
                warnings = ["Export konnte nicht gelesen werden: \(error.localizedDescription)"]
                phase = .idle
            }
        }
    }

    // MARK: - Import

    func startImport() {
        let queue = pending.sorted { $0.date < $1.date }
        guard !queue.isEmpty else { return }
        done = 0
        total = queue.count
        phase = .importing
        let album = albumName.trimmingCharacters(in: .whitespaces).isEmpty ? "Snapchat Memories" : albumName
        let burn = burnOverlays

        task = Task {
            UIApplication.shared.isIdleTimerDisabled = true
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                currentLabel = ""
                phase = .finished
            }
            do {
                try await PhotoLibrary.requestFullAccess()
                let albumID = try await PhotoLibrary.albumID(named: album)
                var failed = 0
                for item in queue {
                    if Task.isCancelled { log.insert("Abgebrochen.", at: 0); break }
                    currentLabel = item.date.formatted(date: .abbreviated, time: .shortened)
                    do {
                        try await engine.process(item, albumID: albumID, burnOverlay: burn)
                        markImported(item.id)
                    } catch {
                        failed += 1
                        log.insert("\(currentLabel): \(error.localizedDescription)", at: 0)
                    }
                    done += 1
                }
                log.insert("Fertig: \(done - failed) importiert, \(failed) fehlgeschlagen.", at: 0)
            } catch {
                log.insert(error.localizedDescription, at: 0)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func resetHistory() {
        importedIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.importedKey)
    }

    private func markImported(_ id: String) {
        importedIDs.insert(id)
        UserDefaults.standard.set(Array(importedIDs), forKey: Self.importedKey)
    }

    private func stopAccessing() {
        accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        accessedURLs.removeAll()
        Task { await engine.reset() }
    }
}
