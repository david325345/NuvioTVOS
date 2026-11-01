import Foundation

/// What the remote gestures do (fork test build). Each action says what it did in a short
/// bubble at the top, as the gestures have no other feedback.
extension PlayerViewModel {
    func performGestureAction(_ action: PlayerGestureAction) {
        switch action {
        case .nextChapter:
            jumpChapter(forward: true)
        case .previousChapter:
            jumpChapter(forward: false)
        case .openChapters:
            if isSceneEnabled {
                openScene()
            } else {
                showPlayerToast("InSight je vypnutý")
            }
        case .skipIntro:
            skipSegmentByGesture()
        case .forward30:
            jumpBy(30)
        case .back30:
            jumpBy(-30)
        case .playPause:
            togglePlayPause()
        case .nextEpisode:
            if nextEpisode != nil {
                showPlayerToast("Další díl")
                playNextEpisode()
            } else {
                showPlayerToast("Žádný další díl")
            }
        case .toggleSubtitles:
            toggleSubtitlesByGesture()
        case .cycleAudio:
            cycleAudioByGesture()
        case .faster:
            let speeds = PlaybackSpeed.allCases
            let index = speeds.firstIndex(of: playbackSpeed) ?? 0
            let next = speeds[(index + 1) % speeds.count]
            setSpeed(next)
            showPlayerToast("Rychlost \(next.label)")
        }
    }

    /// Next: the chapter after the playhead. Previous: the start of this chapter, or the one before
    /// when the playhead is within its first 3 seconds.
    private func jumpChapter(forward: Bool) {
        let chapters = self.chapters
        guard !chapters.isEmpty else {
            showPlayerToast("Soubor nemá kapitoly")
            return
        }
        let position = time.current
        let current = PlaybackChapters.index(at: position, in: chapters) ?? 0
        let target: Int
        if forward {
            guard current + 1 < chapters.count else {
                showPlayerToast("Poslední kapitola")
                return
            }
            target = current + 1
        } else {
            target = position - chapters[current].startSeconds > 3 ? current : max(current - 1, 0)
        }
        seek(to: chapters[target].startSeconds)
        showPlayerToast("Kapitola \(target + 1) · \(PlaybackChapters.displayName(chapters[target], index: target))")
    }

    private func jumpBy(_ seconds: Double) {
        let duration = time.duration
        let target = max(0, min(time.current + seconds, duration > 0 ? duration - 1 : time.current + seconds))
        seek(to: target)
        showPlayerToast(seconds > 0 ? "+\(Int(seconds)) s" : "−\(Int(-seconds)) s")
    }

    /// The opening or ending the playhead is in (the Skip card's, or one from IntroDB / the chapters).
    private func skipSegmentByGesture() {
        if activeSkipInterval != nil {
            skipActiveInterval()
            showPlayerToast("Přeskočeno")
            return
        }
        let position = time.current
        if let segment = skipSegments.first(where: { $0.startTime <= position && position < $0.endTime - 1 }) {
            skipInterval(segment)
            showPlayerToast("Přeskočeno")
        } else {
            showPlayerToast("Tady není co přeskočit")
        }
    }

    /// Off, and back on to the subtitle that was on (or the first one).
    private func toggleSubtitlesByGesture() {
        if let selected = subtitles.first(where: { $0.isSelected && $0.id != "off" }) {
            gestureLastSubtitleID = selected.id
            if let off = subtitles.first(where: { $0.id == "off" }) {
                selectSubtitle(off)
            }
            showPlayerToast("Titulky vypnuty")
            return
        }
        let candidates = subtitles.filter { $0.id != "off" }
        guard let track = candidates.first(where: { $0.id == gestureLastSubtitleID }) ?? candidates.first else {
            showPlayerToast("Žádné titulky")
            return
        }
        selectSubtitle(track)
        showPlayerToast("Titulky: \(track.name.isEmpty ? track.language : track.name)")
    }

    private func cycleAudioByGesture() {
        let tracks = audioTracks
        guard tracks.count > 1 else {
            showPlayerToast(tracks.isEmpty ? "Žádné zvukové stopy" : "Jen jedna zvuková stopa")
            return
        }
        let index = tracks.firstIndex(where: \.isSelected) ?? -1
        let next = tracks[(index + 1) % tracks.count]
        selectAudio(next)
        let name = next.languageName.isEmpty ? next.name : next.languageName
        showPlayerToast("Zvuk: \(name)")
    }
}

extension PlayerViewModel {
    func setGesturesEnabled(_ enabled: Bool) {
        PlayerGestureSettings.setEnabled(enabled)
        areGesturesEnabled = enabled
    }
}
