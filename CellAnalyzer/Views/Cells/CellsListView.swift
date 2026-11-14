import SwiftUI
import CellAnalyzerCore

struct CellsListView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var familyFilter: RadioFamily?
    @State private var sort: Sort = .recent

    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Recently seen", strongest = "Strongest", samples = "Most samples"
        var id: String { rawValue }
    }

    var body: some View {
        let cells = filtered
        List {
            if model.cells.isEmpty {
                ContentUnavailableView {
                    Label("No cells yet", systemImage: "cellularbars")
                } description: {
                    Text("Import Field Test screenshots or add a measurement manually. Cells appear here with decoded IDs and frequencies.")
                }
            } else {
                ForEach(groupedFamilies(cells), id: \.self) { family in
                    Section(family.displayName) {
                        ForEach(cells.filter { $0.family == family }) { cell in
                            NavigationLink(value: cell.key) {
                                CellRow(cell: cell, gnbIdBits: model.settings.gnbIdBits)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Cells")
        .navigationDestination(for: CellKey.self) { key in
            CellDetailView(cellKey: key)
        }
        .searchable(text: $search, prompt: "ID, PCI, band, operator")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Technology", selection: $familyFilter) {
                        Text("All").tag(RadioFamily?.none)
                        ForEach([RadioFamily.nr, .lte, .umts, .gsm], id: \.self) { family in
                            Text(family.displayName).tag(RadioFamily?.some(family))
                        }
                    }
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }

    private var filtered: [CellAggregate] {
        var cells = model.cells
        if let familyFilter { cells = cells.filter { $0.family == familyFilter } }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            let bits = model.settings.gnbIdBits
            cells = cells.filter { searchText(for: $0, gnbIdBits: bits).contains(query) }
        }
        switch sort {
        case .recent: return cells.sorted { $0.lastSeen > $1.lastSeen }
        case .strongest: return cells.sorted { ($0.rsrp?.mean ?? -999) > ($1.rsrp?.mean ?? -999) }
        case .samples: return cells.sorted { $0.observationCount > $1.observationCount }
        }
    }

    private func searchText(for cell: CellAggregate, gnbIdBits: Int) -> String {
        var parts: [String] = [cell.title(gnbIdBits: gnbIdBits), cell.operatorDescription]
        if let band = cell.bandLabel { parts.append(band) }
        if let pci = cell.pci { parts.append("pci \(pci)") }
        if let cellId = cell.cellId { parts.append(String(cellId)) }
        if let channel = cell.channel { parts.append(String(channel)) }
        if let area = cell.areaCode { parts.append(String(area)) }
        return parts.joined(separator: " ").lowercased()
    }

    private func groupedFamilies(_ cells: [CellAggregate]) -> [RadioFamily] {
        Array(Set(cells.map(\.family))).sorted()
    }
}

struct CellRow: View {
    let cell: CellAggregate
    let gnbIdBits: Int

    var body: some View {
        HStack(spacing: 12) {
            GradeDot(grade: cell.overallGrade)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(cell.title(gnbIdBits: gnbIdBits)).font(.body.weight(.medium))
                    if let band = cell.bandLabel {
                        Text(band).font(.caption.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(cell.radio.generation.color.opacity(0.15), in: Capsule())
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if let rsrp = cell.rsrp {
                    Text(Format.dB(rsrp.mean, unit: "dBm")).font(.subheadline.monospacedDigit())
                }
                Text("\(cell.observationCount)×").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        var parts = [cell.operatorDescription]
        if let pci = cell.pci { parts.append("PCI \(pci)") }
        if let area = cell.areaCode { parts.append((cell.family == .lte || cell.family == .nr ? "TAC " : "LAC ") + String(area)) }
        return parts.joined(separator: " · ")
    }
}
