import ImageIO
import UIKit
import XCTest
@testable import LYSVGAPlayer

@MainActor
final class LYSVGAFrameExporterTests: XCTestCase {
    func testImageAndPNGDataRenderRequestedFramesAtStableScale() async throws {
        let exporter = try await LYSVGAFrameExporter(video: try video())

        let first = try exporter.image(atFrame: 0, size: CGSize(width: 8, height: 4), scale: 2)
        let second = try exporter.image(atFrame: 1, size: CGSize(width: 8, height: 4), scale: 1)

        XCTAssertEqual(first.size, CGSize(width: 8, height: 4))
        XCTAssertEqual(first.scale, 2)
        XCTAssertPixel(try XCTUnwrap(first.cgImage), at: CGPoint(x: 1, y: 1), rgba: (255, 0, 0, 255))
        XCTAssertPixel(try XCTUnwrap(first.cgImage), at: CGPoint(x: 6, y: 1), rgba: (0, 0, 0, 0))
        XCTAssertPixel(try XCTUnwrap(second.cgImage), at: CGPoint(x: 6, y: 1), rgba: (255, 0, 0, 255))
        XCTAssertPixel(try XCTUnwrap(second.cgImage), at: CGPoint(x: 1, y: 1), rgba: (0, 0, 0, 0))

        let png = try exporter.pngData(atFrame: 1, scale: 2)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 16)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 8)
    }

    func testSequenceWritesSelectedFramesWithoutRemovingOtherFiles() async throws {
        let exporter = try await LYSVGAFrameExporter(video: try video())
        let directory = TestSupport.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: existing)

        let urls = try await exporter.exportPNGSequence(
            frames: 0...1,
            to: directory,
            filePrefix: "sample-",
            scale: 1
        )

        XCTAssertEqual(urls.map(\.lastPathComponent), ["sample-00000.png", "sample-00001.png"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
        for url in urls {
            XCTAssertGreaterThan(try Data(contentsOf: url).count, 0)
        }
    }

    func testInvalidFrameRangeSizeScalePrefixAndURLReturnExportErrors() async throws {
        let exporter = try await LYSVGAFrameExporter(video: try video())

        XCTAssertThrowsError(try exporter.image(atFrame: -1)) { error in
            guard case .invalidExportConfiguration = error as? LYSVGAError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try exporter.image(atFrame: 0, size: .zero)) { error in
            guard case .invalidExportConfiguration = error as? LYSVGAError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try exporter.image(atFrame: 0, scale: .infinity)) { error in
            guard case .invalidExportConfiguration = error as? LYSVGAError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try exporter.image(
            atFrame: 0,
            size: CGSize(width: 0.5, height: 1),
            scale: 1
        )) { error in
            guard case .invalidExportConfiguration = error as? LYSVGAError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await XCTAssertThrowsErrorAsync(try await exporter.exportPNGSequence(
            frames: 1...2,
            to: TestSupport.temporaryDirectory()
        ))
        await XCTAssertThrowsErrorAsync(try await exporter.exportPNGSequence(
            to: URL(string: "https://example.com/export")!
        ))
        await XCTAssertThrowsErrorAsync(try await exporter.exportPNGSequence(
            to: TestSupport.temporaryDirectory(),
            filePrefix: "nested/path"
        ))
    }

    func testCancelledSequenceMapsToLibraryCancellationError() async throws {
        let exporter = try await LYSVGAFrameExporter(video: try video())
        let directory = TestSupport.temporaryDirectory()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await exporter.exportPNGSequence(to: directory)
        }

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertEqual(error as? LYSVGAError, .cancelled)
        }
    }

    func testCancelledPreparationMapsToLibraryCancellationError() async throws {
        let movie = try video()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LYSVGAFrameExporter(video: movie)
        }

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertEqual(error as? LYSVGAError, .cancelled)
        }
    }

    private func video() throws -> LYSVGAVideo {
        let image = try solidImage(.red)
        let frames = [
            frame(x: 0),
            frame(x: 6),
        ]
        return try LYSVGAVideo(
            version: "export",
            canvasSize: LYSVGASize(width: 8, height: 4),
            fps: 20,
            frameCount: 2,
            images: ["pixel.png": try XCTUnwrap(image.pngData())],
            audioData: [:],
            sprites: [LYSVGASprite(imageKey: "pixel.png", frames: frames)],
            audios: []
        )
    }

    private func frame(x: Double) -> LYSVGAFrame {
        LYSVGAFrame(
            alpha: 1,
            layout: LYSVGARect(x: x, y: 0, width: 2, height: 2),
            transform: .identity
        )
    }

    private func solidImage(_ color: UIColor) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    private func XCTAssertPixel(
        _ image: CGImage,
        at point: CGPoint,
        rgba expected: (Int, Int, Int, Int),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let crop = image.cropping(to: CGRect(x: point.x, y: point.y, width: 1, height: 1)) else {
            return XCTFail("Unable to sample image", file: file, line: line)
        }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(Int(pixel[0]), expected.0, accuracy: 2, file: file, line: line)
        XCTAssertEqual(Int(pixel[1]), expected.1, accuracy: 2, file: file, line: line)
        XCTAssertEqual(Int(pixel[2]), expected.2, accuracy: 2, file: file, line: line)
        XCTAssertEqual(Int(pixel[3]), expected.3, accuracy: 2, file: file, line: line)
    }

    private func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ handler: (Error) -> Void = { error in
            guard case .invalidExportConfiguration = error as? LYSVGAError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected expression to throw")
        } catch {
            handler(error)
        }
    }
}
