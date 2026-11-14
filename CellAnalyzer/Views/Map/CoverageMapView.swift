import SwiftUI
import MapKit
import CellAnalyzerCore

/// All located measurements coloured by signal grade, plus estimated / registered cell sites.
struct CoverageMapView: View {
    @Environment(AppModel.self) private var model
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var filter: Filter = .all
    @State private var colorBy: ColorBy = .signal
    @State private var showSites = true
    @State private var selectedCell: CellKey?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", nr = "5G", lte = "LTE", legacy = "2G/3G"
        var id: String { rawValue }

        func matches(_ radio: RadioTechnology) -> Bool {
            switch self {
            case .all: return true
            case .nr: return radio.family == .nr
            case .lte: return radio.family == .lte
            case .legacy: return radio.generation <= .g3 && radio != .unknown
            }
        }
    }

    enum ColorBy: String, CaseIterable, Identifiable {
        case signal = "Signal", technology = "Technology"
        var id: String { rawValue }
    }

    /// Rendering thousands of annotations is slow; show the most recent ones.
    private let maxPoints = 1500

    var body: some View {
        let samples = mapSamples
        let sites = showSites ? siteMarkers : []
        Map(position: $position, selection: $selectedCell) {
            ForEach(samples) { sample in
                Annotation("", coordinate: sample.coordinate, anchor: .center) {
                    Circle()
                        .fill(sample.color)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 0.5))
                }
            }
            ForEach(sites) { site in
                Marker(site.title, systemImage: site.isRegistered ? "antenna.radiowaves.left.and.right" : "scope",
                       coordinate: site.coordinate)
                    .tint(site.isRegistered ? .purple : .blue)
                    .tag(site.key)
            }
            UserAnnotation()
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .safeAreaInset(edge: .bottom) { controls }
        .navigationTitle("Coverage map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $selectedCell) { key in
            NavigationStack {
                CellDetailView(cellKey: key)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { selectedCell = nil }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .overlay {
            if samples.isEmpty && sites.isEmpty {
                ContentUnavailableView("Nothing to map yet", systemImage: "map",
                                       description: Text("Start recording on the Live tab or import Field Test screenshots while location access is allowed."))
                    .background(.regularMaterial)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Technology", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Picker("Colour", selection: $colorBy) {
                    ForEach(ColorBy.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Sites", isOn: $showSites).toggleStyle(.button)
            }
            legend
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    @ViewBuilder private var legend: some View {
        HStack(spacing: 10) {
            switch colorBy {
            case .signal:
                ForEach(SignalGrade.allCases.reversed(), id: \.self) { grade in
                    legendItem(grade.label, grade.color)
                }
                legendItem("No signal data", .gray)
            case .technology:
                ForEach([NetworkGeneration.g5, .g4, .g3, .g2], id: \.self) { generation in
                    legendItem(generation.displayName, generation.color)
                }
            }
        }
        .font(.caption2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendItem(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).lineLimit(1)
        }
    }

    // MARK: Data

    private struct Sample: Identifiable {
        let id: UUID
        let coordinate: CLLocationCoordinate2D
        let color: Color
    }

    private struct Site: Identifiable {
        var id: String
        var key: CellKey
        var title: String
        var coordinate: CLLocationCoordinate2D
        var isRegistered: Bool
    }

    private var mapSamples: [Sample] {
        let located = model.store.observations.filter { $0.location?.isValid == true && filter.matches($0.radio) }
        return located.suffix(maxPoints).map { o in
            let color: Color
            switch colorBy {
            case .signal: color = SignalQuality.overallGrade(for: o)?.color ?? .gray
            case .technology: color = o.radio.generation.color
            }
            return Sample(id: o.id, coordinate: o.location!.coordinate, color: color)
        }
    }

    private var siteMarkers: [Site] {
        model.cells.filter { filter.matches($0.radio) }.compactMap { cell in
            let title = cell.title(gnbIdBits: model.settings.gnbIdBits)
            if let tower = model.towers.tower(for: cell.key) {
                return Site(id: "r-\(cell.key)", key: cell.key, title: title,
                            coordinate: tower.location.coordinate, isRegistered: true)
            }
            if let estimate = cell.estimatedLocation, cell.observationCount >= 2 {
                return Site(id: "e-\(cell.key)", key: cell.key, title: title,
                            coordinate: estimate.coordinate, isRegistered: false)
            }
            return nil
        }
    }
}
