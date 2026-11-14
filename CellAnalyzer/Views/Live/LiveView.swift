import SwiftUI
import UIKit
import CellAnalyzerCore

struct LiveView: View {
    @Environment(AppModel.self) private var model
    @State private var showCapture = false
    @State private var manualDraft: CellObservation?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                servicesSection
                recordingCard
                latestCellCard
                captureCard
                connectionCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Live")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { HelpView() } label: { Image(systemName: "questionmark.circle") }
            }
        }
        .refreshable {
            model.telephony.refresh()
            model.location.refreshOnce()
        }
        .sheet(isPresented: $showCapture) {
            CaptureView()
        }
        .sheet(item: $manualDraft) { draft in
            NavigationStack {
                ObservationEditorView(observation: draft, isNew: true)
            }
        }
    }

    // MARK: Sections

    @ViewBuilder private var servicesSection: some View {
        if model.telephony.services.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("No cellular service", systemImage: "simcard")
                    .font(.headline)
                Text("No SIM was detected, the device has no modem (simulator, Wi-Fi iPad) or Airplane Mode is on.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .card()
        } else {
            ForEach(model.telephony.services) { service in
                ServiceCard(service: service)
            }
        }
    }

    private var recordingCard: some View {
        let recorder = model.recorder
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording").font(.headline)
                    Text(recorder.isRecording
                         ? "Logging radio changes and position\(model.settings.backgroundRecording ? ", also in background" : "")."
                         : "Log radio technology and position over time, e.g. during a drive.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    recorder.toggle()
                } label: {
                    Label(recorder.isRecording ? "Stop" : "Start",
                          systemImage: recorder.isRecording ? "stop.fill" : "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : .accentColor)
            }
            if recorder.isRecording, let started = recorder.startedAt {
                HStack {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        StatTile(title: "Duration", value: Format.duration(context.date.timeIntervalSince(started)), systemImage: "timer")
                    }
                    StatTile(title: "Samples", value: "\(recorder.samplesThisSession)", systemImage: "list.number")
                }
            }
            if !model.location.isAuthorized {
                Button("Allow location access") { model.location.requestPermission() }
                    .font(.subheadline)
            }
        }
        .card()
    }

    @ViewBuilder private var latestCellCard: some View {
        if let latest = model.latestMeasured {
            NavigationLink {
                if let cell = model.cell(containing: latest) {
                    CellDetailView(cellKey: cell.key)
                } else {
                    ObservationEditorView(observation: latest, isNew: false)
                }
            } label: {
                LatestMeasurementCard(observation: latest)
            }
            .buttonStyle(.plain)
        }
    }

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add cell measurements").font(.headline)
            Text("iOS hides cell IDs and signal levels from apps. Open Field Test Mode (dial *3001#12345#*), take screenshots, and import them here.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    showCapture = true
                } label: {
                    Label("Import screenshots", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    manualDraft = newManualObservation()
                } label: {
                    Label("Manual", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)
            }
            Button {
                UIPasteboard.general.string = "*3001#12345#*"
            } label: {
                Label("Copy Field Test code", systemImage: "doc.on.doc")
                    .font(.subheadline)
            }
        }
        .card()
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connection").font(.headline)
            LabeledContent("Active path") {
                Label(model.path.interface.rawValue, systemImage: model.path.interface.systemImage)
            }
            LabeledContent("Cellular data for this app", value: model.telephony.cellularDataState.label)
            if model.path.isExpensive { LabeledContent("Metered", value: "Yes") }
            if model.path.isConstrained { LabeledContent("Low Data Mode", value: "On") }
            if let location = model.location.lastLocation {
                LabeledContent("Position") {
                    Text("\(Format.coordinate(GeoPoint(location))) ±\(Int(location.horizontalAccuracy)) m")
                        .monospacedDigit()
                }
            } else {
                LabeledContent("Position", value: model.location.isAuthorized ? "Waiting for GPS…" : "Not allowed")
            }
        }
        .font(.subheadline)
        .card()
    }

    private func newManualObservation() -> CellObservation {
        let service = model.telephony.dataService
        var radio = service?.radio ?? .lte
        if radio == .unknown { radio = .lte }
        // Pre-fill the network from the most recent capture; iOS no longer exposes MCC/MNC.
        let previous = model.store.observations.last { $0.mcc != nil }
        return CellObservation(source: .manual, radio: radio, simSlot: service?.label,
                               mcc: previous?.mcc, mnc: previous?.mnc, mncDigits: previous?.mncDigits,
                               location: model.location.currentPoint)
    }
}

private struct ServiceCard: View {
    let service: CellularService
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(service.label, systemImage: "simcard")
                    .font(.headline)
                if service.isDataService {
                    Text("DATA").font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                Spacer()
                RadioBadge(radio: service.radio, large: true)
            }
            Text(service.radio.explanation)
                .font(.subheadline).foregroundStyle(.secondary)
            if let changed = model.telephony.lastChange {
                Text("Last change \(changed, style: .relative) ago")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private func subtitle(for cell: CellAggregate) -> String {
        var parts: [String] = [cell.operatorDescription]
        if let band = cell.bandLabel { parts.append(band) }
        if let pci = cell.pci { parts.append("PCI \(pci)") }
        return parts.joined(separator: " · ")
    }
}

struct LatestMeasurementCard: View {
    let observation: CellObservation
    @Environment(AppModel.self) private var model

    var body: some View {
        let family = observation.radio.family
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Latest measured cell").font(.headline)
                    Text("\(observation.source.displayName) · \(observation.timestamp, style: .relative) ago")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                RadioBadge(radio: observation.radio)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            if let cell = model.cell(containing: observation) {
                Text(cell.title(gnbIdBits: model.settings.gnbIdBits))
                    .font(.title3.weight(.semibold))
                Text(subtitle(for: cell))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if observation.hasSignal {
                VStack(spacing: 10) {
                    if observation.rsrp != nil || observation.rssi == nil {
                        SignalGaugeRow(metric: .rsrp, value: observation.rsrp, family: family)
                    }
                    if observation.rsrq != nil { SignalGaugeRow(metric: .rsrq, value: observation.rsrq, family: family) }
                    if observation.sinr != nil { SignalGaugeRow(metric: .sinr, value: observation.sinr, family: family) }
                    if observation.rssi != nil { SignalGaugeRow(metric: .rssi, value: observation.rssi, family: family) }
                }
            }
        }
        .card()
    }

    private func subtitle(for cell: CellAggregate) -> String {
        var parts: [String] = [cell.operatorDescription]
        if let band = cell.bandLabel { parts.append(band) }
        if let pci = cell.pci { parts.append("PCI \(pci)") }
        return parts.joined(separator: " · ")
    }
}
