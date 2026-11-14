import SwiftUI
import UIKit
import PhotosUI
import CellAnalyzerCore

/// One imported screenshot (or pasted text) with the cells recognized in it.
struct CaptureDraft: Identifiable {
    let id = UUID()
    var thumbnail: UIImage?
    var timestamp: Date
    var timestampFromMetadata: Bool
    var location: GeoPoint?
    var observations: [CellObservation]
    var include = true
    var lines: [String]
    var recognizedPairs: [RecognizedPair]
    var signCorrected: [FieldTestField]
    var error: String?
}

struct CaptureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var drafts: [CaptureDraft] = []
    @State private var processed = 0
    @State private var total = 0
    @State private var showPaste = false
    @State private var pastedText = ""

    private var isProcessing: Bool { processed < total }
    private var selectedCount: Int { drafts.filter(\.include).flatMap(\.observations).count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 30, matching: .images) {
                        Label("Choose Field Test screenshots", systemImage: "photo.on.rectangle.angled")
                    }
                    Button {
                        pastedText = UIPasteboard.general.string ?? ""
                        showPaste = true
                    } label: {
                        Label("Paste copied text", systemImage: "doc.on.clipboard")
                    }
                } footer: {
                    Text("Text is recognized on the device. Tip: Live Text can copy text from a screenshot too. If you were recording while taking the screenshots, each one is placed on the map using its timestamp.")
                }

                if isProcessing {
                    Section {
                        ProgressView(value: Double(processed), total: Double(max(total, 1))) {
                            Text("Reading \(processed + 1) of \(total)…")
                        }
                    }
                }

                ForEach($drafts) { $draft in
                    DraftSection(draft: $draft)
                }
            }
            .navigationTitle("Import measurements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save \(selectedCount)") { save() }
                        .disabled(selectedCount == 0 || isProcessing)
                }
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await process(items) }
            }
            .sheet(isPresented: $showPaste) {
                PasteTextSheet(text: $pastedText) { text in
                    addPastedText(text)
                }
            }
        }
    }

    // MARK: Processing

    private func process(_ items: [PhotosPickerItem]) async {
        processed = 0
        total = items.count
        let simLabel = model.telephony.dataService?.label
        for item in items {
            defer { processed += 1 }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let result = try await FieldTestOCR.recognize(imageData: data)
                let timestamp = result.imageDate ?? Date()
                let location = model.bestLocation(for: timestamp)
                var observations = result.capture.observations(timestamp: timestamp, location: location)
                for i in observations.indices { observations[i].simSlot = simLabel }
                let thumbnail = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 90, height: 195))
                drafts.append(CaptureDraft(
                    thumbnail: thumbnail, timestamp: timestamp, timestampFromMetadata: result.imageDate != nil,
                    location: location, observations: observations, include: !observations.isEmpty,
                    lines: result.lines, recognizedPairs: result.capture.pairs,
                    signCorrected: result.capture.cells.flatMap(\.signCorrected)))
            } catch {
                drafts.append(CaptureDraft(thumbnail: nil, timestamp: Date(), timestampFromMetadata: false,
                                           location: nil, observations: [], include: false, lines: [],
                                           recognizedPairs: [], signCorrected: [], error: error.localizedDescription))
            }
        }
        pickerItems = []
    }

    private func addPastedText(_ text: String) {
        let capture = FieldTestParser.parse(text: text)
        let now = Date()
        let location = model.bestLocation(for: now)
        var observations = capture.observations(timestamp: now, location: location)
        for i in observations.indices {
            observations[i].source = .manual
            observations[i].simSlot = model.telephony.dataService?.label
        }
        drafts.append(CaptureDraft(thumbnail: nil, timestamp: now, timestampFromMetadata: false, location: location,
                                   observations: observations, include: !observations.isEmpty,
                                   lines: text.components(separatedBy: .newlines), recognizedPairs: capture.pairs,
                                   signCorrected: capture.cells.flatMap(\.signCorrected)))
    }

    private func save() {
        let observations = drafts.filter(\.include).flatMap { draft in
            draft.observations.map { o -> CellObservation in
                var o = o
                o.timestamp = draft.timestamp
                o.location = draft.location
                return o
            }
        }
        model.store.add(contentsOf: observations)
        dismiss()
    }
}

private struct DraftSection: View {
    @Binding var draft: CaptureDraft
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                if let thumbnail = draft.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable().scaledToFit()
                        .frame(width: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let error = draft.error {
                        Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
                    } else if draft.observations.isEmpty {
                        Label("No cell data recognized", systemImage: "questionmark.circle")
                            .foregroundStyle(.orange)
                        Text("Make sure the screenshot shows a Field Test page with serving-cell values, such as Serving Cell Info or Serving Cell Meas.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(draft.recognizedPairs.filter { !$0.isNeighbor }.count) values recognized")
                            .font(.subheadline.weight(.medium))
                    }
                    DatePicker("Taken", selection: $draft.timestamp)
                        .font(.caption)
                    if !draft.timestampFromMetadata {
                        Text("No timestamp in the image – check the time.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    if let location = draft.location {
                        Label(Format.coordinate(location), systemImage: "location.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button {
                            draft.location = model.location.currentPoint
                        } label: {
                            Label("Use current location", systemImage: "location")
                        }
                        .font(.caption)
                        .disabled(model.location.currentPoint == nil)
                    }
                }
            }

            ForEach($draft.observations) { $observation in
                NavigationLink {
                    ObservationForm(observation: $observation)
                        .navigationTitle("Review")
                } label: {
                    ObservationSummaryRow(observation: observation)
                }
            }

            if !draft.signCorrected.isEmpty {
                Label("A missing minus sign was added to \(draft.signCorrected.map(\.rawValue).joined(separator: ", ")). Please check.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            if !draft.observations.isEmpty {
                Toggle("Include", isOn: $draft.include)
            }

            if !draft.lines.isEmpty {
                DisclosureGroup("Recognized text") {
                    Text(draft.lines.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct ObservationSummaryRow: View {
    let observation: CellObservation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                RadioBadge(radio: observation.radio)
                if let plmn = observation.plmn { Text(plmn).font(.caption.monospacedDigit()) }
                Spacer()
                SignalBars(grade: SignalQuality.overallGrade(for: observation))
            }
            Text(details)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var details: String {
        var parts: [String] = []
        if let cellId = observation.cellId { parts.append("CID \(cellId)") }
        if let pci = observation.pci { parts.append("PCI \(pci)") }
        if let channel = observation.channel { parts.append("CH \(channel)") }
        if let band = observation.resolvedBand { parts.append(observation.radio.family == .nr ? "n\(band)" : "B\(band)") }
        if let rsrp = observation.rsrp { parts.append("RSRP \(Format.dB(rsrp, unit: "dBm"))") }
        if let sinr = observation.sinr { parts.append("SINR \(Format.dB(sinr, unit: "dB"))") }
        return parts.isEmpty ? "No values" : parts.joined(separator: " · ")
    }
}

private struct PasteTextSheet: View {
    @Binding var text: String
    var onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body.monospaced())
                .padding(.horizontal)
                .navigationTitle("Paste Field Test text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Parse") {
                            onAdd(text)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
