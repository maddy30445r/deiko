import Foundation

/// A stroke sample in top-left-origin global screen points. DeikoGesture has no
/// dependencies, so it owns this tiny type; callers map their own Point into it.
public struct StrokePoint: Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// What a modifier-held stroke meant. Classification only dresses the ink and
/// picks the verb — it never changes what is captured — so a misread mislabels
/// a verb rather than losing evidence.
public enum StrokeKind: String, Sendable, CaseIterable {
    case point, lasso, connector, trace, emphasis
}

public enum StrokeClassifier {
    /// A stroke whose bounding box is smaller than this is a tap, not a shape.
    public static let minMarkArea: Double = 400
    /// Chord shorter than this fraction of path length reads as closed → lasso.
    public static let closedChordFraction = 0.35
    /// Path length beyond this multiple of the bbox diagonal is back-and-forth
    /// scribbling → emphasis. A single drawn circle sits near π/√2 ≈ 2.2.
    public static let scribbleWindingFactor = 2.5
    /// Linear when every point deviates from the chord by less than
    /// max(floor, fraction × chord). The floor absorbs hand jitter.
    public static let linearDeviationFraction = 0.12
    public static let linearDeviationFloor: Double = 14
    /// A connector shorter than this is a nudge, not a relation.
    public static let minConnectorChord: Double = 60

    public static func classify(_ path: [StrokePoint]) -> StrokeKind {
        guard path.count >= 3, let first = path.first, let last = path.last else { return .point }

        let xs = path.map(\.x), ys = path.map(\.y)
        let w = (xs.max() ?? 0) - (xs.min() ?? 0)
        let h = (ys.max() ?? 0) - (ys.min() ?? 0)
        if w * h < minMarkArea { return .point }

        var length = 0.0
        for i in 1..<path.count {
            length += hypot(path[i].x - path[i - 1].x, path[i].y - path[i - 1].y)
        }
        let chord = hypot(last.x - first.x, last.y - first.y)
        let diagonal = hypot(w, h)

        // Winding first: a double-circled loop also has a tiny chord, and the
        // repetition is the signal — going around twice is emphasis.
        if length > scribbleWindingFactor * diagonal { return .emphasis }
        if chord < closedChordFraction * length { return .lasso }
        if chord >= minConnectorChord, maxChordDeviation(path, from: first, to: last)
            < max(linearDeviationFloor, linearDeviationFraction * chord) {
            return .connector
        }
        return .trace
    }

    /// Greatest perpendicular distance of any sample from the first→last chord.
    private static func maxChordDeviation(
        _ path: [StrokePoint], from a: StrokePoint, to b: StrokePoint
    ) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let chord = hypot(dx, dy)
        guard chord > 0 else { return 0 }
        var worst = 0.0
        for p in path {
            let d = abs(dy * (p.x - a.x) - dx * (p.y - a.y)) / chord
            if d > worst { worst = d }
        }
        return worst
    }
}
