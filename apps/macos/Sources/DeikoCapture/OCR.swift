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

    // There used to be an `isNeeded(for:)` here — a predicate that skipped OCR
    // when accessibility had already produced text. It is gone, and every
    // referent is now read off its pixels.
    //
    // It was deleted rather than fixed because it failed twice, the same way,
    // for different reasons. First a git-blame annotation ("You, 6 hours ago")
    // counted as "AX has text" and suppressed OCR for an entire circled region
    // of code — which is why regions were exempted from it. Then, in session
    // 20260728-230442, `"Caret Right Icon"` did the same for three point
    // referents and a tab labelled `"0"` for a fourth; all four reached the
    // aligner carrying nothing about what the user meant. Any predicate of this
    // shape has to decide whether a string is meaningful, and it will keep
    // getting that wrong on content it has never seen.
    //
    // What it bought was never worth defending: each referent resolves inside
    // its own detached `Task`, so the ~163ms measured cost overlaps other work
    // and nothing waits on it except the end of the session. It was optimising
    // background time nobody was blocked on, and paying for it in referents.
}
