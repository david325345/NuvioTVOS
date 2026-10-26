import SwiftUI
import GestureCore

/// What the capture screen shows: the touch surface with the finger and its
/// path, the recognized gesture, the raw event log and the pretend timeline.
struct CaptureOverlay: View {
    @ObservedObject var model: LabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            HStack(alignment: .top, spacing: 48) {
                VStack(spacing: 14) {
                    PadView(model: model)
                        .frame(width: 460, height: 460)
                    Text(String(format: "%@ · %.0f bodů/s", model.controllerName, model.sampleRate))
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 460)
                }
                VStack(alignment: .leading, spacing: 18) {
                    Text(model.headline)
                        .font(.system(size: 50, weight: .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                    Text(model.detail)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    LogView(lines: model.log)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 50)
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.mode.title)
                .font(.system(size: 38, weight: .heavy))
            Spacer()
            Text("Menu = zpět")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch model.mode {
        case .test:
            TimelineStrip(timeline: model.timeline)
        case let .record(action):
            Text(model.recordCandidate.map { "\(action.title) ← \($0.title)" } ?? "\(action.title) ← zatím nic")
                .font(.system(size: 30, weight: .semibold))
        }
    }
}

/// The touch surface, drawn as a square from −1 to 1 (y up): side-tap
/// lines, the circle zone, lit presses, the finger and its path.
private struct PadView: View {
    @ObservedObject var model: LabModel

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            func point(_ p: PadPoint) -> CGPoint {
                CGPoint(x: (p.x + 1) / 2 * w, y: (1 - p.y) / 2 * h)
            }
            func path(_ points: [PadPoint]) -> Path {
                var path = Path()
                guard let first = points.first else { return path }
                path.move(to: point(first))
                for p in points.dropFirst() { path.addLine(to: point(p)) }
                return path
            }

            let frame = CGRect(x: 0, y: 0, width: w, height: h)
            context.fill(Path(roundedRect: frame, cornerRadius: 36), with: .color(.white.opacity(0.07)))
            context.stroke(Path(roundedRect: frame.insetBy(dx: 1, dy: 1), cornerRadius: 36),
                           with: .color(.white.opacity(0.25)), lineWidth: 2)

            // Circle zone and side-tap thresholds.
            let ring = model.tuning.circleMinRadius
            let ringRect = CGRect(x: (1 - ring) / 2 * w, y: (1 - ring) / 2 * h, width: ring * w, height: ring * h)
            context.stroke(Path(ellipseIn: ringRect), with: .color(.white.opacity(0.15)),
                           style: StrokeStyle(lineWidth: 2, dash: [8, 8]))
            // Taps inside this square are "in the middle"; outside, on the nearest edge.
            let side = model.tuning.sideThreshold
            let topLeft = point(PadPoint(x: -side, y: side))
            let middle = CGRect(x: topLeft.x, y: topLeft.y, width: side * w, height: side * h)
            context.stroke(Path(middle), with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 2, dash: [6, 10]))
            // Corner zones: lines at the diagonal ± half the corner width.
            if model.tuning.cornerTouches {
                let half = model.tuning.cornerWidth / 2
                for quadrant in 0..<4 {
                    for offset in [-half, half] {
                        let radians = (45 + offset + Double(quadrant) * 90) * .pi / 180
                        var line = Path()
                        line.move(to: point(PadPoint(x: cos(radians) * side * 1.2, y: sin(radians) * side * 1.2)))
                        line.addLine(to: point(PadPoint(x: cos(radians) * 1.3, y: sin(radians) * 1.3)))
                        context.stroke(line, with: .color(.white.opacity(0.12)),
                                       style: StrokeStyle(lineWidth: 2, dash: [6, 10]))
                    }
                }
            }

            // Pressed buttons light up where they are.
            let marks: [(RemoteButton, PadPoint)] = [
                (.select, PadPoint(x: 0, y: 0)), (.up, PadPoint(x: 0, y: 0.82)),
                (.down, PadPoint(x: 0, y: -0.82)), (.left, PadPoint(x: -0.82, y: 0)),
                (.right, PadPoint(x: 0.82, y: 0)),
            ]
            for (button, at) in marks {
                let c = point(at)
                let r: CGFloat = button == .select ? 46 : 30
                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                if model.pressed.contains(button) {
                    context.fill(Path(ellipseIn: rect), with: .color(.orange.opacity(0.85)))
                } else {
                    // Outlines only, so an idle mark never looks like the finger.
                    context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.18)), lineWidth: 2)
                }
            }
            if model.pressed.contains(.playPause) {
                context.draw(Text("▶︎❙❙").font(.system(size: 28, weight: .bold)).foregroundColor(.orange),
                             at: CGPoint(x: w / 2, y: h - 30))
            }

            // Finger path, finger.
            context.stroke(path(model.trail), with: .color(.cyan.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            if let finger = model.fingerPoint {
                let c = point(finger)
                context.fill(Path(ellipseIn: CGRect(x: c.x - 18, y: c.y - 18, width: 36, height: 36)),
                             with: .color(.cyan))
            }
        }
    }
}

private struct LogView: View {
    let lines: [LogLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines) { line in
                Text(line.text)
                    .font(.system(size: 21, weight: line.kind == .gesture ? .bold : .regular, design: .monospaced))
                    .foregroundStyle(color(line.kind))
                    .lineLimit(1)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 420, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.06)))
    }

    private func color(_ kind: LogLine.Kind) -> Color {
        switch kind {
        case .raw: return .white.opacity(0.6)
        case .gesture: return .green
        case .info: return .yellow
        }
    }
}

/// The pretend episode: chapters, playhead, state.
private struct TimelineStrip: View {
    let timeline: LabTimeline

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    ForEach(Array(timeline.chapters.enumerated()), id: \.offset) { index, chapter in
                        let start = chapter.start / timeline.duration
                        let end = timeline.end(ofChapter: index) / timeline.duration
                        let current = index == timeline.currentChapterIndex
                        RoundedRectangle(cornerRadius: 6)
                            .fill(current ? Color.white.opacity(0.45) : Color.white.opacity(0.18))
                            .frame(width: max(2, w * (end - start) - 4), height: 18)
                            .offset(x: w * start)
                        Text(chapter.name)
                            .font(.system(size: 18, weight: current ? .bold : .regular))
                            .lineLimit(1)
                            .frame(width: max(2, w * (end - start) - 4), alignment: .leading)
                            .offset(x: w * start + 4, y: 26)
                    }
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: 4, height: 30)
                        .offset(x: w * timeline.position / timeline.duration - 2)
                }
            }
            .frame(height: 52)
            Text("\(timeline.isPlaying ? "▶︎" : "❙❙")  \(LabTimeline.format(time: timeline.position)) / \(LabTimeline.format(time: timeline.duration))   ·   Díl \(timeline.episode)   ·   Titulky \(timeline.subtitlesOn ? "zap" : "vyp")   ·   Rychlost \(speedText)")
                .font(.system(size: 24, weight: .semibold).monospacedDigit())
        }
    }

    private var speedText: String {
        String(format: "%.2f×", timeline.speed)
    }
}
