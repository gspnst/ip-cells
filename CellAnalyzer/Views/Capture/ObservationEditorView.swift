import SwiftUI
import CellAnalyzerCore

/// Editable form for all fields of an observation, with a live preview of derived values.
struct ObservationForm: View {
    @Binding var observation: CellObservation
    @Environment(AppModel.self) private var model

    private static let radios: [RadioTechnology] = [.lte, .nrNSA, .nrSA, .umts, .hsdpa, .gsm, .edge, .unknown]

    var body: some View {
        Form {
            Section("Radio") {
                Picker("Technology", selection: $observation.radio) {
                    ForEach(Self.radios, id: \.self) { Text($0.displayName).tag($0) }
                }
                DatePicker("Time", selection: $observation.timestamp)
            }

            Section {
                OptionalIntField(title: "MCC", value: $observation.mcc)
                OptionalIntField(title: "MNC", value: $observation.mnc)
                OptionalIntField(title: areaLabel, value: $observation.areaCode, allowHex: true)
                OptionalIntField(title: cellIdLabel, value: $observation.cellId, allowHex: true)
                OptionalIntField(title: pciLabel, value: $observation.pci)
            } header: {
                Text("Identity")
            } footer: {
                if let mcc = observation.mcc {
                    Text(OperatorDirectory.describe(mcc: mcc, mnc: observation.mnc))
                }
            }

            Section {
                OptionalIntField(title: channelLabel, value: $observation.channel)
                OptionalIntField(title: "Band", value: $observation.band)
                OptionalDoubleField(title: "Bandwidth", value: $observation.bandwidthMHz, unit: "MHz")
            } header: {
                Text("Spectrum")
            } footer: {
                if let info = channelInfo {
                    Text([info.bandLabel, info.downlinkMHz.map { "DL " + Spectrum.formatFrequency($0) }]
                            .compactMap { $0 }.joined(separator: " · "))
                }
            }

            Section("Signal") {
                OptionalDoubleField(title: "RSRP", value: $observation.rsrp, unit: "dBm")
                OptionalDoubleField(title: "RSRQ", value: $observation.rsrq, unit: "dB")
                OptionalDoubleField(title: "SINR", value: $observation.sinr, unit: "dB")
                OptionalDoubleField(title: "RSSI", value: $observation.rssi, unit: "dBm")
                OptionalIntField(title: "Timing advance", value: $observation.timingAdvance)
            }

            Section("Location") {
                if let location = observation.location {
                    LabeledContent("Position", value: Format.coordinate(location))
                    Button("Remove position", role: .destructive) { observation.location = nil }
                }
                Button("Use current position") { observation.location = model.location.currentPoint }
                    .disabled(model.location.currentPoint == nil)
            }

            Section("Notes") {
                TextField("Notes", text: Binding(
                    get: { observation.notes ?? "" },
                    set: { observation.notes = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
            }
        }
    }

    private var family: RadioFamily { observation.radio.family }
    private var areaLabel: String { family == .lte || family == .nr ? "TAC" : "LAC" }
    private var cellIdLabel: String {
        switch family {
        case .lte: return "ECI (cell ID)"
        case .nr: return "NCI (cell ID)"
        default: return "Cell ID"
        }
    }
    private var pciLabel: String {
        switch family {
        case .umts: return "PSC"
        case .gsm: return "BSIC"
        default: return "PCI"
        }
    }
    private var channelLabel: String {
        switch family {
        case .lte: return "EARFCN"
        case .nr: return "NR-ARFCN"
        case .umts: return "UARFCN"
        default: return "ARFCN"
        }
    }

    private var channelInfo: ChannelInfo? {
        guard let channel = observation.channel else { return nil }
        return Spectrum.channelInfo(family: family, channel: channel, mcc: observation.mcc, reportedBand: observation.band)
    }
}

/// Edits a stored observation (or creates a new one) and saves to the store.
struct ObservationEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CellObservation
    let isNew: Bool

    init(observation: CellObservation, isNew: Bool) {
        _draft = State(initialValue: observation)
        self.isNew = isNew
    }

    var body: some View {
        ObservationForm(observation: $draft)
            .navigationTitle(isNew ? "New measurement" : "Measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isNew {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if isNew { model.store.add(draft) } else { model.store.update(draft) }
                        dismiss()
                    }
                }
                if !isNew {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Delete", role: .destructive) {
                            model.store.delete(ids: [draft.id])
                            dismiss()
                        }
                    }
                }
            }
    }
}
