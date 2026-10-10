import SwiftUI
import WebKit

/// Ordner in der App, in den die Snapchat-Exporte heruntergeladen werden.
enum ExportStore {
    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("SnapchatExport", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func zips() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "zip" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func totalSize() -> Int64 {
        zips().reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static func deleteAll() {
        zips().forEach { try? FileManager.default.removeItem(at: $0) }
    }
}

// MARK: - Bildschirm mit eingebautem Snapchat-Login

struct SnapchatFetchView: View {
    @ObservedObject var vm: ImportViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = BrowserState()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DisclosureGroup("Anleitung", isExpanded: $browser.showHelp) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Bei Snapchat einloggen.")
                        Text("2. «Meine Daten» › «Export your Memories» einschalten › Zeitraum «Gesamte Zeit» › absenden.")
                        Text("3. Warten, bis die Mail «Deine Daten sind bereit» kommt (Minuten bis Stunden).")
                        Text("4. Hier wieder öffnen › «See exports» › bei jeder Datei auf «Download» tippen. Die App lädt und liest alles selbst ein.")
                    }
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                SnapchatWebView(state: browser) { file in
                    vm.didDownloadExport(file)
                }

                if let status = browser.status {
                    HStack(spacing: 8) {
                        if browser.isDownloading { ProgressView() }
                        Text(status).font(.footnote)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.thinMaterial)
                }
            }
            .navigationTitle("Von Snapchat holen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { browser.webView?.goBack() } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Button("Meine Daten") { browser.open(BrowserState.myDataURL) }
                    Spacer()
                    Button { browser.webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }
}

@MainActor
final class BrowserState: ObservableObject {
    static let startURL = URL(string: "https://accounts.snapchat.com/")!
    static let myDataURL = URL(string: "https://accounts.snapchat.com/v2/download-my-data")!

    @Published var status: String?
    @Published var isDownloading = false
    @Published var showHelp = true
    weak var webView: WKWebView?

    func open(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }
}

// MARK: - WKWebView mit Download-Abfang

struct SnapchatWebView: UIViewRepresentable {
    @ObservedObject var state: BrowserState
    let onDownloaded: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(state: state, onDownloaded: onDownloaded) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // Login bleibt gespeichert
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        state.webView = webView
        webView.load(URLRequest(url: BrowserState.myDataURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        let state: BrowserState
        let onDownloaded: (URL) -> Void
        private var destinations: [ObjectIdentifier: URL] = [:]
        private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]

        init(state: BrowserState, onDownloaded: @escaping (URL) -> Void) {
            self.state = state
            self.onDownloaded = onDownloaded
        }

        // Fenster mit target=_blank im selben WebView öffnen
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let response = navigationResponse.response
            let mime = response.mimeType?.lowercased() ?? ""
            let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
            let isZip = mime.contains("zip") || mime == "application/octet-stream"
                || response.url?.pathExtension.lowercased() == "zip"
            if isZip || disposition.contains("attachment") || !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        // MARK: WKDownloadDelegate

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            var name = suggestedFilename.isEmpty ? "snapchat-export.zip" : suggestedFilename
            if !name.lowercased().hasSuffix(".zip") { name += ".zip" }
            let dest = ExportStore.folder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            let key = ObjectIdentifier(download)
            destinations[key] = dest

            observations[key] = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let mb = Double(progress.completedUnitCount) / 1_048_576
                let text: String
                if progress.totalUnitCount > 0 {
                    text = String(format: "Lade %@ … %.0f %% (%.0f MB)", name, progress.fractionCompleted * 100, mb)
                } else {
                    text = String(format: "Lade %@ … %.0f MB", name, mb)
                }
                Task { @MainActor in
                    self?.state.isDownloading = true
                    self?.state.status = text
                }
            }
            Task { @MainActor in
                self.state.isDownloading = true
                self.state.status = "Download gestartet: \(name)"
                self.state.showHelp = false
            }
            completionHandler(dest)
        }

        func downloadDidFinish(_ download: WKDownload) {
            let key = ObjectIdentifier(download)
            observations[key] = nil
            guard let dest = destinations.removeValue(forKey: key) else { return }
            Task { @MainActor in
                self.state.isDownloading = false
                self.state.status = "✓ \(dest.lastPathComponent) geladen – wird eingelesen. Weitere Dateien? Sonst «Fertig»."
                self.onDownloaded(dest)
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            let key = ObjectIdentifier(download)
            observations[key] = nil
            destinations[key] = nil
            Task { @MainActor in
                self.state.isDownloading = false
                self.state.status = "Download fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }
}
