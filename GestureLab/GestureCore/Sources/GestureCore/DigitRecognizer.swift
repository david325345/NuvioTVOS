import Foundation

/// A drawn digit someone saved as their own sample.
public struct DigitTemplate: Codable, Equatable, Sendable {
    public let digit: Int
    public let strokes: [[PadPoint]]

    public init(digit: Int, strokes: [[PadPoint]]) {
        self.digit = digit
        self.strokes = strokes
    }
}

public struct DigitMatch: Equatable, Sendable {
    public let digit: Int
    /// 1 = identical shape, 0 = nothing alike.
    public let score: Double
    /// The next most likely digit, to show what it was confused with.
    public let runnerUp: Int?
    public let runnerUpScore: Double?
}

/// Recognizes digits drawn on the touch surface with the $P point-cloud
/// recognizer (Vatavu, Anthony, Wobbrock 2012): strokes are resampled to a
/// fixed number of points, scaled and centred, then matched point to point.
/// Stroke order and direction don't matter, rotation does (6 is not 9).
public struct DigitRecognizer: Sendable {
    public static let pointCount = 32
    /// Average distance (in the unit box) at which the score reaches 0.
    static let zeroScoreDistance = 0.30

    private struct Entry: Sendable {
        let digit: Int
        let cloud: [PadPoint]
    }

    private let entries: [Entry]

    public init(userTemplates: [DigitTemplate] = [], includeDefaults: Bool = true) {
        var all = includeDefaults ? Self.defaultTemplates : []
        all += userTemplates
        entries = all.compactMap { template in
            Self.normalize(template.strokes).map { Entry(digit: template.digit, cloud: $0) }
        }
    }

    public func recognize(_ strokes: [[PadPoint]]) -> DigitMatch? {
        guard let cloud = Self.normalize(strokes), !entries.isEmpty else { return nil }
        var bestPerDigit: [Int: Double] = [:]
        for entry in entries {
            let distance = Self.greedyCloudMatch(cloud, entry.cloud)
            bestPerDigit[entry.digit] = min(bestPerDigit[entry.digit] ?? .infinity, distance)
        }
        let ranked = bestPerDigit.sorted { $0.value < $1.value }
        guard let best = ranked.first else { return nil }
        let second = ranked.count > 1 ? ranked[1] : nil
        return DigitMatch(
            digit: best.key,
            score: Self.score(forDistance: best.value),
            runnerUp: second?.key,
            runnerUpScore: second.map { Self.score(forDistance: $0.value) }
        )
    }

    static func score(forDistance distance: Double) -> Double {
        // The greedy match weights points from 1 down to 1/n, about n/2 in total.
        let weightSum = Double(pointCount + 1) / 2
        let average = distance / weightSum
        return max(0, min(1, 1 - average / zeroScoreDistance))
    }

    // MARK: - $P

    private struct StrokePoint {
        var point: PadPoint
        var stroke: Int
    }

    /// Resampled to `pointCount` points, scaled to the unit box (aspect kept),
    /// centred on the centroid. Nil for a dot or an empty drawing.
    static func normalize(_ strokes: [[PadPoint]]) -> [PadPoint]? {
        var points: [StrokePoint] = []
        for (index, stroke) in strokes.enumerated() {
            points += stroke.map { StrokePoint(point: $0, stroke: index) }
        }
        guard points.count >= 2 else { return nil }
        let xs = points.map(\.point.x), ys = points.map(\.point.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let size = max(maxX - minX, maxY - minY)
        guard size > 0.0001 else { return nil }

        var resampled = resample(points, count: pointCount)
        for index in resampled.indices {
            resampled[index].x = (resampled[index].x - minX) / size
            resampled[index].y = (resampled[index].y - minY) / size
        }
        let cx = resampled.map(\.x).reduce(0, +) / Double(resampled.count)
        let cy = resampled.map(\.y).reduce(0, +) / Double(resampled.count)
        return resampled.map { PadPoint(x: $0.x - cx, y: $0.y - cy) }
    }

    private static func resample(_ input: [StrokePoint], count: Int) -> [PadPoint] {
        var points = input
        var length = 0.0
        for i in 1..<points.count where points[i].stroke == points[i - 1].stroke {
            length += points[i - 1].point.distance(to: points[i].point)
        }
        guard length > 0 else { return Array(repeating: points[0].point, count: count) }
        let interval = length / Double(count - 1)
        var accumulated = 0.0
        var result = [points[0].point]
        var i = 1
        while i < points.count {
            if points[i].stroke == points[i - 1].stroke {
                let a = points[i - 1].point, b = points[i].point
                let d = a.distance(to: b)
                if accumulated + d >= interval, d > 0 {
                    let t = (interval - accumulated) / d
                    let q = PadPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
                    result.append(q)
                    points.insert(StrokePoint(point: q, stroke: points[i].stroke), at: i)
                    accumulated = 0
                } else {
                    accumulated += d
                }
            }
            i += 1
        }
        while result.count < count, let last = points.last?.point { result.append(last) }
        return Array(result.prefix(count))
    }

    static func greedyCloudMatch(_ a: [PadPoint], _ b: [PadPoint]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return .infinity }
        let step = max(1, Int(pow(Double(n), 0.5)))
        var best = Double.infinity
        var start = 0
        while start < n {
            best = min(best, cloudDistance(a, b, start: start, n: n), cloudDistance(b, a, start: start, n: n))
            start += step
        }
        return best
    }

    private static func cloudDistance(_ a: [PadPoint], _ b: [PadPoint], start: Int, n: Int) -> Double {
        var matched = Array(repeating: false, count: n)
        var sum = 0.0
        var i = start
        repeat {
            var nearest = Double.infinity
            var index = 0
            for j in 0..<n where !matched[j] {
                let d = a[i].distance(to: b[j])
                if d < nearest {
                    nearest = d
                    index = j
                }
            }
            matched[index] = true
            let weight = 1 - Double((i - start + n) % n) / Double(n)
            sum += weight * nearest
            i = (i + 1) % n
        } while i != start
        return sum
    }

    // MARK: - Built-in shapes

    /// One or two ways of writing each digit, so it works before any samples
    /// are saved. Drawn on a 0…1 box with y pointing down, like on paper.
    public static let defaultTemplates: [DigitTemplate] = {
        func arc(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double,
                 from start: Double, to end: Double, steps: Int = 16) -> [(Double, Double)] {
            (0...steps).map { step in
                let degrees = start + (end - start) * Double(step) / Double(steps)
                let radians = degrees * .pi / 180
                return (cx + rx * cos(radians), cy + ry * sin(radians))
            }
        }
        func template(_ digit: Int, _ strokes: [[(Double, Double)]]) -> DigitTemplate {
            DigitTemplate(digit: digit, strokes: strokes.map { stroke in
                stroke.map { PadPoint(x: $0.0 * 2 - 1, y: 1 - $0.1 * 2) }
            })
        }
        return [
            template(0, [arc(0.5, 0.5, 0.32, 0.48, from: -90, to: -450, steps: 24)]),
            template(1, [[(0.5, 0.0), (0.5, 1.0)]]),
            template(1, [[(0.3, 0.2), (0.55, 0.0), (0.55, 1.0)]]),
            template(2, [arc(0.5, 0.3, 0.32, 0.28, from: 200, to: 380) + [(0.15, 1.0), (0.85, 1.0)]]),
            template(3, [arc(0.5, 0.27, 0.30, 0.25, from: 210, to: 450)
                         + arc(0.5, 0.75, 0.32, 0.25, from: 270, to: 510)]),
            template(4, [[(0.65, 1.0), (0.65, 0.0), (0.1, 0.65), (0.9, 0.65)]]),
            template(4, [[(0.35, 0.0), (0.15, 0.6), (0.8, 0.6)], [(0.65, 0.3), (0.65, 1.0)]]),
            template(5, [[(0.8, 0.02), (0.3, 0.02), (0.25, 0.45)]
                         + arc(0.5, 0.7, 0.30, 0.28, from: 230, to: 500)]),
            template(6, [[(0.75, 0.0), (0.5, 0.15), (0.3, 0.4), (0.22, 0.6)]
                         + arc(0.5, 0.72, 0.28, 0.27, from: 180, to: -180)]),
            template(7, [[(0.15, 0.02), (0.85, 0.02), (0.4, 1.0)]]),
            template(8, [arc(0.5, 0.27, 0.26, 0.25, from: -30, to: -270)
                         + arc(0.5, 0.74, 0.30, 0.26, from: 270, to: 630)
                         + arc(0.5, 0.27, 0.26, 0.25, from: 90, to: -30, steps: 8)]),
            template(9, [arc(0.5, 0.28, 0.28, 0.26, from: 0, to: -360) + [(0.78, 0.28), (0.75, 1.0)]]),
        ]
    }()
}
