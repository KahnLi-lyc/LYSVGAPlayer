import XCTest
@testable import LYSVGAPlayer

final class LYSVGAFormatDecoderTests: XCTestCase {
    func testDetectsZIPAndZlibFixtures() throws {
        XCTAssertEqual(try LYSVGAFormatDecoder.detect(TestSupport.fixture("mutiMatte")), .zip)
        XCTAssertEqual(try LYSVGAFormatDecoder.detect(TestSupport.fixture("matteRect")), .zlib)
    }

    func testDecodesV1JSONFixtureIntoUnifiedModel() throws {
        let video = try LYSVGAFormatDecoder.decode(TestSupport.fixture("mutiMatte"))

        XCTAssertEqual(video.version, "1.1.0")
        XCTAssertEqual(video.canvasSize, LYSVGASize(width: 600, height: 600))
        XCTAssertEqual(video.fps, 30)
        XCTAssertEqual(video.frameCount, 1)
        XCTAssertEqual(video.sprites.count, 3)
        XCTAssertEqual(video.sprites[1].matteKey, "white")
        guard case let .rect(rect) = video.sprites[1].frames[0].shapes[0].type else {
            return XCTFail("Expected a mapped rectangle shape.")
        }
        XCTAssertEqual(rect.rect.width, 299.62109375, accuracy: 0.000_001)
        XCTAssertEqual(video.sprites[1].frames[0].shapes[0].style.fill?.red, 1)
    }

    func testDecodesV2ProtobufFixtureIntoUnifiedModel() throws {
        let video = try LYSVGAFormatDecoder.decode(TestSupport.fixture("matteRect"))

        XCTAssertFalse(video.version.isEmpty)
        XCTAssertGreaterThan(video.canvasSize.width, 0)
        XCTAssertGreaterThan(video.canvasSize.height, 0)
        XCTAssertGreaterThan(video.fps, 0)
        XCTAssertGreaterThan(video.frameCount, 0)
        XCTAssertFalse(video.sprites.isEmpty)
        XCTAssertTrue(video.sprites.flatMap(\.frames).flatMap(\.shapes).contains { shape in
            if case .rect = shape.type { return true }
            return false
        })
    }

    func testShortAndCorruptDataAlwaysThrowSpecificErrors() throws {
        XCTAssertThrowsError(try LYSVGAFormatDecoder.decode(Data([0x50, 0x4B]))) { error in
            XCTAssertEqual(error as? LYSVGAError, .dataTooShort(actual: 2, minimum: 4))
        }
        XCTAssertThrowsError(try LYSVGAFormatDecoder.decode(Data([0x78, 0x9C, 0x00, 0x00]))) { error in
            guard case .decompressionFailure = error as? LYSVGAError else {
                return XCTFail("Expected decompressionFailure, got \(error)")
            }
        }
        XCTAssertThrowsError(try LYSVGAFormatDecoder.decode(Data([0x50, 0x4B, 0x03, 0x04]))) { error in
            guard case .zipFailure = error as? LYSVGAError else {
                return XCTFail("Expected zipFailure, got \(error)")
            }
        }
    }

    func testRejectsArchivePathTraversalBeforeExtraction() throws {
        XCTAssertThrowsError(try LYSVGAFormatDecoder.decode(TestSupport.fixture("unsafeTraversal"))) { error in
            XCTAssertEqual(error as? LYSVGAError, .unsafeArchiveEntry("../movie.spec"))
        }
    }
}
