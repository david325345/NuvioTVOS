import CoreImage
import Foundation
import UIKit

/// Blurred copies of backdrops for Details. Blurring a small copy once and
/// fading it in costs far less than animating `.blur(radius:)` over the full
/// screen, which re-renders the blur on every frame of the animation.
final class BackdropBlurCache: @unchecked Sendable {
    static let shared = BackdropBlurCache()

    /// Width the blur is rendered at. Shown about four times larger, which
    /// a heavy blur hides completely.
    private static let renderWidth: CGFloat = 480
    /// Blur radius in screen points (Details used `.blur(radius: 22)`).
    private static let screenRadius: CGFloat = 22
    private static let screenWidth: CGFloat = 1920

    private let cache = NSCache<NSString, UIImage>()
    private let context = CIContext(options: [.cacheIntermediates: false])

    private init() {
        cache.countLimit = 12
    }

    func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func blurredImage(for url: URL, from source: UIImage) async -> UIImage? {
        if let cached = cachedImage(for: url) { return cached }
        let context = self.context
        let blurred = await Task.detached(priority: .utility) {
            BackdropBlurCache.render(source, context: context)
        }.value
        if let blurred {
            cache.setObject(blurred, forKey: url.absoluteString as NSString)
        }
        return blurred
    }

    private static func render(_ image: UIImage, context: CIContext) -> UIImage? {
        guard let cgImage = image.cgImage, cgImage.width > 0 else { return nil }
        var input = CIImage(cgImage: cgImage)
        let scale = min(1, renderWidth / CGFloat(cgImage.width))
        if scale < 1 {
            input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let extent = input.extent.integral
        // The copy is drawn stretched to the screen width, so scale the radius
        // down by the same factor to match the old on-screen blur.
        let radius = screenRadius * extent.width / screenWidth
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        // Clamping first keeps the edges from fading to black (`opaque: true`).
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: extent),
              let rendered = context.createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: rendered)
    }
}

/// Lets the Home hero wait briefly for its artwork and ratings, so text,
/// logo, backdrop and ratings change together instead of one after another.
enum HeroDisplayPreparation {
    /// Runs `work` and returns when it finishes, when `timeout` passes, or
    /// when the calling task is cancelled — whichever comes first. The work
    /// itself keeps going after a timeout and still fills the caches.
    static func waitBounded(
        timeout: Duration,
        _ work: @escaping @Sendable () async -> Void
    ) async {
        let job = Task.detached(priority: .userInitiated) { await work() }
        let timer = Task { try? await Task.sleep(for: timeout) }
        let gate = ResumeOnce()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gate.set(continuation)
                Task {
                    await job.value
                    gate.resume()
                }
                Task {
                    await timer.value
                    gate.resume()
                }
            }
        } onCancel: {
            timer.cancel()
        }
        timer.cancel()
    }

    /// Resumes a continuation exactly once, whichever side gets there first.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var resumed = false

        func set(_ continuation: CheckedContinuation<Void, Never>) {
            let resumeNow: Bool = lock.withLock {
                if resumed { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }

        func resume() {
            let pending: CheckedContinuation<Void, Never>? = lock.withLock {
                guard !resumed else { return nil }
                resumed = true
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume()
        }
    }
}
