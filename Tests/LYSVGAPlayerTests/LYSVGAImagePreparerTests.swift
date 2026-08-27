import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LYSVGAPlayer

final class LYSVGAImagePreparerTests: XCTestCase {
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

    func testEmptyImagesReturnEmptyDictionary() async throws {
        let images = try await LYSVGAImagePreparer.prepare(makeVideo(images: [:]))

        XCTAssertTrue(images.isEmpty)
    }

    func testDecodeOptionsEnableImmediateImageCaching() {
        let options = LYSVGAImagePreparer.decodeOptions as NSDictionary

        XCTAssertEqual(options[kCGImageSourceShouldCache as String] as? Bool, true)
        XCTAssertEqual(options[kCGImageSourceShouldCacheImmediately as String] as? Bool, true)
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

    private var validPNG: Data {
        let pixels = Data([0xFF, 0x00, 0x00, 0xFF])
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
