import Foundation

public struct LabChapter: Equatable, Sendable {
    public let name: String
    public let start: Double

    public init(name: String, start: Double) {
        self.name = name
        self.start = start
    }
}

/// A pretend episode with chapters, so the actions show what they would do
/// without a real video.
public struct LabTimeline: Equatable, Sendable {
    public static let sampleChapters = [
        LabChapter(name: "Prolog", start: 0),
        LabChapter(name: "Opening", start: 90),
        LabChapter(name: "Část A", start: 180),
        LabChapter(name: "Část B", start: 720),
        LabChapter(name: "Ending", start: 1290),
        LabChapter(name: "Upoutávka", start: 1380),
    ]
    static let audioTracks = ["Japonština", "Angličtina"]
    static let speeds: [Double] = [1, 1.25, 1.5, 2]
    /// "Previous chapter" more than this far into a chapter restarts it instead.
    static let restartThreshold: Double = 3

    public let chapters: [LabChapter]
    public let duration: Double
    public var position: Double = 0
    public var isPlaying = true
    public var episode = 1
    public var subtitlesOn = true
    public var audioIndex = 0
    public var speed: Double = 1

    public init(chapters: [LabChapter] = LabTimeline.sampleChapters, duration: Double = 1420) {
        self.chapters = chapters
        self.duration = duration
    }

    public var currentChapterIndex: Int {
        chapters.lastIndex { $0.start <= position } ?? 0
    }

    public func end(ofChapter index: Int) -> Double {
        index + 1 < chapters.count ? chapters[index + 1].start : duration
    }

    public mutating func advance(by seconds: Double) {
        guard isPlaying, seconds > 0 else { return }
        position = min(duration, position + seconds * speed)
        if position >= duration { isPlaying = false }
    }

    /// Does `action` and returns the line to show.
    @discardableResult
    public mutating func perform(_ action: LabAction) -> String {
        switch action {
        case .nextChapter:
            let next = currentChapterIndex + 1
            guard next < chapters.count else { return "Poslední kapitola" }
            position = chapters[next].start
            return "Kapitola \(next + 1): \(chapters[next].name)"
        case .previousChapter:
            let index = currentChapterIndex
            if position - chapters[index].start > Self.restartThreshold || index == 0 {
                position = chapters[index].start
                return "Znovu kapitola \(index + 1): \(chapters[index].name)"
            }
            position = chapters[index - 1].start
            return "Kapitola \(index): \(chapters[index - 1].name)"
        case .skipIntro:
            guard let opening = chapters.firstIndex(where: { $0.name == "Opening" }),
                  currentChapterIndex == opening else { return "Tady není úvod" }
            position = end(ofChapter: opening)
            return "Úvod přeskočen"
        case .forward10: return seek(by: 10)
        case .back10: return seek(by: -10)
        case .forward30: return seek(by: 30)
        case .back30: return seek(by: -30)
        case .playPause:
            isPlaying.toggle()
            return isPlaying ? "Přehrává se" : "Pauza"
        case .nextEpisode:
            episode += 1
            position = 0
            isPlaying = true
            return "Díl \(episode)"
        case .toggleSubtitles:
            subtitlesOn.toggle()
            return subtitlesOn ? "Titulky zapnuté" : "Titulky vypnuté"
        case .cycleAudio:
            audioIndex = (audioIndex + 1) % Self.audioTracks.count
            return "Zvuk: \(Self.audioTracks[audioIndex])"
        case .faster:
            let index = Self.speeds.firstIndex(of: speed) ?? 0
            speed = Self.speeds[(index + 1) % Self.speeds.count]
            return "Rychlost \(Self.format(speed: speed))"
        }
    }

    private mutating func seek(by seconds: Double) -> String {
        position = min(max(0, position + seconds), duration)
        return (seconds > 0 ? "+" : "−") + "\(Int(abs(seconds))) s → " + Self.format(time: position)
    }

    public static func format(time: Double) -> String {
        let total = Int(max(0, time))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func format(speed: Double) -> String {
        var text = String(format: "%.2f", speed)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }
}
