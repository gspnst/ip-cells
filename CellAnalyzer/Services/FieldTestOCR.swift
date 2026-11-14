import Foundation
import ImageIO
import Vision
import CellAnalyzerCore

/// Runs on-device text recognition (Vision) on Field Test Mode screenshots and parses the result.
enum FieldTestOCR {
    struct Result {
        var lines: [String]
        var capture: FieldTestCapture
        /// Capture time from the image metadata, when present.
        var imageDate: Date?
    }

    enum OCRError: LocalizedError {
        case unreadableImage
        var errorDescription: String? { "The image could not be read." }
    }

    static func recognize(imageData: Data) async throws -> Result {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OCRError.unreadableImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        let date = captureDate(from: properties)

        let tokens = try await recognizeTokens(in: image, orientation: orientation)
        let lines = OCRLineAssembler.lines(from: tokens)
        return Result(lines: lines, capture: FieldTestParser.parse(lines: lines), imageDate: date)
    }

    private static func recognizeTokens(in image: CGImage, orientation: CGImagePropertyOrientation) async throws -> [OCRToken] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.recognitionLanguages = ["en-US"]
                request.minimumTextHeight = 0.008
                let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
                do {
                    try handler.perform([request])
                    let tokens = (request.results ?? []).compactMap { observation -> OCRToken? in
                        guard let text = observation.topCandidates(1).first?.string else { return nil }
                        let box = observation.boundingBox // normalized, origin bottom-left
                        return OCRToken(text: text, x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                    }
                    continuation.resume(returning: tokens)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Reads EXIF/TIFF/PNG timestamps. iOS screenshots usually carry `DateTimeOriginal`.
    private static func captureDate(from properties: [CFString: Any]) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let candidates: [String?] = [
            exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
            tiff?[kCGImagePropertyTIFFDateTime] as? String,
            png?[kCGImagePropertyPNGCreationTime] as? String,
        ]
        let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String
        for case let text? in candidates {
            if let date = parseExifDate(text, offset: offset) { return date }
        }
        return nil
    }

    static func parseExifDate(_ text: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset, let tz = TimeZone(iso8601Offset: offset) {
            formatter.timeZone = tz
        } else {
            formatter.timeZone = .current
        }
        for format in ["yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return ISO8601DateFormatter().date(from: text)
    }
}

private extension TimeZone {
    /// Parses "+02:00" / "-0500".
    init?(iso8601Offset: String) {
        let sign: Int = iso8601Offset.hasPrefix("-") ? -1 : 1
        let digits = iso8601Offset.filter(\.isNumber)
        guard digits.count == 4, let h = Int(digits.prefix(2)), let m = Int(digits.suffix(2)) else { return nil }
        self.init(secondsFromGMT: sign * (h * 3600 + m * 60))
    }
}
