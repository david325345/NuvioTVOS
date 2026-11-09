import Combine
import SwiftAssRenderer
import SwiftUI

/// Renders authored ASS/SSA frames over Aether's video surface.
struct ASSRenderedSubtitles: UIViewRepresentable {
    let renderer: AssSubtitlesRenderer
    let reloadSignal: PassthroughSubject<ASSRenderCoordinator.ReloadEvent, Never>
    let onCanvasSizeChanged: ((AssSubtitlesRenderer) -> Void)?

    func makeUIView(context: Context) -> ASSFrameHostView {
        ASSFrameHostView(
            renderer: renderer,
            reloadSignal: reloadSignal,
            onCanvasSizeChanged: onCanvasSizeChanged
        )
    }

    func updateUIView(_ view: ASSFrameHostView, context: Context) {}
}

/// Keeps the last frame during a track reload; libass briefly publishes nil
/// while reparsing even when a visible cue has not ended.
@MainActor
final class ASSFrameHostView: UIView {
    private let renderer: AssSubtitlesRenderer
    private let onCanvasSizeChanged: ((AssSubtitlesRenderer) -> Void)?
    private let imageView = UIImageView()
    private var displayScale: CGFloat {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        return scale > 0 ? scale : 1.0
    }
    private var previousBounds = CGRect.zero
    private var cancellables = Set<AnyCancellable>()
    private var isReloading = false
    private var displayedImage: CGImage?
    private var displayedImageRect: CGRect?
    private var displayedImageScale: CGFloat?
    private var displayedDialogueIdentity: [String]?
    private var displayedRendererGeneration: Int?
    private var previousCanvasSize = CGSize.zero
    private var previousDisplayScale: CGFloat = 0
    // Test build: a reload the overlay keeps waiting on.
    private var reloadBeganAt: Date?
    private var loggedLongReload = false

    init(
        renderer: AssSubtitlesRenderer,
        reloadSignal: PassthroughSubject<ASSRenderCoordinator.ReloadEvent, Never>,
        onCanvasSizeChanged: ((AssSubtitlesRenderer) -> Void)?
    ) {
        self.renderer = renderer
        self.onCanvasSizeChanged = onCanvasSizeChanged
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        imageView.isUserInteractionEnabled = false
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        reloadSignal
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .began:
                    self.isReloading = true
                    self.reloadBeganAt = self.reloadBeganAt ?? Date()
                case .frameRendered(let snapshot):
                    guard !self.isReloading else {
                        if let began = self.reloadBeganAt, !self.loggedLongReload,
                           Date().timeIntervalSince(began) > 3 {
                            self.loggedLongReload = true
                            TestDiagnosticLog.subtitles("ASS overlay still waiting for a reload to finish after 3 s")
                        }
                        return
                    }
                    self.acceptFrame(snapshot)
                case .finished(let snapshot):
                    self.isReloading = false
                    self.reloadBeganAt = nil
                    self.finishReload(snapshot)
                }
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !bounds.isEmpty else { return }
        if !previousBounds.isEmpty, imageView.image != nil, previousBounds != bounds {
            let old = imageView.frame
            imageView.frame = CGRect(
                x: old.minX * bounds.width / previousBounds.width,
                y: old.minY * bounds.height / previousBounds.height,
                width: old.width * bounds.width / previousBounds.width,
                height: old.height * bounds.height / previousBounds.height
            ).integral
        }
        let scale = displayScale
        let canvasChanged = previousCanvasSize != bounds.size || previousDisplayScale != scale
        renderer.setCanvasSize(bounds.size, scale: scale)
        if canvasChanged {
            previousCanvasSize = bounds.size
            previousDisplayScale = scale
            TestDiagnosticLog.subtitles("ASS canvas \(Int(bounds.width))×\(Int(bounds.height)) at \(Int(scale))x")
            onCanvasSizeChanged?(renderer)
        }
    }

    private func acceptFrame(_ snapshot: ASSRenderSnapshot) {
        guard snapshot.rendererID == ObjectIdentifier(renderer) else { return }
        guard let image = snapshot.image else {
            hide()
            return
        }
        display(image, dialogueIdentity: snapshot.dialogueIdentity,
                rendererGeneration: snapshot.rendererGeneration)
    }

    private func finishReload(_ snapshot: ASSRenderSnapshot) {
        guard snapshot.rendererID == ObjectIdentifier(renderer) else { return }
        if let image = snapshot.image {
            display(image, dialogueIdentity: snapshot.dialogueIdentity,
                    rendererGeneration: snapshot.rendererGeneration)
            return
        }

        // libass can publish nil while a reload reparses an unchanged active line.
        // Preserve only when the final rendered offset still resolves to the same
        // active dialogue on the same track generation.
        guard displayedImage != nil,
              !snapshot.dialogueIdentity.isEmpty,
              displayedDialogueIdentity == snapshot.dialogueIdentity,
              displayedRendererGeneration == snapshot.rendererGeneration else {
            hide()
            return
        }
    }

    private func display(_ image: ProcessedImage, dialogueIdentity: [String],
                         rendererGeneration: Int) {
        let scale = displayScale
        let imageUnchanged = displayedImage === image.image
            && displayedImageRect == image.imageRect
            && displayedImageScale == scale
        previousBounds = bounds
        imageView.frame = image.imageRect
        if !imageUnchanged {
            imageView.image = UIImage(cgImage: image.image, scale: scale, orientation: .up)
            displayedImage = image.image
            displayedImageRect = image.imageRect
            displayedImageScale = scale
        }
        displayedDialogueIdentity = dialogueIdentity
        displayedRendererGeneration = rendererGeneration
        imageView.isHidden = false
    }

    private func hide() {
        imageView.image = nil
        imageView.isHidden = true
        displayedImage = nil
        displayedImageRect = nil
        displayedImageScale = nil
        displayedDialogueIdentity = nil
        displayedRendererGeneration = nil
    }
}
