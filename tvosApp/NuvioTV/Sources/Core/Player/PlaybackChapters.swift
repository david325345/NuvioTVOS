import Foundation

/// One chapter of the playing file (Matroska / MP4 container chapters), on
/// the same 0-based axis as the playback position and `seek(to:)`.
struct PlaybackChapter: Equatable, Identifiable, Hashable {
    let id: Int
    let name: String
    let startSeconds: Double
    let endSeconds: Double

    var durationSeconds: Double { max(0, endSeconds - startSeconds) }
}

/// Chapter lookups for the player: names to show, where the playhead is, the
/// marks on the timeline, and Skip Intro / Skip Ending from chapter names.
enum PlaybackChapters {
    /// Chapters from an engine's (start, duration) list: sorted, each ending
    /// where the next one starts when the container gives no length, the last
    /// at the end of the video. A single chapter is no chapter list: the file
    /// gets no Chapters button and no marks.
    static func chapters(
        from items: [(id: Int, name: String, start: Double, duration: Double)],
        totalDuration: Double
    ) -> [PlaybackChapter] {
        let sorted = items
            .filter { $0.start.isFinite && $0.start >= 0 }
            .sorted { $0.start < $1.start }
        guard sorted.count >= 2 else { return [] }
        return sorted.enumerated().map { index, item in
            let next = index + 1 < sorted.count ? sorted[index + 1].start : nil
            var end = item.duration.isFinite && item.duration > 0 ? item.start + item.duration : (next ?? totalDuration)
            if let next { end = min(end, next) }
            if totalDuration > 0 { end = min(end, totalDuration) }
            return PlaybackChapter(id: item.id, name: item.name, startSeconds: item.start, endSeconds: max(item.start, end))
        }
    }

    /// The chapter's own name, or "Chapter N" when it has none or only a
    /// generic one ("Chapter 03", "00:12:30.000").
    static func displayName(_ chapter: PlaybackChapter, index: Int) -> String {
        let name = chapter.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || isGeneric(name) {
            return L10n.format("player_chapter_number", fallback: "Chapter %d", index + 1)
        }
        return name
    }

    private static func isGeneric(_ name: String) -> Bool {
        name.range(of: #"^(chapter|kapitola|chapitre|kapitel|cap[ií]tulo|capitolo)\s*\d+$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
            || name.range(of: #"^\d{1,2}:\d{2}(:\d{2})?([.,]\d+)?$"#, options: .regularExpression) != nil
    }

    /// The chapter that holds `seconds`, if any.
    static func index(at seconds: Double, in chapters: [PlaybackChapter]) -> Int? {
        guard seconds.isFinite else { return nil }
        return chapters.lastIndex { seconds >= $0.startSeconds - 0.25 }
            .flatMap { seconds < chapters[$0].endSeconds || $0 == chapters.count - 1 ? $0 : nil }
    }

    /// Where chapters start on the timeline, as fractions of the duration
    /// (the first chapter at the very start is not marked).
    static func markers(_ chapters: [PlaybackChapter], duration: Double) -> [Double] {
        guard duration > 0, chapters.count > 1 else { return [] }
        return chapters
            .map { $0.startSeconds / duration }
            .filter { $0 > 0.002 && $0 < 0.998 }
    }

    // MARK: - Skip from chapter names

    enum Kind: Equatable {
        case opening
        case ending
    }

    /// An opening or an ending on the timeline, as fractions of the duration.
    struct TimelineSegment: Equatable {
        let start: Double
        let end: Double
        let kind: Kind
    }

    /// Longest chapter still taken for an opening or an ending: anything longer
    /// is more likely a part of the episode that happens to carry the name.
    static let maxOpeningSeconds: Double = 180
    static let maxEndingSeconds: Double = 240
    static let minSegmentSeconds: Double = 15

    /// What a chapter name says: "Opening", "OP", "OP2", "Intro", "Opening
    /// Credits" → opening; "Ending", "ED", "Credits", "End Credits", "Outro" →
    /// ending. Anything else (Part A, Prologue, Preview, Chapter 3) → nil.
    static func kind(ofName name: String) -> Kind? {
        let normalized = name.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return nil }
        if normalized.range(of: #"^(op ?\d*|opening( (credits|song|theme|titles))?|intro(duction)?)( \d+)?$"#,
                            options: .regularExpression) != nil {
            return .opening
        }
        if normalized.range(of: #"^(ed ?\d*|ending( (credits|song|theme))?|end credits|closing credits|credits|outro)( \d+)?$"#,
                            options: .regularExpression) != nil {
            return .ending
        }
        return nil
    }

    /// Skip Intro / Skip Ending intervals from chapter names: the first short
    /// opening and the first short ending chapter.
    static func skipIntervals(from chapters: [PlaybackChapter]) -> [SkipInterval] {
        var opening: SkipInterval?
        var ending: SkipInterval?
        for chapter in chapters {
            guard let kind = kind(ofName: chapter.name), chapter.durationSeconds >= minSegmentSeconds else { continue }
            switch kind {
            case .opening where opening == nil && chapter.durationSeconds <= maxOpeningSeconds:
                opening = SkipInterval(startTime: chapter.startSeconds, endTime: chapter.endSeconds,
                                       type: "intro", provider: "chapters")
            case .ending where ending == nil && chapter.durationSeconds <= maxEndingSeconds:
                ending = SkipInterval(startTime: chapter.startSeconds, endTime: chapter.endSeconds,
                                      type: "outro", provider: "chapters")
            default:
                break
            }
        }
        return [opening, ending].compactMap { $0 }
    }

    /// Where the opening and the ending sit on the timeline, as fractions of
    /// the duration, from the skip segments in use (IntroDB and chapters).
    static func timelineSegments(_ intervals: [SkipInterval], duration: Double) -> [TimelineSegment] {
        guard duration > 0 else { return [] }
        return intervals.compactMap { interval in
            let kind: Kind
            if interval.isIntro {
                kind = .opening
            } else if interval.isEnding {
                kind = .ending
            } else {
                return nil
            }
            let start = min(max(interval.startTime / duration, 0), 1)
            let end = min(max(interval.endTime / duration, 0), 1)
            guard end - start > 0.001 else { return nil }
            return TimelineSegment(start: start, end: end, kind: kind)
        }
    }

    /// A chapter's badge in the list: from its name, or from the segment it
    /// lines up with (IntroDB's opening over an unnamed chapter).
    static func kind(of chapter: PlaybackChapter, segments: [SkipInterval]) -> Kind? {
        if let named = kind(ofName: chapter.name) { return named }
        let match = segments.first {
            abs($0.startTime - chapter.startSeconds) <= 3 && abs($0.endTime - chapter.endSeconds) <= 3
        }
        guard let match else { return nil }
        return match.isIntro ? .opening : (match.isEnding ? .ending : nil)
    }

    /// IntroDB first; chapters only fill an opening or an ending IntroDB
    /// doesn't have.
    static func merged(introDB: [SkipInterval], chapters: [SkipInterval]) -> [SkipInterval] {
        let hasIntro = introDB.contains(where: \.isIntro)
        let hasEnding = introDB.contains(where: \.isEnding)
        let extra = chapters.filter { ($0.isIntro && !hasIntro) || ($0.isEnding && !hasEnding) }
        guard !extra.isEmpty else { return introDB }
        return (introDB + extra).sorted { $0.startTime < $1.startTime }
    }
}
