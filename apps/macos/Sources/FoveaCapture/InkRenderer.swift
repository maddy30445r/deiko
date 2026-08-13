import Foundation
import FoveaGesture

// TEMPORARY STUB — Task 4 replaces this with the real ink drawing (stroke path
// overlaid on the crop, plus the numbered badge). Exists here only so Task 3's
// wiring in `Recorder.resolve` has something to call and the build stays green.
enum InkRenderer {
    static func ink(
        file: String, strokePath: [Point], cropRect: Frame, kind: StrokeKind, number: Int
    ) {}
}
