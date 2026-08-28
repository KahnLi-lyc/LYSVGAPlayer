import CoreGraphics
import ImageIO
import UIKit
import XCTest
@testable import LYSVGAPlayer

private enum SnapshotError: Error {
    case failure(String)
}

@MainActor
final class LYSVGAPixelSnapshotTests: XCTestCase {
    private let snapshotSize = CGSize(width: 128, height: 128)

    func testV1BitmapSnapshot() async throws {
        try await assertSnapshot(fixture: "matteBitmap_1.x", frame: 0, named: "v1-bitmap")
    }

    func testV2BitmapSnapshot() async throws {
        try await assertSnapshot(fixture: "rose_2.0.0", frame: 20, named: "v2-bitmap")
    }

    func testVectorSnapshot() async throws {
        try await assertSnapshot(fixture: "mutiMatte", frame: 0, named: "vector")
    }

    func testMatteSnapshot() async throws {
        try await assertSnapshot(fixture: "matteRect", frame: 0, named: "matte")
    }
}

@MainActor
private extension LYSVGAPixelSnapshotTests {
    func assertSnapshot(
        fixture: String,
        frame: Int,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let video = try LYSVGAFormatDecoder.decode(TestSupport.fixture(fixture))
        let renderer = LYSVGARenderer()
        try await renderer.prepare(video: video)
        renderer.layout(
            in: CGRect(origin: .zero, size: snapshotSize),
            contentMode: .scaleAspectFit,
            clipsToBounds: true
        )
        renderer.display(frame: min(frame, video.frameCount - 1))

        let actual = try render(renderer.rootLayer)
        guard let baselineURL = Bundle.module.url(
            forResource: name,
            withExtension: "png",
            subdirectory: "Fixtures/Snapshots"
        ) else {
            try record(actual, named: name)
            return XCTFail("Recorded missing snapshot \(name).png; rerun the test.", file: file, line: line)
        }
        let expected = try loadImage(at: baselineURL)
        XCTAssertEqual(actual.width, expected.width, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, file: file, line: line)
        guard actual.width == expected.width, actual.height == expected.height else { return }

        let actualBytes = try rgbaBytes(actual)
        let expectedBytes = try rgbaBytes(expected)
        var differingPixels = 0
        var totalChannelDifference = 0
        var maximumChannelDifference = 0

        for pixelOffset in stride(from: 0, to: actualBytes.count, by: 4) {
            var pixelDiffers = false
            for channel in 0..<4 {
                let difference = abs(Int(actualBytes[pixelOffset + channel]) - Int(expectedBytes[pixelOffset + channel]))
                totalChannelDifference += difference
                maximumChannelDifference = max(maximumChannelDifference, difference)
                if difference > 8 { pixelDiffers = true }
            }
            if pixelDiffers { differingPixels += 1 }
        }

        let pixelCount = actual.width * actual.height
        let allowedDifferingPixels = max(1, pixelCount / 500)
        let meanChannelDifference = Double(totalChannelDifference) / Double(pixelCount * 4)
        XCTAssertLessThanOrEqual(
            differingPixels,
            allowedDifferingPixels,
            "\(name): \(differingPixels) pixels exceeded tolerance 8; max channel delta \(maximumChannelDifference)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            meanChannelDifference,
            0.5,
            "\(name): mean channel delta \(meanChannelDifference)",
            file: file,
            line: line
        )
    }

    func render(_ layer: CALayer) throws -> CGImage {
        let width = Int(snapshotSize.width)
        let height = Int(snapshotSize.height)
        guard let context = makeContext(width: width, height: height) else {
            throw SnapshotError.failure("Unable to create the snapshot bitmap context.")
        }
        context.translateBy(x: 0, y: snapshotSize.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        guard let image = context.makeImage() else {
            throw SnapshotError.failure("Unable to create the snapshot image.")
        }
        return image
    }

    func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = makeContext(width: image.width, height: image.height, data: &bytes) else {
            throw SnapshotError.failure("Unable to normalize snapshot pixels.")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    func makeContext(width: Int, height: Int, data: UnsafeMutableRawPointer? = nil) -> CGContext? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    func loadImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SnapshotError.failure("Unable to decode snapshot \(url.lastPathComponent).")
        }
        return image
    }

    func record(_ image: CGImage, named name: String) throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let outputDirectory = testDirectory.appendingPathComponent("Fixtures/Snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = outputDirectory.appendingPathComponent("\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw SnapshotError.failure("Unable to create snapshot destination.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SnapshotError.failure("Unable to write snapshot \(name).png.")
        }
    }
}
