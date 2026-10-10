import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var vm = ImportViewModel()
    @State private var showPicker = false
    @State private var confirmReset = false
    @State private var confirmDelete = false
    @State private var showSnapchat = false

    var body: some View {
        NavigationStack {
            Form {
                fetchSection
                exportSection
                if !vm.warnings.isEmpty { warningSection }
                if vm.phase != .idle && vm.phase != .scanning && !vm.items.isEmpty {
                    summarySection
                    settingsSection
                    importSection
                }
                if !vm.log.isEmpty { logSection }
                Section {
                    Button("Import-Verlauf zurücksetzen", role: .destructive) { confirmReset = true }
                        .disabled(vm.phase == .importing)
                } footer: {
                    Text("Die App merkt sich, welche Memories schon importiert wurden, damit beim nächsten Durchlauf nichts doppelt im Album landet.")
                }
            }
            .navigationTitle("SnapMemories")
            .onAppear {
                if vm.items.isEmpty && vm.phase == .idle { vm.loadDownloadedExports() }
            }
            .fileImporter(isPresented: $showPicker,
                          allowedContentTypes: [.zip, .folder, .json, .html],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { vm.load(urls) }
            }
            .confirmationDialog("Verlauf wirklich zurücksetzen? Beim nächsten Import werden alle Memories erneut ins Album gelegt.",
                                isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Zurücksetzen", role: .destructive) { vm.resetHistory() }
            }
            .confirmationDialog("Heruntergeladene Export-ZIPs löschen? Bereits importierte Fotos bleiben im Album.",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) { vm.deleteDownloadedExports() }
            }
            .fullScreenCover(isPresented: $showSnapchat) {
                SnapchatFetchView(vm: vm)
            }
        }
    }

    // MARK: - Abschnitte

    private var howToSection: some View {
        Section {
            DisclosureGroup("So holst du deine Memories") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Snapchat › Profil › Einstellungen › Meine Daten (oder accounts.snapchat.com).")
                    Text("2. «Export your Memories» aktivieren, Zeitraum «Gesamte Zeit» wählen, absenden.")
                    Text("3. Wenn die Mail kommt: ZIP-Datei(en) herunterladen und in der Dateien-App unter «Auf meinem iPhone» speichern.")
                    Text("4. Hier alle ZIP-Dateien des Exports auf einmal auswählen (oder den entpackten Ordner).")
                }
                .font(.callout)
                .padding(.vertical, 4)
            }
        }
    }

    private var fetchSection: some View {
        Section {
            Button {
                showSnapchat = true
            } label: {
                Label("Bei Snapchat einloggen & Export holen", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
            }
            .disabled(vm.phase == .importing)

            if !vm.downloadedExports.isEmpty {
                LabeledContent("In der App gespeichert",
                               value: "\(vm.downloadedExports.count) ZIP · \(vm.downloadedSizeText)")
                Button {
                    vm.loadDownloadedExports()
                } label: {
                    Label("Gespeicherte Exporte einlesen", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(vm.phase == .importing)
                Button("Gespeicherte Exporte löschen", role: .destructive) { confirmDelete = true }
                    .disabled(vm.phase == .importing)
            }
        } header: {
            Text("Direkt von Snapchat")
        } footer: {
            Text("Du loggst dich im eingebauten Browser bei Snapchat ein, forderst den Export an und tippst später auf «Download». Die App lädt die Dateien selbst und liest sie automatisch ein. Dein Passwort geht nur an Snapchat.")
        }
    }

    private var exportSection: some View {
        Section("Oder: Dateien aus der Dateien-App") {
            Button {
                showPicker = true
            } label: {
                Label(vm.pickedNames.isEmpty ? "Export-Dateien wählen" : "Andere Dateien wählen",
                      systemImage: "doc.zipper")
            }
            .disabled(vm.phase == .importing)

            ForEach(vm.pickedNames, id: \.self) { name in
                Text(name).font(.footnote).foregroundStyle(.secondary)
            }
            if vm.phase == .scanning {
                HStack { ProgressView(); Text("Export wird gelesen …") }
            }
        }
    }

    private var warningSection: some View {
        Section {
            ForEach(vm.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }

    private var summarySection: some View {
        Section("Gefunden") {
            LabeledContent("Fotos", value: "\(vm.photoCount)")
            LabeledContent("Videos", value: "\(vm.videoCount)")
            if let first = vm.firstDate, let last = vm.lastDate {
                LabeledContent("Zeitraum",
                               value: "\(first.formatted(date: .numeric, time: .omitted)) – \(last.formatted(date: .numeric, time: .omitted))")
            }
            LabeledContent("Im Export enthalten", value: "\(vm.localCount)")
            if vm.remoteCount > 0 {
                LabeledContent("Nur als Download-Link", value: "\(vm.remoteCount)")
            }
            if vm.approximateCount > 0 {
                LabeledContent("Nur Tag bekannt (ohne Uhrzeit)", value: "\(vm.approximateCount)")
            }
            LabeledContent("Schon importiert", value: "\(vm.alreadyImported)")
        }
    }

    private var settingsSection: some View {
        Section {
            TextField("Albumname", text: $vm.albumName)
            Toggle("Text & Sticker ins Foto einbrennen", isOn: $vm.burnOverlays)
            if vm.remoteCount > 0 {
                Toggle("Fehlende Memories herunterladen", isOn: $vm.downloadMissing)
            }
        } header: {
            Text("Einstellungen")
        } footer: {
            Text(vm.remoteCount > 0
                 ? "Download-Links von Snapchat laufen nach einigen Tagen ab. Bei «Link abgelaufen» einfach einen neuen Export anfordern."
                 : "Jedes Memory bekommt sein Originaldatum und erscheint so auch in «Alle Fotos» am richtigen Tag.")
        }
        .disabled(vm.phase == .importing)
    }

    private var importSection: some View {
        Section("Import") {
            if vm.phase == .importing {
                ProgressView(value: Double(vm.done), total: Double(max(vm.total, 1))) {
                    Text("\(vm.done) von \(vm.total)")
                } currentValueLabel: {
                    Text(vm.currentLabel)
                }
                Text("Bitte die App geöffnet lassen, bis der Import fertig ist.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Abbrechen", role: .destructive) { vm.cancel() }
            } else {
                let count = vm.pending.count
                Button {
                    vm.startImport()
                } label: {
                    Label(count == 0 ? "Alles schon importiert" : "\(count) Memories ins Album «\(vm.albumName)» importieren",
                          systemImage: "photo.on.rectangle.angled")
                }
                .disabled(count == 0)
            }
        }
    }

    private var logSection: some View {
        Section("Protokoll") {
            ForEach(Array(vm.log.prefix(200).enumerated()), id: \.offset) { _, line in
                Text(line).font(.footnote)
            }
        }
    }
}

#Preview {
    ContentView()
}
