import SwiftUI
import CellAnalyzerCore

// MARK: - Colors

extension SignalGrade {
    var color: Color {
        switch self {
        case .excellent: return .green
        case .good: return .mint
        case .fair: return .yellow
        case .poor: return .orange
        case .noSignal: return .red
        }
    }
}

extension NetworkGeneration {
    var color: Color {
        switch self {
        case .g5: return .purple
        case .g4: return .blue
        case .g3: return .teal
        case .g2: return .orange
        case .unknown: return .gray
        }
    }
}

extension AnomalySeverity {
    var color: Color {
        switch self {
        case .high: return .red
        case .medium: return .orange
        case .low: return .yellow
        case .info: return .gray
        }
    }

    var systemImage: String {
        switch self {
        case .high: return "exclamationmark.octagon.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .low: return "info.circle.fill"
        case .info: return "info.circle"
        }
    }
}

// MARK: - Formatting

enum Format {
    static func dB(_ value: Double?, unit: String) -> String {
        guard let value else { return "–" }
        let rounded = (value * 10).rounded() / 10
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return "\(text) \(unit)"
    }

    static func metric(_ metric: SignalMetric, _ value: Double?) -> String { dB(value, unit: metric.unit) }

    static func optional(_ value: Int?) -> String { value.map(String.init) ?? "–" }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "–"
    }

    static func distance(_ meters: Double) -> String {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = meters < 1000 ? 0 : 1
        return formatter.string(from: Measurement(value: meters, unit: UnitLength.meters))
    }

    static func coordinate(_ p: GeoPoint) -> String {
        String(format: "%.5f, %.5f", p.latitude, p.longitude)
    }
}

// MARK: - Badges & rows

struct RadioBadge: View {
    let radio: RadioTechnology
    var large = false

    var body: some View {
        Text(radio.displayName)
            .font(large ? .title3.weight(.bold) : .caption.weight(.semibold))
            .padding(.horizontal, large ? 12 : 7)
            .padding(.vertical, large ? 6 : 3)
            .background(radio.generation.color.opacity(0.18), in: Capsule())
            .foregroundStyle(radio.generation.color)
    }
}

struct GradeDot: View {
    let grade: SignalGrade?
    var body: some View {
        Circle()
            .fill(grade?.color ?? .gray.opacity(0.4))
            .frame(width: 10, height: 10)
    }
}

/// Four-bar indicator like the status bar, coloured by grade.
struct SignalBars: View {
    let grade: SignalGrade?
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(bar <= (grade?.bars ?? 0) ? (grade?.color ?? .gray) : Color.gray.opacity(0.25))
                    .frame(width: 4, height: CGFloat(4 + bar * 3))
            }
        }
        .accessibilityLabel(grade?.label ?? "No signal data")
    }
}

/// Labeled horizontal gauge for one signal metric.
struct SignalGaugeRow: View {
    let metric: SignalMetric
    let value: Double?
    var family: RadioFamily = .lte

    var body: some View {
        let grade = value.map { SignalQuality.grade(metric, $0, family: family) }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(metric.displayName).font(.subheadline.weight(.medium))
                Spacer()
                Text(Format.metric(metric, value)).font(.subheadline.monospacedDigit())
                if let grade {
                    Text(grade.label).font(.caption).foregroundStyle(grade.color)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.18))
                    Capsule()
                        .fill(grade?.color ?? .gray)
                        .frame(width: geo.size.width * (value.map { SignalQuality.normalized(metric, $0) } ?? 0))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var systemImage: String?
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(tint) }
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var help: String?

    init(_ label: String, _ value: String, help: String? = nil) {
        self.label = label
        self.value = value
        self.help = help
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(label) {
                Text(value).monospacedDigit().textSelection(.enabled)
            }
            if let help {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

// MARK: - Optional number fields

/// Text field bound to an optional integer; empty text means `nil`.
struct OptionalIntField: View {
    let title: String
    @Binding var value: Int?
    var allowHex = false
    @State private var text = ""

    var body: some View {
        LabeledContent(title) {
            TextField(allowHex ? "dec or 0x…" : "–", text: $text)
                .multilineTextAlignment(.trailing)
                .keyboardType(allowHex ? .asciiCapable : .numbersAndPunctuation)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .monospacedDigit()
                .onChange(of: text) { _, new in
                    let trimmed = new.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { value = nil; return }
                    if allowHex, trimmed.lowercased().hasPrefix("0x") {
                        if let v = Int(trimmed.dropFirst(2), radix: 16) { value = v }
                    } else if let v = Int(trimmed) {
                        value = v
                    }
                }
        }
        .onAppear { text = value.map(String.init) ?? "" }
    }
}

/// Text field bound to an optional double; accepts "," as decimal separator.
struct OptionalDoubleField: View {
    let title: String
    @Binding var value: Double?
    var unit: String?
    @State private var text = ""

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("–", text: $text)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
                    .monospacedDigit()
                    .onChange(of: text) { _, new in
                        let normalized = new.replacingOccurrences(of: ",", with: ".")
                            .replacingOccurrences(of: "\u{2212}", with: "-")
                            .trimmingCharacters(in: .whitespaces)
                        if normalized.isEmpty { value = nil } else if let v = Double(normalized) { value = v }
                    }
                if let unit { Text(unit).foregroundStyle(.secondary) }
            }
        }
        .onAppear {
            if let value {
                text = value == value.rounded() ? String(Int(value)) : String(value)
            } else {
                text = ""
            }
        }
    }
}
