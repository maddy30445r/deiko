import Foundation
import Testing
@testable import FoveaGesture

private func circle(r: Double, turns: Double = 1.0, cx: Double = 500, cy: Double = 500) -> [StrokePoint] {
    stride(from: 0.0, through: 360.0 * turns, by: 10.0).map {
        let a = $0 * .pi / 180
        return StrokePoint(x: cx + r * cos(a), y: cy + r * sin(a))
    }
}

@Suite struct StrokeClassifierTests {
    @Test func tinyWiggleIsAPoint() {
        let path = [StrokePoint(x: 100, y: 100), StrokePoint(x: 104, y: 102), StrokePoint(x: 101, y: 105)]
        #expect(StrokeClassifier.classify(path) == .point)
    }

    @Test func fullCircleIsALasso() {
        #expect(StrokeClassifier.classify(circle(r: 80)) == .lasso)
    }

    @Test func sloppyThreeQuarterCircleIsStillALasso() {
        #expect(StrokeClassifier.classify(circle(r: 80, turns: 0.75)) == .lasso)
    }

    @Test func straightSweepIsAConnector() {
        // 400pt left-to-right with a little hand jitter.
        let path = stride(from: 0.0, through: 400.0, by: 20.0).map {
            StrokePoint(x: 100 + $0, y: 300 + ($0.truncatingRemainder(dividingBy: 40) == 0 ? 3 : -3))
        }
        #expect(StrokeClassifier.classify(path) == .connector)
    }

    @Test func diagonalSweepIsAConnector() {
        let path = stride(from: 0.0, through: 300.0, by: 15.0).map {
            StrokePoint(x: 100 + $0, y: 100 + $0 * 0.6)
        }
        #expect(StrokeClassifier.classify(path) == .connector)
    }

    @Test func lShapedPathIsATrace() {
        // Down 200 then right 200 — far from linear, far from closed.
        let down = stride(from: 0.0, through: 200.0, by: 20.0).map { StrokePoint(x: 100, y: 100 + $0) }
        let right = stride(from: 20.0, through: 200.0, by: 20.0).map { StrokePoint(x: 100 + $0, y: 300) }
        #expect(StrokeClassifier.classify(down + right) == .trace)
    }

    @Test func denseZigzagIsEmphasis() {
        // Back-and-forth over a 120×40 box: path length far exceeds the diagonal.
        var path: [StrokePoint] = []
        for row in 0..<6 {
            let y = 200.0 + Double(row) * 8
            let xs = row % 2 == 0 ? stride(from: 0.0, through: 120.0, by: 15.0) : stride(from: 120.0, through: 0.0, by: -15.0)
            for x in xs { path.append(StrokePoint(x: 400 + x, y: y)) }
        }
        #expect(StrokeClassifier.classify(path) == .emphasis)
    }

    @Test func doubleCircleIsEmphasis() {
        // Circling the same thing twice is emphasis, not a lasso.
        #expect(StrokeClassifier.classify(circle(r: 60, turns: 2.0)) == .emphasis)
    }

    @Test func shortNudgeIsNotAConnector() {
        // A 40pt straight drag is too short to be a relation.
        let path = stride(from: 0.0, through: 40.0, by: 5.0).map { StrokePoint(x: 100 + $0, y: 500 + $0 * 0.3) }
        #expect(StrokeClassifier.classify(path) != .connector)
    }
}
