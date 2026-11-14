import SwiftUI
import MapKit
import Charts
import CellAnalyzerCore

struct CellDetailView: View {
    let cellKey: CellKey
    @Environment(AppModel.self) private var model

    var body: some View {
        if let cell = model.cell(for: cellKey) {
            CellDetailContent(cell: cell)
        } else {
            ContentUnavailableView("Cell not found", systemImage: "questionmark.circle",
                                   description: Text("Its measurements may have been deleted."))
        }
    }
}

private struct CellDetailContent: View {
    let cell: CellAggregate
    @Environment(AppModel.self) private var model

    var body: some View {
        let gnbIdBits = model.settings.gnbIdBits
        let observations = model.observations(for: cell)
        let identity = cell.decodedIdentity(gnbIdBits: gnbIdBits)
        let channel = cell.channelInfo

        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        RadioBadge(radio: cell.radio)
                        if let band = cell.bandLabel { Text(band).font(.headline) }
                        Spacer()
                        SignalBars(grade: cell.overallGrade)
                    }
                    Text(cell.title(gnbIdBits: gnbIdBits)).font(.title2.bold())
                    Text(operatorLine).font(.subheadline).foregroundStyle(.secondary)
                    Text("Seen \(cell.observationCount)× · \(cell.firstSeen.formatted(date: .abbreviated, time: .shortened)) – \(cell.lastSeen.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            let cellAnomalies = model.anomalies(for: cell.key)
            if !cellAnomalies.isEmpty {
                Section("Findings") {
                    ForEach(cellAnomalies) { AnomalyRow(anomaly: $0) }
                }
            }

            identitySection(identity)
            spectrumSection(channel)
            signalSection(observations)
            locationSection(observations)

            Section("Measurements") {
                ForEach(observations.reversed()) { o in
                    NavigationLink {
                        ObservationEditorView(observation: o, isNew: false)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(o.timestamp.formatted(date: .abbreviated, time: .standard)).font(.subheadline)
                                Text(o.source.displayName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let rsrp = o.rsrp { Text(Format.dB(rsrp, unit: "dBm")).monospacedDigit() }
                            GradeDot(grade: SignalQuality.overallGrade(for: o))
                        }
                    }
                }
                .onDelete { offsets in
                    let reversed = Array(observations.reversed())
                    model.store.delete(ids: Set(offsets.map { reversed[$0].id }))
                }
            }
        }
        .navigationTitle(cell.family == .nr ? "5G cell" : "\(cell.family.displayName) cell")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var operatorLine: String {
        var line = cell.operatorDescription
        if let mcc = cell.mcc, let country = OperatorDirectory.country(mcc: mcc), country.isoCode != "XX" {
            line = country.flag + " " + line
        }
        return line
    }

    // MARK: Identity

    @ViewBuilder
    private func identitySection(_ identity: DecodedCellIdentity?) -> some View {
        Section {
            if let identity {
                InfoRow(cellIdName, "\(identity.rawCellId)")
                InfoRow("Hex", identity.hexCellId)
                if let site = identity.siteId {
                    InfoRow(identity.siteLabel, "\(site)",
                            help: cell.family == .lte ? "The eNodeB is the base station site; one site usually serves 3+ sectors on several carriers." : nil)
                }
                if let local = identity.localCellId {
                    InfoRow(identity.localLabel, "\(local)",
                            help: cell.family == .lte ? "Common vendor convention: \(CellIdentityDecoder.lteSectorHint(localCellId: local)) (not standardized)." : nil)
                }
                if cell.family == .nr {
                    Stepper(value: gnbBitsBinding, in: 22...32) {
                        VStack(alignment: .leading) {
                            Text("gNB ID length: \(model.settings.gnbIdBits) bits")
                            Text("Operators choose 22–32 bits. Change this if the gNB IDs look wrong.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let global = identity.globalIdentifier {
                    InfoRow(cell.family == .nr ? "NCGI" : (cell.family == .lte ? "ECGI" : "CGI"), global)
                }
                ForEach(identity.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("No global cell ID captured. This cell is identified by channel and PCI only, which is unique just locally.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let area = cell.areaCode {
                InfoRow(cell.family == .lte || cell.family == .nr ? "Tracking area (TAC)" : "Location area (LAC)",
                        "\(area) (0x\(String(area, radix: 16, uppercase: true)))")
            }
            if let pci = cell.pci {
                if let parts = CellIdentityDecoder.pciComponents(pci, family: cell.family), cell.family == .lte || cell.family == .nr {
                    InfoRow("PCI", "\(pci)", help: "SSS group \(parts.group), PSS \(parts.id). Neighbouring cells on one frequency must have different PCIs.")
                } else {
                    InfoRow(cell.family == .umts ? "PSC" : "PCI", "\(pci)")
                }
            }
            if cell.pcisSeen.count > 1 {
                InfoRow("PCIs seen", cell.pcisSeen.sorted().map(String.init).joined(separator: ", "))
            }
        } header: {
            Text("Identity")
        }
    }

    private var gnbBitsBinding: Binding<Int> {
        Binding(get: { model.settings.gnbIdBits }, set: { model.settings.gnbIdBits = $0 })
    }

    private var cellIdName: String {
        switch cell.family {
        case .lte: return "ECI"
        case .nr: return "NCI"
        default: return "Cell ID"
        }
    }

    // MARK: Spectrum

    @ViewBuilder
    private func spectrumSection(_ info: ChannelInfo?) -> some View {
        Section("Spectrum") {
            if let info {
                if let label = info.bandLabel {
                    InfoRow("Band", info.bandName.map { "\(label) · \($0)" } ?? label)
                }
                if !info.alternativeBands.isEmpty {
                    InfoRow("Also matches", info.alternativeBands.map { "n\($0)" }.joined(separator: ", "),
                            help: "NR bands overlap; the band reported by the modem is authoritative.")
                }
                if let duplex = info.duplex { InfoRow("Duplex", duplex.rawValue) }
                if info.channel >= 0 { InfoRow(channelName, "\(info.channel)") }
                if let dl = info.downlinkMHz { InfoRow("Downlink", Spectrum.formatFrequency(dl)) }
                if let ul = info.uplinkMHz, info.duplex != .tdd {
                    InfoRow("Uplink", Spectrum.formatFrequency(ul) + (info.uplinkChannel.map { " (ch \($0))" } ?? ""))
                }
            } else {
                Text("No channel number captured.").font(.caption).foregroundStyle(.secondary)
            }
            if let bw = cell.bandwidthMHz {
                InfoRow("Bandwidth", "\(Spectrum.trimmed(bw, decimals: 1)) MHz")
                if let sinr = cell.sinr?.mean {
                    InfoRow("Est. peak throughput",
                            "≈ \(Int(SignalQuality.estimatedThroughputMbps(sinr: sinr, bandwidthMHz: bw))) Mbit/s",
                            help: "Shannon-based estimate for 2×2 MIMO at the average SINR, before load. Real speeds are usually lower.")
                }
            }
        }
    }

    private var channelName: String {
        switch cell.family {
        case .lte: return "EARFCN"
        case .nr: return "NR-ARFCN"
        case .umts: return "UARFCN"
        default: return "ARFCN"
        }
    }

    // MARK: Signal

    private struct ChartPoint: Identifiable {
        let id: UUID
        let date: Date
        let value: Double
    }

    private func stats(_ metric: SignalMetric) -> MetricStats? {
        switch metric {
        case .rsrp: return cell.rsrp
        case .rsrq: return cell.rsrq
        case .sinr: return cell.sinr
        case .rssi: return cell.rssi
        }
    }

    @ViewBuilder
    private func signalSection(_ observations: [CellObservation]) -> some View {
        let present = SignalMetric.allCases.filter { stats($0) != nil }
        if !present.isEmpty {
            Section {
                ForEach(present, id: \.self) { metric in
                    if let stats = stats(metric) {
                        VStack(alignment: .leading, spacing: 6) {
                            SignalGaugeRow(metric: metric, value: stats.latest, family: cell.family)
                            if stats.count > 1 {
                                Text("avg \(Format.metric(metric, stats.mean)) · min \(Format.metric(metric, stats.min)) · max \(Format.metric(metric, stats.max))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                let series = observations.compactMap { o in o.rsrp.map { ChartPoint(id: o.id, date: o.timestamp, value: $0) } }
                if series.count > 1 {
                    Chart {
                        RuleMark(y: .value("Good", -80))
                            .foregroundStyle(.green.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        RuleMark(y: .value("Weak", -100))
                            .foregroundStyle(.red.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        ForEach(series) { point in
                            LineMark(x: .value("Time", point.date), y: .value("RSRP", point.value))
                                .foregroundStyle(.gray.opacity(0.6))
                            PointMark(x: .value("Time", point.date), y: .value("RSRP", point.value))
                                .foregroundStyle(SignalQuality.grade(.rsrp, point.value).color)
                        }
                    }
                    .chartYScale(domain: -140 ... -44)
                    .chartYAxisLabel("RSRP (dBm)")
                    .frame(height: 180)
                }
            } header: {
                Text("Signal")
            } footer: {
                Text(SignalMetric.rsrp.explanation + " " + SignalMetric.sinr.explanation)
            }
        }
    }

    // MARK: Location

    @ViewBuilder
    private func locationSection(_ observations: [CellObservation]) -> some View {
        let tower = model.towers.tower(for: cell.key)
        let points = observations.compactMap { o in
            o.location.map { MapSample(id: o.id, point: $0, grade: SignalQuality.overallGrade(for: o)) }
        }
        Section {
            if !points.isEmpty || tower != nil {
                Map(initialPosition: .automatic) {
                    ForEach(points) { p in
                        Annotation("", coordinate: p.point.coordinate) {
                            Circle().fill(p.grade?.color ?? .gray).frame(width: 9, height: 9)
                                .overlay(Circle().stroke(.white, lineWidth: 1))
                        }
                    }
                    if let estimate = cell.estimatedLocation {
                        Marker("Estimate", systemImage: "scope", coordinate: estimate.coordinate).tint(.blue)
                    }
                    if let tower {
                        Marker("OpenCellID", systemImage: "antenna.radiowaves.left.and.right", coordinate: tower.location.coordinate)
                            .tint(.purple)
                        if let range = tower.rangeMeters {
                            MapCircle(center: tower.location.coordinate, radius: range)
                                .foregroundStyle(.purple.opacity(0.08))
                                .stroke(.purple.opacity(0.4), lineWidth: 1)
                        }
                    }
                    UserAnnotation()
                }
                .frame(height: 240)
                .listRowInsets(EdgeInsets())
            }

            if let estimate = cell.estimatedLocation {
                InfoRow("Estimated position", Format.coordinate(estimate),
                        help: "Signal-weighted centre of your measurements. It lies towards the strongest readings; with few samples or samples from one side it is rough.")
            }
            if let me = model.location.currentPoint {
                if let tower {
                    distanceRow("Registered site", from: me, to: tower.location)
                } else if let estimate = cell.estimatedLocation, cell.observationCount > 1 {
                    distanceRow("Estimate", from: me, to: estimate)
                }
            }
            if let ta = model.observations(for: cell).last(where: { $0.timingAdvance != nil })?.timingAdvance,
               let range = Geodesy.distance(timingAdvance: ta, family: cell.family) {
                InfoRow("Timing-advance distance", "\(Format.distance(range.lowerBound)) – \(Format.distance(range.upperBound))",
                        help: "Round-trip timing puts the antenna within this radius.")
            }
            lookupRow(tower: tower)
        } header: {
            Text("Location")
        }
    }

    private func towerSummary(_ tower: TowerLocation) -> String {
        var text = "found"
        if let samples = tower.samples { text = "\(samples) samples" }
        if let range = tower.rangeMeters { text += ", range " + Format.distance(range) }
        return text
    }

    private func distanceRow(_ label: String, from me: GeoPoint, to target: GeoPoint) -> some View {
        let distance = Geodesy.distance(me, target)
        let bearing = Geodesy.bearing(from: me, to: target)
        return InfoRow("\(label) from you", "\(Format.distance(distance)) \(Geodesy.compassDirection(bearing)) (\(Int(bearing))°)")
    }

    @ViewBuilder
    private func lookupRow(tower: TowerLocation?) -> some View {
        let towers = model.towers
        if let tower {
            InfoRow("OpenCellID", towerSummary(tower))
        } else if towers.isNotFound(cell.key) {
            InfoRow("OpenCellID", "Not in database")
        }
        if let error = towers.errors[cell.key] {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        if towers.canLookUp(cell) {
            Button {
                Task { await towers.lookUp(cell) }
            } label: {
                HStack {
                    Label(tower == nil ? "Look up registered position" : "Refresh lookup", systemImage: "magnifyingglass")
                    if towers.inFlight.contains(cell.key) { Spacer(); ProgressView() }
                }
            }
            .disabled(!model.settings.hasOpenCellIDKey || towers.inFlight.contains(cell.key))
            if !model.settings.hasOpenCellIDKey {
                Text("Add a free OpenCellID API key in Settings to look up registered tower positions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("A database lookup needs MCC, MNC, TAC/LAC and the cell ID.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AnomalyRow: View {
    let anomaly: Anomaly

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: anomaly.severity.systemImage)
                .foregroundStyle(anomaly.severity.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(anomaly.title).font(.subheadline.weight(.semibold))
                Text(anomaly.detail).font(.caption).foregroundStyle(.secondary)
                Text(anomaly.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A located measurement for map rendering.
struct MapSample: Identifiable {
    let id: UUID
    let point: GeoPoint
    let grade: SignalGrade?
}
