import Combine
import CoreGraphics
import Foundation

extension PlaybackChapters {
    /// Where a chapter's thumbnail is taken: a few seconds in, past a fade from
    /// black at the cut, but inside even a short chapter.
    static func thumbnailTime(for chapter: PlaybackChapter) -> Double {
        chapter.startSeconds + min(5, chapter.durationSeconds * 0.25)
    }

    /// Tries a chapter gets before it keeps its placeholder until the panel opens again.
    static let thumbnailAttempts = 3

    /// Forward buffer that lets stills load while the panel is closed during playback.
    static let backgroundThumbnailBufferSeconds: Double = 15

    /// The wait before trying a chapter again: a few seconds after the first miss, then longer.
    static func thumbnailRetryDelay(afterAttempts attempts: Int) -> TimeInterval {
        attempts <= 1 ? 5 : 30
    }

    /// The next chapter to load among `missing`: the one closest to `anchor` (the focused
    /// chapter in the panel, else the playing one), the later one on a tie.
    static func nextThumbnailIndex(missing: [Int], anchor: Int) -> Int? {
        missing.min { a, b in
            let da = abs(a - anchor), db = abs(b - anchor)
            return da != db ? da < db : a > b
        }
    }

    /// The order the thumbnails load in: the playing chapter, then outward
    /// (next, previous, the one after, …), so what is on screen comes first.
    static func thumbnailOrder(count: Int, from current: Int) -> [Int] {
        guard count > 0 else { return [] }
        let start = min(max(current, 0), count - 1)
        var order = [start]
        var step = 1
        while order.count < count {
            if start + step < count { order.append(start + step) }
            if start - step >= 0 { order.append(start - step) }
            step += 1
        }
        return order
    }
}

/// Thumbnails for the Chapters panel, by chapter id. Its own object so a new
/// image redraws the panel only, not the whole player. Used on the main thread.
final class ChapterThumbnailStore: ObservableObject {
    @Published private(set) var images: [Int: CGImage] = [:]

    func set(_ image: CGImage, for chapterID: Int) {
        images[chapterID] = image
    }

    func reset() {
        if !images.isEmpty { images = [:] }
    }
}
