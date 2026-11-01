import Foundation

/// How an add-on subtitle's times move onto the video: `time * scale + offset`, in seconds.
/// A scale other than 1 corrects a subtitle made for another frame rate (25 against 23.976).
struct SubtitleSyncMapping: Codable, Equatable, Sendable {
    var scale: Double
    var offset: Double

    static let identity = SubtitleSyncMapping(scale: 1, offset: 0)

    func callAsFunction(_ time: Double) -> Double { time * scale + offset }

    /// The largest move this mapping makes to a time in `span`.
    func largestShift(over span: ClosedRange<Double>) -> Double {
        max(abs(self(span.lowerBound) - span.lowerBound), abs(self(span.upperBound) - span.upperBound))
    }

    /// How far apart two mappings put a time in `span` at most.
    func distance(to other: SubtitleSyncMapping, over span: ClosedRange<Double>) -> Double {
        max(abs(self(span.lowerBound) - other(span.lowerBound)), abs(self(span.upperBound) - other(span.upperBound)))
    }
}

/// How well a mapping puts the subtitle's lines onto the reference.
struct SubtitleSyncFit: Equatable, Sendable {
    var mapping: SubtitleSyncMapping
    /// Share of lines that start within half a second of a reference line, or mostly overlap one.
    var coverage: Double
    /// Lines that start within half a second of a reference line.
    var startMatches: Int
    /// The longest run of lines next to nothing in the reference.
    var longestMiss: Int
    /// Median distance between matched starts after the mapping, in seconds.
    var medianError: Double
    var lineCount: Int
}

enum SubtitleSyncVerdict: Equatable, Sendable {
    case confident
    /// Too few lines (in the subtitle or the reference) to judge.
    case tooFewLines
    /// No mapping puts enough lines on the reference.
    case noMatch
    /// Two different mappings fit about as well: no telling which is right.
    case ambiguous
}

struct SubtitleSyncAlignment: Equatable, Sendable {
    var fit: SubtitleSyncFit?
    var verdict: SubtitleSyncVerdict
}

/// Finds the mapping that lines an add-on subtitle up with a reference timeline (the subtitles
/// embedded in the video), from line timing only, so the two may be in different languages.
///
/// Every line start votes for the offsets that would put it on a reference start; the strongest
/// offsets of each frame rate ratio are then scored on all lines and refined to the median error.
/// A mapping is used only when most lines land on the reference and no other mapping comes close.
enum SubtitleSyncAligner {
    /// 1 first: it wins a tie. Then the PAL speed-up both ways, 24 against 23.976, 25 against 24.
    static let scales: [Double] = [1, 25 / 23.976, 23.976 / 25, 24 / 23.976, 23.976 / 24, 25 / 24, 24 / 25]
    static let maxOffset: Double = 180
    static let binWidth: Double = 0.1
    static let smoothingBins = 3
    static let peaksPerScale = 3
    static let peakSeparation: Double = 1.5
    static let startTolerance: Double = 0.5
    static let minLines = 20
    static let minCoverage: Double = 0.8
    static let minStartShare: Double = 0.5
    static let maxMissRun = 12
    /// A different mapping with this share of the best one's matched starts makes the result
    /// ambiguous. Starts, not overlap: a mapping a second off still overlaps most lines.
    static let rivalShare: Double = 0.8
    /// Mappings closer than this everywhere count as the same answer.
    static let distinctMappings: Double = 1.0

    static func align(target: [SubtitleTimingCue], reference: [SubtitleTimingCue]) -> SubtitleSyncAlignment {
        let lines = target.filter(\.isDialogue).sorted { $0.start < $1.start }
        let referenceCues = reference.sorted { $0.start < $1.start }
        guard lines.count >= minLines, referenceCues.count >= minLines else {
            return SubtitleSyncAlignment(fit: nil, verdict: .tooFewLines)
        }
        let starts = referenceCues.map(\.start)
        let intervals = mergedIntervals(referenceCues)
        let span = lines[0].start...max(lines[lines.count - 1].end, lines[0].start + 1)

        var fits: [SubtitleSyncFit] = []
        for scale in scales {
            for offset in votedOffsets(lines: lines, referenceStarts: starts, scale: scale) {
                var fit = evaluate(lines: lines, referenceStarts: starts, intervals: intervals,
                                   mapping: SubtitleSyncMapping(scale: scale, offset: offset))
                for _ in 0..<2 where fit.startMatches > 0 && abs(fit.medianError) > 0.001 {
                    let refined = SubtitleSyncMapping(scale: scale, offset: fit.mapping.offset + fit.medianError)
                    let next = evaluate(lines: lines, referenceStarts: starts, intervals: intervals, mapping: refined)
                    guard next.coverage >= fit.coverage - 0.001 else { break }
                    fit = next
                }
                fits.append(fit)
            }
        }
        guard var best = fits.max(by: { better($1, than: $0) }) else {
            return SubtitleSyncAlignment(fit: nil, verdict: .noMatch)
        }
        // A frame rate change only when it clearly fits better than none.
        if best.mapping.scale != 1,
           let plain = fits.filter({ $0.mapping.scale == 1 }).max(by: { better($1, than: $0) }),
           Double(plain.startMatches) >= Double(best.startMatches) - 0.02 * Double(lines.count) {
            best = plain
        }
        let enoughStarts = Double(best.startMatches) >= max(Double(minLines), minStartShare * Double(lines.count))
        guard best.coverage >= minCoverage, enoughStarts, best.longestMiss <= maxMissRun else {
            return SubtitleSyncAlignment(fit: best, verdict: .noMatch)
        }
        let rival = fits.contains { fit in
            fit.mapping.distance(to: best.mapping, over: span) > distinctMappings
                && Double(fit.startMatches) >= Double(best.startMatches) * rivalShare
        }
        return SubtitleSyncAlignment(fit: best, verdict: rival ? .ambiguous : .confident)
    }

    /// Matched starts weigh most (they pin the timing down); overlap counts lines a translation
    /// split or merged differently.
    static func score(_ fit: SubtitleSyncFit) -> Double {
        0.7 * Double(fit.startMatches) / Double(max(fit.lineCount, 1)) + 0.3 * fit.coverage
    }

    static func better(_ lhs: SubtitleSyncFit, than rhs: SubtitleSyncFit) -> Bool {
        let left = score(lhs)
        let right = score(rhs)
        if abs(left - right) > 0.0001 { return left > right }
        return abs(lhs.medianError) < abs(rhs.medianError)
    }

    /// The offsets most line starts vote for at `scale`, strongest first.
    static func votedOffsets(lines: [SubtitleTimingCue], referenceStarts starts: [Double], scale: Double) -> [Double] {
        let binCount = Int((2 * maxOffset / binWidth).rounded()) + 1
        var votes = [Int](repeating: 0, count: binCount)
        for line in lines {
            let scaled = line.start * scale
            var index = lowerBound(starts, scaled - maxOffset)
            while index < starts.count, starts[index] <= scaled + maxOffset {
                let bin = Int(((starts[index] - scaled + maxOffset) / binWidth).rounded())
                if bin >= 0, bin < binCount { votes[bin] += 1 }
                index += 1
            }
        }
        var smoothed = [Int](repeating: 0, count: binCount)
        var running = 0
        for index in 0..<(binCount + smoothingBins) {
            if index < binCount { running += votes[index] }
            if index - 2 * smoothingBins - 1 >= 0 { running -= votes[index - 2 * smoothingBins - 1] }
            let center = index - smoothingBins
            if center >= 0, center < binCount { smoothed[center] = running }
        }
        var offsets: [Double] = []
        let suppression = Int((peakSeparation / binWidth).rounded())
        for _ in 0..<peaksPerScale {
            guard let peak = smoothed.enumerated().max(by: { $0.element < $1.element }), peak.element > 0 else { break }
            let bin = peak.offset
            offsets.append(Double(bin) * binWidth - maxOffset)
            for index in max(0, bin - suppression)...min(binCount - 1, bin + suppression) { smoothed[index] = 0 }
        }
        return offsets
    }

    static func evaluate(
        lines: [SubtitleTimingCue],
        referenceStarts starts: [Double],
        intervals: [ClosedRange<Double>],
        mapping: SubtitleSyncMapping
    ) -> SubtitleSyncFit {
        var covered = 0
        var startMatches = 0
        var run = 0
        var longest = 0
        var errors: [Double] = []
        for line in lines {
            let start = mapping(line.start)
            let end = max(mapping(line.end), start + 0.01)
            let error = nearest(starts, to: start).map { $0 - start }
            let startHit = error.map { abs($0) <= startTolerance } ?? false
            if startHit, let error {
                startMatches += 1
                errors.append(error)
            }
            let hit = startHit || overlap(intervals, start...end) >= 0.5 * (end - start)
            if hit {
                covered += 1
                run = 0
            } else {
                run += 1
                longest = max(longest, run)
            }
        }
        errors.sort()
        let median = errors.isEmpty ? 0 : errors[errors.count / 2]
        return SubtitleSyncFit(
            mapping: mapping,
            coverage: Double(covered) / Double(lines.count),
            startMatches: startMatches,
            longestMiss: longest,
            medianError: median,
            lineCount: lines.count)
    }

    static func mergedIntervals(_ cues: [SubtitleTimingCue]) -> [ClosedRange<Double>] {
        var merged: [ClosedRange<Double>] = []
        for cue in cues.sorted(by: { $0.start < $1.start }) where cue.end > cue.start {
            if let last = merged.last, cue.start <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, cue.end)
            } else {
                merged.append(cue.start...cue.end)
            }
        }
        return merged
    }

    static func overlap(_ intervals: [ClosedRange<Double>], _ range: ClosedRange<Double>) -> Double {
        var index = max(0, lowerBoundUpper(intervals, range.lowerBound))
        var total = 0.0
        while index < intervals.count, intervals[index].lowerBound < range.upperBound {
            let low = max(intervals[index].lowerBound, range.lowerBound)
            let high = min(intervals[index].upperBound, range.upperBound)
            if high > low { total += high - low }
            index += 1
        }
        return total
    }

    static func nearest(_ sorted: [Double], to value: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = lowerBound(sorted, value)
        if index == 0 { return sorted[0] }
        if index == sorted.count { return sorted[sorted.count - 1] }
        return value - sorted[index - 1] <= sorted[index] - value ? sorted[index - 1] : sorted[index]
    }

    /// First index whose value is not below `value`.
    static func lowerBound(_ sorted: [Double], _ value: Double) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// First interval that ends at or after `value`.
    private static func lowerBoundUpper(_ intervals: [ClosedRange<Double>], _ value: Double) -> Int {
        var low = 0
        var high = intervals.count
        while low < high {
            let mid = (low + high) / 2
            if intervals[mid].upperBound < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// The video's own subtitle timeline to line an add-on subtitle up with: which embedded tracks
/// to try, and their lines.
enum SubtitleSyncReference {
    static let minEvents = 8
    static let minSpan: Double = 30
    /// A text frame without a length in the index lasts until the next one, at most this long.
    static let estimatedTextDuration: Double = 4
    static let maxDuration: Double = 20
    /// PGS shows a picture and clears it: a pair this far apart is one line.
    static let pgsLineRange: ClosedRange<Double> = 0.3...15
    /// A text track with this many times the events of the leanest one is signs or karaoke.
    static let crowdedTrackFactor: Double = 3
    static let maxCandidates = 3

    static let unwantedName = try! NSRegularExpression(
        pattern: #"sign|song|forced|commentary|karaoke|lyric|\bop\b|\bed\b"#, options: [.caseInsensitive])
    static let hearingImpairedName = try! NSRegularExpression(
        pattern: #"sdh|\bcc\b|hearing|impaired"#, options: [.caseInsensitive])

    /// The lines of an embedded track.
    static func cues(of track: MatroskaSubtitleTrack) -> [SubtitleTimingCue] {
        var events = track.events.sorted { $0.start < $1.start }
        events = events.enumerated().filter { index, event in
            index == 0 || event.start - events[index - 1].start > 0.001
        }.map { $0.element }
        guard !events.isEmpty else { return [] }
        if track.isPGS {
            var cues: [SubtitleTimingCue] = []
            var index = 0
            while index + 1 < events.count {
                let length = events[index + 1].start - events[index].start
                if pgsLineRange.contains(length) {
                    cues.append(SubtitleTimingCue(start: events[index].start, end: events[index + 1].start))
                    index += 2
                } else {
                    index += 1
                }
            }
            return cues
        }
        return events.enumerated().map { index, event in
            let next = index + 1 < events.count ? events[index + 1].start - event.start : estimatedTextDuration
            let length = event.duration.flatMap { $0 > 0 ? $0 : nil } ?? min(next, estimatedTextDuration)
            return SubtitleTimingCue(start: event.start, end: event.start + min(max(length, 0.2), maxDuration))
        }
    }

    struct Candidate: Sendable {
        let track: MatroskaSubtitleTrack
        let cues: [SubtitleTimingCue]
    }

    /// The embedded tracks to try, best first: text tracks (ASS before SRT, as SRT copies were seen
    /// running 1.4 s late), the ones closest to the subtitle's line count; PGS only without text.
    static func candidates(in index: MatroskaSubtitleIndex, targetLineCount: Int) -> [Candidate] {
        let usable: [Candidate] = index.tracks.compactMap { track in
            guard !track.isForced, !track.isCommentary, track.isText || track.isPGS,
                  !matches(unwantedName, track.name) else { return nil }
            let lines = cues(of: track)
            guard lines.count >= minEvents,
                  let first = lines.first, let last = lines.last, last.end - first.start >= minSpan else { return nil }
            return Candidate(track: track, cues: lines)
        }
        var pool = usable.filter { $0.track.isText }
        if pool.count >= 2, let leanest = pool.map(\.cues.count).min() {
            pool = pool.filter { Double($0.cues.count) <= crowdedTrackFactor * Double(leanest) }
        }
        if pool.isEmpty { pool = usable.filter { $0.track.isPGS } }

        var seen = Set<String>()
        pool = pool.filter { candidate in
            let key = "\(candidate.cues.count):\(Int((candidate.cues[0].start * 20).rounded())):\(Int((candidate.cues[candidate.cues.count - 1].start * 20).rounded()))"
            return seen.insert(key).inserted
        }
        let target = Double(max(targetLineCount, 1))
        func score(_ candidate: Candidate) -> Double {
            var value = abs(log(Double(candidate.cues.count) / target))
            if !candidate.track.isASS { value += 0.3 }
            if candidate.track.isHearingImpaired || matches(hearingImpairedName, candidate.track.name) { value += 0.5 }
            if candidate.track.isDefault { value -= 0.05 }
            return value
        }
        return Array(pool.sorted { score($0) < score($1) }.prefix(maxCandidates))
    }

    private static func matches(_ expression: NSRegularExpression, _ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}
