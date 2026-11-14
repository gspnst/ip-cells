// Prints the text visible in each screenshot, row by row (top to bottom), using Vision.
// Used in CI to review UI-test screenshots from the job log.
// Usage: swift scripts/ocr-screenshots.swift screenshots/*.png
import AppKit
import Foundation
import Vision

for path in CommandLine.arguments.dropFirst().sorted() {
    guard let image = NSImage(contentsOfFile: path),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("===== \(path): unreadable")
        continue
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: cgImage).perform([request])
    let observations = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }

    var rows: [[VNRecognizedTextObservation]] = []
    for observation in observations {
        if let anchor = rows.last?.first, abs(anchor.boundingBox.midY - observation.boundingBox.midY) < 0.007 {
            rows[rows.count - 1].append(observation)
        } else {
            rows.append([observation])
        }
    }
    print("===== \(URL(fileURLWithPath: path).lastPathComponent) (\(cgImage.width)x\(cgImage.height))")
    for row in rows {
        let text = row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            .compactMap { $0.topCandidates(1).first?.string }
        print("  " + text.joined(separator: "  |  "))
    }
}
