import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CellAnalyzerCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var apiKey = ""
    @State private var exportFile: ExportFile?
    @State private var exportError: String?
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Sample interval", selection: $settings.sampleInterval) {
                    Text("5 s").tag(5.0)
                    Text("10 s").tag(10.0)
                    Text("30 s").tag(30.0)
                    Text("60 s").tag(60.0)
                }
                Toggle("Keep recording in background", isOn: $settings.backgroundRecording)
            } header: {
                Text("Recording")
            } footer: {
                Text("Samples are also taken on every radio change and after moving 25 m. Background recording uses location updates and costs battery.")
            }

            Section {
                SecureField("API key", text: $apiKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { settings.openCellIDKey = apiKey }
                Button("Save key") { settings.openCellIDKey = apiKey }
                    .disabled(apiKey == settings.openCellIDKey)
                Toggle("Look up new cells automatically", isOn: $settings.autoLookup)
                    .disabled(!settings.hasOpenCellIDKey)
                Link("Get a free key at opencellid.org", destination: URL(string: "https://opencellid.org/register.php")!)
            } header: {
                Text("Cell database (OpenCellID)")
            } footer: {
                Text("Used to show the registered position of a cell. A lookup sends only the cell identity (MCC, MNC, area code, cell ID) to OpenCellID. Your location is never sent.")
            }

            Section {
                Stepper("gNB ID length: \(settings.gnbIdBits) bits", value: $settings.gnbIdBits, in: 22...32)
            } header: {
                Text("5G decoding")
            } footer: {
                Text("A 36-bit NR cell ID splits into a gNB ID and a local cell ID. The split is operator specific; 24 bits is the most common.")
            }

            Section {
                ForEach(ExportFormat.allCases) { format in
                    Button {
                        export(format)
                    } label: {
                        Label("Export \(format.displayName)", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Import JSON", systemImage: "square.and.arrow.down")
                }
                if let importMessage {
                    Text(importMessage).font(.caption).foregroundStyle(.secondary)
                }
                if let exportError {
                    Text(exportError).font(.caption).foregroundStyle(.red)
                }
                Button("Delete all data", role: .destructive) { confirmDelete = true }
            } header: {
                Text("Data (\(model.store.observations.count) measurements)")
            }

            Section("Help") {
                NavigationLink("Using Field Test Mode") { HelpView() }
                NavigationLink("What iOS does and doesn't allow") { LimitationsView() }
            }

            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
            }
        }
        .navigationTitle("Settings")
        .onAppear { apiKey = model.settings.openCellIDKey }
        .sheet(item: $exportFile) { file in
            ShareSheet(url: file.url)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            importFile(result)
        }
        .confirmationDialog("Delete all measurements and lookups?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { model.store.deleteAll() }
        }
    }

    private func export(_ format: ExportFormat) {
        do {
            let data = try Exporters.data(format, observations: model.store.observations, aggregates: model.cells,
                                          gnbIdBits: model.settings.gnbIdBits)
            let stamp = Date().formatted(.iso8601.year().month().day())
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cell-analyzer-\(stamp).\(format.fileExtension)")
            try data.write(to: url, options: .atomic)
            exportError = nil
            exportFile = ExportFile(url: url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let observations = try Exporters.importJSON(Data(contentsOf: url))
            let before = model.store.observations.count
            model.store.add(contentsOf: observations)
            importMessage = "Imported \(model.store.observations.count - before) new measurements."
        } catch {
            importMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}

struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// UIKit share sheet for exported files.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
