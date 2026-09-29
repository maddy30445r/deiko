import CoreGraphics
import Foundation
import Vision

/// On-device text recognition (Vision): no key, no network. It runs only when accessibility returned
/// no usable text, since AX strings are exact where OCR must choose between `l`, `1` and `I`. Lines keep
/// their rectangles so the assembled context can say "this text, at the point you indicated".
enum OCR {

    /// Discard near-noise: Vision reports stray glyphs from UI chrome at low confidence.
    static let minimumConfidence: Float = 0.3

    /// The user's languages first, English last so it is never dropped. Matched by language and
    /// script, not by string: Vision names `en-US`, `zh-Hans`; macOS reports `en-IN`, `zh-Hans-CN`.
    /// `zh-Hant-TW` resolves to `zh-Hant`.
    private static let recognitionLanguages: [String] = {
        let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? ["en-US"]
        var out: [String] = []
        for tag in Locale.preferredLanguages {
            let want = Locale.Language(identifier: tag)
            let match = supported.first { $0 == tag }
                ?? supported.first {
                    let has = Locale.Language(identifier: $0)
                    return has.languageCode == want.languageCode && has.script == want.script
                }
                ?? supported.first { Locale.Language(identifier: $0).languageCode == want.languageCode }
            if let match, !out.contains(match) { out.append(match) }
        }
        // Identifiers, paths and JSON keys are Latin whatever the UI language.
        if !out.contains("en-US") { out.append("en-US") }
        return out
    }()

    /// Recognise text in `image`, returning lines positioned in global screen coordinates.
    /// `rect` is where the image came from, in that same space.
    static func recognize(_ image: CGImage, in rect: Frame) -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Identifiers, paths and JSON keys are not dictionary words; language correction
        // "fixes" them into English.
        request.usesLanguageCorrection = false
        // Vision reads only the scripts of the languages it is given: pass the Mac's languages
        // (English always kept, for identifiers) and let it pick the script per line.
        request.recognitionLanguages = recognitionLanguages
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let observations = request.results else { return [] }

        return observations.compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= minimumConfidence else { return nil }

            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            return OCRLine(
                text: text,
                confidence: Double(candidate.confidence),
                frame: screenFrame(of: observation.boundingBox, in: rect)
            )
        }
        .sorted { Frame.readingOrder($0.frame, $1.frame) }
    }

    /// Vision reports normalised boxes with a bottom-left origin; the rest of this codebase is
    /// top-left. The `1 - maxY` is that flip; without it OCR text lands mirrored against AX frames.
    private static func screenFrame(of boundingBox: CGRect, in rect: Frame) -> Frame {
        Frame(
            x: rect.x + boundingBox.minX * rect.width,
            y: rect.y + (1 - boundingBox.maxY) * rect.height,
            width: boundingBox.width * rect.width,
            height: boundingBox.height * rect.height
        )
    }
}
