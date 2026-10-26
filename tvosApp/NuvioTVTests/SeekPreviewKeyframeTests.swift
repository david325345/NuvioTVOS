import XCTest
import CoreGraphics
import AetherEngine
@testable import NuvioTV

final class SeekPreviewKeyframeTests: XCTestCase {
    private func makeImage() -> CGImage {
        let bytes = Data([0, 0, 0, 255])
        return CGImage(
            width: 1, height: 1,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: bytes as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    func testExactRequestsStayWithinHalfASecond() {
        XCTAssertTrue(HybridSeekThumbnailPolicy.acceptsPreview(actualSeconds: 42.3, requestedSeconds: 42, precise: true))
        XCTAssertFalse(HybridSeekThumbnailPolicy.acceptsPreview(actualSeconds: 39, requestedSeconds: 42, precise: true))
        XCTAssertFalse(HybridSeekThumbnailPolicy.acceptsPreview(actualSeconds: nil, requestedSeconds: 42, precise: true))
        XCTAssertFalse(HybridSeekThumbnailPolicy.acceptsPreview(actualSeconds: .nan, requestedSeconds: 42, precise: false))
    }

    func testFastRequestsTakeTheKeyframeBeforeTheTarget() {
        XCTAssertTrue(HybridSeekThumbnailPolicy.acceptsPreview(actualSeconds: 39, requestedSeconds: 42, precise: false))
        XCTAssertTrue(HybridSeekThumbnailPolicy.acceptsPreview(actualSeconds: 30.5, requestedSeconds: 42, precise: false))
        // Too far back, or past the target: not this position.
        XCTAssertFalse(HybridSeekThumbnailPolicy.acceptsPreview(actualSeconds: 25, requestedSeconds: 42, precise: false))
        XCTAssertFalse(HybridSeekThumbnailPolicy.acceptsPreview(actualSeconds: 44, requestedSeconds: 42, precise: false))
    }

    @MainActor
    func testResidentKeyframeIsKeptForAFastRequestWithoutFallback() async {
        let image = makeImage()
        let keyframe = ScrubFrame(image: image, actualSeconds: 39, refined: false, validRange: 38..<46)
        XCTAssertTrue(AetherPlaybackController.acceptsBoundedScrubFrame(keyframe, at: 42, precise: false))
        XCTAssertFalse(AetherPlaybackController.acceptsBoundedScrubFrame(keyframe, at: 42))

        var fallbackCount = 0
        let result = await AetherPlaybackController.boundedProgressiveScrubFrame(
            at: 42,
            precise: false,
            resident: { keyframe },
            ownsSource: { true },
            cleanup: {},
            isCurrent: { true },
            fallback: {
                fallbackCount += 1
                return nil
            })
        XCTAssertEqual(fallbackCount, 0)
        XCTAssertTrue(result?.image === image)
        XCTAssertEqual(result?.actualSeconds, 39)
    }

    func testOriginStillAcceptanceFollowsTheRequest() {
        let still = BoundedStillFrame(image: makeImage(), actualSeconds: 39)
        XCTAssertTrue(PlaybackThumbnailSourceFallback.isAccurate(still, requestedSeconds: 42, precise: false))
        XCTAssertFalse(PlaybackThumbnailSourceFallback.isAccurate(still, requestedSeconds: 42))
    }
}
