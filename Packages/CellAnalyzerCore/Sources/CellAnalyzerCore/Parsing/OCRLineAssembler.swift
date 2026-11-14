import Foundation

/// A piece of recognized text with its bounding box in normalized coordinates
/// (0…1, origin top-left, y grows downward).
public struct OCRToken: Sendable, Hashable {
    public var text: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(text: String, x: Double, y: Double, width: Double, height: Double) {
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var midY: Double { y + height / 2 }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
}

/// Rebuilds table rows from OCR tokens. Field Test Mode renders "label ……… value" rows;
/// text recognizers return the label and the value as separate boxes, so they have to be
/// re-joined by vertical position. Large horizontal gaps become a tab, which the parser
/// treats as the label/value separator.
public enum OCRLineAssembler {
    public static func lines(from tokens: [OCRToken], columnGap: Double = 0.04) -> [String] {
        var rows: [[OCRToken]] = []
        for token in tokens.sorted(by: { $0.midY < $1.midY }) where !token.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if let index = rows.lastIndex(where: { belongs(token, to: $0) }) {
                rows[index].append(token)
            } else {
                rows.append([token])
            }
        }
        return rows
            .sorted { mid($0) < mid($1) }
            .map { row in
                let sorted = row.sorted { $0.x < $1.x }
                var line = ""
                var previous: OCRToken?
                for token in sorted {
                    if let previous {
                        line += (token.x - previous.maxX) > columnGap ? "\t" : " "
                    }
                    line += token.text.trimmingCharacters(in: .whitespaces)
                    previous = token
                }
                return line
            }
    }

    private static func mid(_ row: [OCRToken]) -> Double {
        row.map(\.midY).reduce(0, +) / Double(row.count)
    }

    /// A token joins a row when it overlaps vertically with the row by at least half of the smaller height.
    private static func belongs(_ token: OCRToken, to row: [OCRToken]) -> Bool {
        guard let top = row.map(\.y).min(), let bottom = row.map(\.maxY).max() else { return false }
        let rowHeight = bottom - top
        let overlap = min(bottom, token.maxY) - max(top, token.y)
        return overlap >= 0.5 * min(rowHeight, token.height)
    }
}
