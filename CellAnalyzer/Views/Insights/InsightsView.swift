import SwiftUI
import Charts
import CellAnalyzerCore

struct InsightsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = model.summary
        List {
            if summary.observationCount == 0 {
                ContentUnavailableView {
                    Label("No data yet", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("Record a session on the Live tab or import Field Test screenshots to see statistics and security checks.")
                }
            } else {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        StatTile(title: "Samples", value: "\(summary.observationCount)", systemImage: "list.number")
                        StatTile(title: "Cells", value: "\(summary.uniqueCells)", systemImage: "cellularbars")
                        StatTile(title: "Handovers", value: "\(summary.handovers)", systemImage: "arrow.left.arrow.right")
                        StatTile(title: "RAT changes", value: "\(summary.radioChanges)", systemImage: "arrow.triangle.2.circlepath")
                        StatTile(title: "5G time", value: "\(Int((summary.fiveGShare * 100).rounded())) %", systemImage: "5.circle", tint: .purple)
                        StatTile(title: "Span", value: Format.duration(summary.duration), systemImage: "clock")
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .listRowBackground(Color.clear)
                }

                securitySection

                if !summary.timeByRadio.isEmpty {
                    Section {
                        RadioTimeChart(timeByRadio: summary.timeByRadio)
                    } header: {
                        Text("Time on each technology")
                    } footer: {
                        Text("From iOS samples while recording. Gaps over 5 minutes are not counted.")
                    }
                }

                if !summary.bandUsage.isEmpty {
                    Section("Bands") {
                        BandUsageChart(bandUsage: summary.bandUsage)
                    }
                }

                if let rsrp = summary.rsrp {
                    Section("Signal overview") {
                        InfoRow("Average RSRP", Format.dB(rsrp.mean, unit: "dBm"))
                        InfoRow("Range", "\(Format.dB(rsrp.min, unit: "dBm")) … \(Format.dB(rsrp.max, unit: "dBm"))")
                        if let sinr = summary.sinr {
                            InfoRow("Average SINR", Format.dB(sinr.mean, unit: "dB"))
                        }
                        SignalTimelineChart(observations: model.store.observations)
                    }
                }

                if !summary.operators.isEmpty {
                    Section("Networks") {
                        ForEach(operatorCounts(summary), id: \.name) { entry in
                            LabeledContent(entry.name, value: "\(entry.count)")
                        }
                    }
                }

                Section {
                    NavigationLink {
                        EventsTimelineView()
                    } label: {
                        Label("Event timeline (\(summary.events.count))", systemImage: "list.bullet.rectangle")
                    }
                }
            }
        }
        .navigationTitle("Insights")
        .navigationDestination(for: CellKey.self) { CellDetailView(cellKey: $0) }
    }

    private struct OperatorCount {
        let name: String
        let count: Int
    }

    private func operatorCounts(_ summary: SessionSummary) -> [OperatorCount] {
        summary.operators.map { OperatorCount(name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    @ViewBuilder private var securitySection: some View {
        Section {
            if model.anomalies.isEmpty {
                Label("No suspicious patterns found", systemImage: "checkmark.shield")
                    .foregroundStyle(.green)
            } else {
                ForEach(model.anomalies) { anomaly in
                    if let key = anomaly.cellKey, model.cell(for: key) != nil {
                        NavigationLink(value: key) { AnomalyRow(anomaly: anomaly) }
                    } else {
                        AnomalyRow(anomaly: anomaly)
                    }
                }
            }
        } header: {
            Text("Security checks")
        } footer: {
            Text("Heuristics for fake base stations (IMSI catchers) and misconfigured cells. One finding alone is rarely conclusive; look for several close together in time and place.")
        }
    }
}

private struct RadioTimeChart: View {
    let timeByRadio: [RadioTechnology: TimeInterval]

    private struct Entry: Identifiable {
        var id: String { radio.rawValue }
        let radio: RadioTechnology
        let minutes: Double
    }

    var body: some View {
        let entries = timeByRadio.map { Entry(radio: $0.key, minutes: $0.value / 60) }
            .sorted { $0.radio.generation > $1.radio.generation }
        Chart(entries) { entry in
            BarMark(x: .value("Minutes", entry.minutes), y: .value("Technology", entry.radio.displayName))
                .foregroundStyle(entry.radio.generation.color)
                .annotation(position: .trailing) {
                    Text(Format.duration(entry.minutes * 60)).font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartXAxisLabel("minutes")
        .frame(height: CGFloat(max(entries.count, 1)) * 34 + 30)
    }
}

private struct BandUsageChart: View {
    let bandUsage: [String: Int]

    private struct Entry: Identifiable {
        var id: String { band }
        let band: String
        let count: Int
    }

    var body: some View {
        let entries = bandUsage.map { Entry(band: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
        Chart(entries) { entry in
            BarMark(x: .value("Band", entry.band), y: .value("Samples", entry.count))
                .foregroundStyle(entry.band.hasPrefix("n") ? Color.purple : Color.blue)
        }
        .frame(height: 160)
    }
}

private struct SignalTimelineChart: View {
    let observations: [CellObservation]

    private struct Point: Identifiable {
        let id: UUID
        let date: Date
        let rsrp: Double
        let family: String
    }

    var body: some View {
        let points = observations.compactMap { o in
            o.rsrp.map { Point(id: o.id, date: o.timestamp, rsrp: $0, family: o.radio.family.displayName) }
        }
        if points.count > 1 {
            Chart(points) { p in
                PointMark(x: .value("Time", p.date), y: .value("RSRP", p.rsrp))
                    .foregroundStyle(by: .value("Technology", p.family))
                    .symbolSize(20)
            }
            .chartYScale(domain: -140 ... -44)
            .chartYAxisLabel("RSRP (dBm)")
            .frame(height: 180)
        }
    }
}

struct EventsTimelineView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let events = model.summary.events.reversed()
        List {
            if events.isEmpty {
                ContentUnavailableView("No events", systemImage: "list.bullet.rectangle",
                                       description: Text("Radio changes, handovers and area changes appear here."))
            }
            ForEach(Array(events)) { event in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: event.kind))
                        .foregroundStyle(color(for: event.kind))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).font(.subheadline)
                        HStack {
                            Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                            if let sim = event.simSlot { Text("· \(sim)") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Events")
    }

    private func icon(for kind: NetworkEvent.Kind) -> String {
        switch kind {
        case .radioChange: return "arrow.triangle.2.circlepath"
        case .handover: return "arrow.left.arrow.right"
        case .areaChange: return "square.dashed"
        }
    }

    private func color(for kind: NetworkEvent.Kind) -> Color {
        switch kind {
        case let .radioChange(_, to): return to.generation.color
        case .handover: return .blue
        case .areaChange: return .orange
        }
    }
}
