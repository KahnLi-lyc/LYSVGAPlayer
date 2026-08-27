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
        XCTAssertEqual(video.sprites[0].imageKey, "white.matte")
        XCTAssertEqual(video.sprites[1].imageKey, "red.vector")
        XCTAssertEqual(video.sprites[1].matteKey, "white.matte")
        guard case let .rect(rect) = video.sprites[1].frames[0].shapes[0].type else {
            return XCTFail("Expected a mapped rectangle shape.")
        }
        XCTAssertEqual(rect.rect.width, 299.62109375, accuracy: 0.000_001)
        XCTAssertEqual(video.sprites[1].frames[0].shapes[0].style.fill?.red, 1)
    }

    func testDecodesV1ImageFilenameWithPNGFallback() throws {
        let video = try LYSVGAFormatDecoder.decode(TestSupport.fixture("matteBitmap_1.x"))

        let image = try XCTUnwrap(video.images["dengziqi"])
        XCTAssertEqual(image.count, 70_988)
        XCTAssertEqual(Array(image.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(video.sprites[0].imageKey, "dengziqi.matte")
        XCTAssertTrue(video.sprites.dropFirst().allSatisfy { $0.matteKey == "dengziqi.matte" })
    }

    func testV1StyleMapsLineDashArrayAndDefaultsToEmpty() throws {
        let json = Data(#"""
        {
          "ver":"1.1.0",
          "movie":{"viewBox":{"width":10,"height":10},"fps":20,"frames":1},
          "sprites":[{"imageKey":"shape.vector","frames":[{
            "alpha":1,"layout":{"x":0,"y":0,"width":10,"height":10},
            "transform":{"a":1,"b":0,"c":0,"d":1,"tx":0,"ty":0},
            "shapes":[
              {"type":"shape","args":{"d":"M0 0"},"styles":{"lineDash":[3,2,1]}},
              {"type":"keep","styles":{}}
            ]
          }]}]
        }
        """#.utf8)

        let video = try LYSVGAV1Decoder.decode(json, resourceDirectory: TestSupport.temporaryDirectory())
        XCTAssertEqual(video.sprites[0].frames[0].shapes[0].style.lineDash, [3, 2, 1])
        XCTAssertEqual(video.sprites[0].frames[0].shapes[1].style.lineDash, [])
    }

    func testDecodesV2ProtobufFixtureIntoUnifiedModel() throws {
        let video = try LYSVGAFormatDecoder.decode(TestSupport.fixture("matteRect"))

        XCTAssertFalse(video.version.isEmpty)
        XCTAssertGreaterThan(video.canvasSize.width, 0)
        XCTAssertGreaterThan(video.canvasSize.height, 0)
        XCTAssertGreaterThan(video.fps, 0)
        XCTAssertGreaterThan(video.frameCount, 0)
        XCTAssertFalse(video.sprites.isEmpty)
        XCTAssertTrue(video.sprites.contains { $0.imageKey.hasSuffix(".matte") })
        XCTAssertTrue(video.sprites.contains { $0.imageKey.hasSuffix(".vector") })
        XCTAssertTrue(video.sprites.flatMap(\.frames).flatMap(\.shapes).contains { shape in
            if case .rect = shape.type { return true }
            return false
        })
    }

    func testV2OmittedFrameTransformMapsToIdentity() throws {
        var movie = makeV2Movie()
        var frame = Com_Opensource_Svga_FrameEntity()
        frame.alpha = 1
        var layout = Com_Opensource_Svga_Layout()
        layout.width = 10
        layout.height = 10
        frame.layout = layout
        var sprite = Com_Opensource_Svga_SpriteEntity()
        sprite.imageKey = "shape.vector"
        sprite.frames = [frame]
        movie.sprites = [sprite]

        let video = try LYSVGAV2Decoder.decode(movie.serializedData())
        XCTAssertEqual(video.sprites[0].frames[0].transform, .identity)
        XCTAssertEqual(video.sprites[0].imageKey, "shape.vector")
    }

    func testV2ExternalResourcesResolveExactAndPNGFallback() throws {
        let directory = TestSupport.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let exact = Data("exact-bytes".utf8)
        let fallback = Data("png-bytes".utf8)
        try exact.write(to: directory.appendingPathComponent("asset.bin"))
        try fallback.write(to: directory.appendingPathComponent("fallback.png"))
        var movie = makeV2Movie()
        movie.images = [
            "first.png": Data("asset.bin".utf8),
            "second.png": Data("fallback".utf8),
        ]

        let video = try LYSVGAV2Decoder.decode(movie.serializedData(), resourceDirectory: directory)
        XCTAssertEqual(video.images["first"], exact)
        XCTAssertEqual(video.images["second"], fallback)
    }

    func testV2ExternalResourceSupportsPrintableUTF8Filename() throws {
        let directory = TestSupport.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expected = Data("unicode-resource".utf8)
        try expected.write(to: directory.appendingPathComponent("资源.png"))
        var movie = makeV2Movie()
        movie.images = ["image.png": Data("资源.png".utf8)]

        let video = try LYSVGAV2Decoder.decode(movie.serializedData(), resourceDirectory: directory)
        XCTAssertEqual(video.images["image"], expected)
    }

    func testV2PrintableBytesRemainEmbeddedWithoutResourceDirectory() throws {
        var movie = makeV2Movie()
        movie.images = ["inline.png": Data("printable-inline-data".utf8)]

        let video = try LYSVGAV2Decoder.decode(movie.serializedData())
        XCTAssertEqual(video.images["inline"], Data("printable-inline-data".utf8))
    }

    func testV2MissingAndUnsafeExternalReferencesThrow() throws {
        let directory = TestSupport.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var missing = makeV2Movie()
        missing.images = ["image.png": Data("missing".utf8)]
        XCTAssertThrowsError(try LYSVGAV2Decoder.decode(missing.serializedData(), resourceDirectory: directory)) {
            guard case .missingResource = $0 as? LYSVGAError else {
                return XCTFail("Expected missingResource, got \($0)")
            }
        }

        var unsafe = makeV2Movie()
        unsafe.images = ["image.png": Data("../outside".utf8)]
        XCTAssertThrowsError(try LYSVGAV2Decoder.decode(unsafe.serializedData(), resourceDirectory: directory)) {
            XCTAssertEqual($0 as? LYSVGAError, .unsafeArchiveEntry("../outside"))
        }
    }

    func testShortAndCorruptDataAlwaysThrowSpecificErrors() throws {
        XCTAssertThrowsError(try LYSVGAFormatDecoder.decode(Data([0x50, 0x4B]))) { error in
            XCTAssertEqual(error as? LYSVGAError, .dataTooShort(actual: 2, minimum: 4))
        }
        XCTAssertThrowsError(try LYSVGAFormatDecoder.decode(Data([0x78, 0x9C, 0x00, 0x00]))) { error in
            XCTAssertEqual(error as? LYSVGAError, .dataTooShort(actual: 4, minimum: 6))
        }
        var corruptZlib = try TestSupport.fixture("matteRect")
        corruptZlib[corruptZlib.index(before: corruptZlib.endIndex)] ^= 0x01
        XCTAssertThrowsError(try LYSVGAFormatDecoder.decode(corruptZlib)) { error in
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

    func testRejectsArchiveSymlinkEntry() throws {
        XCTAssertThrowsError(try LYSVGAFormatDecoder.decode(TestSupport.fixture("unsafeSymlink"))) { error in
            XCTAssertEqual(error as? LYSVGAError, .unsafeArchiveEntry("movie.spec"))
        }
    }

    private func makeV2Movie() -> Com_Opensource_Svga_MovieEntity {
        var params = Com_Opensource_Svga_MovieParams()
        params.viewBoxWidth = 10
        params.viewBoxHeight = 10
        params.fps = 20
        params.frames = 1
        var movie = Com_Opensource_Svga_MovieEntity()
        movie.version = "2.0"
        movie.params = params
        return movie
    }
}
