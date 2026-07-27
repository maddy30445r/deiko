import CoreGraphics
import Foundation
import Vision

// ─────────────────────────────────────────────────────────────────────────────
// OCR — the conditional half of the Tier 1 base
//
// Vision runs on-device: no API key, no network, no per-call cost. That is why
// it can be the universal fallback without touching the pricing model.
//
// It runs only when AX came back with no usable text. Where AX resolves, its
// strings are exact — OCR has to *decide* between `l`, `1` and `I`, and in a
// field name or identifier that goes into an executed plan, one wrong character
// is a wrong edit.
//
// Recognised text carries its rectangle, not just the string. Positions let the
// assembled context say "this text, at the point you indicated" instead of
// handing the model an unordered bag of words from a 460×220 box.
// ─────────────────────────────────────────────────────────────────────────────

enum OCR {

    /// Discard near-noise. Vision happily reports single stray glyphs from UI
    /// chrome at low confidence.
    static let minimumConfidence: Float = 0.3

    /// Recognise text in `image`, returning lines positioned in global screen
    /// coordinates. `rect` is where the image came from, in that same space.
    static func recognize(_ image: CGImage, in rect: Frame) -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Identifiers, paths and JSON keys are not dictionary words; language
        // correction "fixes" them into English and destroys exactly the strings
        // we care about.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]

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

    /// Vision reports normalised boxes with a BOTTOM-LEFT origin; everything
    /// else in this codebase is top-left. The `1 - maxY` is that flip — get it
    /// wrong and OCR text lands mirrored against the AX frames it should agree
    /// with, which looks like a subtle grounding bug rather than a unit error.
    private static func screenFrame(of boundingBox: CGRect, in rect: Frame) -> Frame {
        Frame(
            x: rect.x + boundingBox.minX * rect.width,
            y: rect.y + (1 - boundingBox.maxY) * rect.height,
            width: boundingBox.width * rect.width,
            height: boundingBox.height * rect.height
        )
    }

    /// Whether AX gave us enough that OCR would be redundant. This is the switch
    /// that keeps the 50-200ms Vision cost off the common path.
    static func isNeeded(for snapshot: AXSnapshot) -> Bool {
        guard snapshot.resolved else { return true }
        // Trimmed, matching `carriesMeaning` and `Capture.rect` — untrimmed,
        // a whitespace-only AX value (a padded cell, an indentation-only line)
        // counted as "AX has text" and suppressed OCR for a referent that then
        // reached the aligner with no text at all.
        let hasText = snapshot.elements.contains { el in
            [el.value, el.title, el.elementDescription, el.selectedText]
                .contains {
                    $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                }
        }
        return !hasText
    }
}
