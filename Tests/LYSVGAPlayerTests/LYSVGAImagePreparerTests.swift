import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LYSVGAPlayer

final class LYSVGAImagePreparerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LYSVGAImagePreparer.resetCacheForTesting()
    }

    func testPreparesValidPNGAndCanonicalizesItsKey() async throws {
        let video = try makeVideo(images: ["pixel.MATTE.PNG": validPNG])

        let images = try await LYSVGAImagePreparer.prepare(video)

        let image = try XCTUnwrap(images["pixel"]?.cgImage)
        XCTAssertEqual(image.width, 1)
        XCTAssertEqual(image.height, 1)
    }

    func testCorruptImageThrowsKeyedPreparationFailure() async throws {
        let video = try makeVideo(images: ["broken.png": Data("not-an-image".utf8)])

        do {
            _ = try await LYSVGAImagePreparer.prepare(video)
            XCTFail("Expected imagePreparationFailure.")
        } catch {
            XCTAssertEqual(error as? LYSVGAError, .imagePreparationFailure("broken"))
        }
    }

    func testTruncatedPNGWithRecognizableContainerThrowsPreparationFailure() async throws {
        let truncatedPNG = Data(validPNG.prefix(33))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(truncatedPNG as CFData, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 0)
        let video = try makeVideo(images: ["truncated.png": truncatedPNG])

        do {
            _ = try await LYSVGAImagePreparer.prepare(video)
            XCTFail("Expected imagePreparationFailure.")
        } catch {
            XCTAssertEqual(error as? LYSVGAError, .imagePreparationFailure("truncated"))
        }
    }

    func testEmptyImagesReturnEmptyDictionary() async throws {
        let images = try await LYSVGAImagePreparer.prepare(makeVideo(images: [:]))

        XCTAssertTrue(images.isEmpty)
    }

    func testDecodeOptionsDeferPixelCachingUntilFirstDisplay() {
        let options = LYSVGAImagePreparer.decodeOptions as NSDictionary

        XCTAssertEqual(options[kCGImageSourceShouldCache as String] as? Bool, false)
        XCTAssertEqual(options[kCGImageSourceShouldCacheImmediately as String] as? Bool, false)
    }

    func testEagerDecodeOptionsCachePixelsImmediately() {
        let options = LYSVGAImagePreparer.eagerDecodeOptions as NSDictionary

        XCTAssertEqual(options[kCGImageSourceShouldCache as String] as? Bool, true)
        XCTAssertEqual(options[kCGImageSourceShouldCacheImmediately as String] as? Bool, true)
    }

    func testEagerPreparationReplacesDeferredCacheEntry() async throws {
        let video = try makeVideo(images: ["pixel.png": validPNG])
        let deferred = try await LYSVGAImagePreparer.prepare(video)
        let eager = try await LYSVGAImagePreparer.prepareEagerly(video)
        let reused = try await LYSVGAImagePreparer.prepare(video)

        let deferredImage = try XCTUnwrap(deferred["pixel"]?.cgImage)
        let eagerImage = try XCTUnwrap(eager["pixel"]?.cgImage)
        let reusedImage = try XCTUnwrap(reused["pixel"]?.cgImage)
        XCTAssertFalse(deferredImage === eagerImage)
        XCTAssertTrue(eagerImage === reusedImage)
    }

    func testReusesPreparedImageForIdenticalDataAcrossVideosAndResourceKeys() async throws {
        let firstImages = try await LYSVGAImagePreparer.prepare(
            makeVideo(images: ["first.png": validPNG])
        )
        let secondImages = try await LYSVGAImagePreparer.prepare(
            makeVideo(images: ["second.png": validPNG])
        )

        let firstImage = try XCTUnwrap(firstImages["first"]?.cgImage)
        let secondImage = try XCTUnwrap(secondImages["second"]?.cgImage)
        XCTAssertTrue(firstImage === secondImage)
    }

    func testReusesPreparedImageForIdenticalDataWithinOneVideo() async throws {
        let images = try await LYSVGAImagePreparer.prepare(
            makeVideo(images: ["first.png": validPNG, "second.png": validPNG])
        )

        let firstImage = try XCTUnwrap(images["first"]?.cgImage)
        let secondImage = try XCTUnwrap(images["second"]?.cgImage)
        XCTAssertTrue(firstImage === secondImage)
    }

    func testConcurrentPreparationsConvergeOnOnePreparedImage() async throws {
        let firstVideo = try makeVideo(images: ["first.png": validPNG])
        let secondVideo = try makeVideo(images: ["second.png": validPNG])

        async let firstImages = LYSVGAImagePreparer.prepare(firstVideo)
        async let secondImages = LYSVGAImagePreparer.prepare(secondVideo)
        let (firstResult, secondResult) = try await (firstImages, secondImages)

        let firstImage = try XCTUnwrap(firstResult["first"]?.cgImage)
        let secondImage = try XCTUnwrap(secondResult["second"]?.cgImage)
        XCTAssertTrue(firstImage === secondImage)
    }

    func testDoesNotReusePreparedImageForDifferentEncodedData() async throws {
        let firstImages = try await LYSVGAImagePreparer.prepare(
            makeVideo(images: ["pixel.png": validPNG])
        )
        let secondImages = try await LYSVGAImagePreparer.prepare(
            makeVideo(images: ["pixel.png": png(pixels: [0x00, 0x00, 0xFF, 0xFF])])
        )

        let firstImage = try XCTUnwrap(firstImages["pixel"]?.cgImage)
        let secondImage = try XCTUnwrap(secondImages["pixel"]?.cgImage)
        XCTAssertFalse(firstImage === secondImage)
    }

    func testPreparationRespondsToTaskCancellation() async throws {
        let gate = ImagePreparationGate()
        let video = try makeVideo(images: ["pixel.png": validPNG])
        let task = Task {
            try await LYSVGAImagePreparer.prepare(video) {
                await gate.waitAtCheckpoint()
            }
        }

        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testCheckpointBypassesAnExistingPreparedImageCacheEntry() async throws {
        let video = try makeVideo(images: ["pixel.png": validPNG])
        _ = try await LYSVGAImagePreparer.prepare(video)
        let counter = ImagePreparationCheckpointCounter()

        _ = try await LYSVGAImagePreparer.prepare(video) {
            await counter.increment()
        }

        let checkpointCount = await counter.count
        XCTAssertEqual(checkpointCount, 1)
    }

    func testPreparationProcessesIndependentImagesConcurrently() async throws {
        let gate = ParallelImagePreparationGate(requiredEntrants: 2)
        let video = try makeVideo(images: [
            "one.png": validPNG,
            "two.png": validPNG,
            "three.png": validPNG,
            "four.png": validPNG,
        ])
        let task = Task {
            try await LYSVGAImagePreparer.prepare(video) {
                await gate.enterAndWait()
            }
        }

        for _ in 0..<100 where await gate.maximumEntrants < 2 {
            try await Task.sleep(for: .milliseconds(2))
        }
        let maximumEntrants = await gate.maximumEntrants
        await gate.releaseAll()
        let images = try await task.value

        XCTAssertGreaterThanOrEqual(maximumEntrants, 2)
        XCTAssertEqual(images.count, 4)
    }

    private var validPNG: Data {
        png(pixels: [0xFF, 0x00, 0x00, 0xFF])
    }

    private func png(pixels: [UInt8]) -> Data {
        let pixels = Data(pixels)
        let provider = CGDataProvider(data: pixels as CFData)!
        let image = CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func makeVideo(images: [String: Data]) throws -> LYSVGAVideo {
        try LYSVGAVideo(
            version: "test",
            canvasSize: LYSVGASize(width: 100, height: 100),
            fps: 20,
            frameCount: 1,
            images: images,
            audioData: [:],
            sprites: [],
            audios: []
        )
    }
}

private actor ImagePreparationGate {
    private var didEnter = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitAtCheckpoint() async {
        didEnter = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard didEnter == false else {
            return
        }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor ParallelImagePreparationGate {
    private let requiredEntrants: Int
    private var entrants = 0
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    private(set) var maximumEntrants = 0

    init(requiredEntrants: Int) {
        self.requiredEntrants = requiredEntrants
    }

    func enterAndWait() async {
        guard released == false else { return }
        entrants += 1
        maximumEntrants = max(maximumEntrants, entrants)
        if entrants >= requiredEntrants {
            releaseAll()
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseAll() {
        released = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor ImagePreparationCheckpointCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
