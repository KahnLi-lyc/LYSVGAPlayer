import XCTest
@testable import LYSVGAPlayer

final class LYSVGAModelTests: XCTestCase {
    func testVideoExposesDurationAndCodableRoundTrip() throws {
        let video = try TestSupport.video()

        XCTAssertEqual(video.duration, 0.1, accuracy: 0.000_001)
        let decoded = try JSONDecoder().decode(LYSVGAVideo.self, from: JSONEncoder().encode(video))
        XCTAssertEqual(decoded, video)
    }

    func testVideoRejectsInvalidCanvasFPSAndFrameCount() {
        XCTAssertThrowsError(try makeVideo(width: 0, fps: 20, frames: 1))
        XCTAssertThrowsError(try makeVideo(width: 100, fps: 0, frames: 1))
        XCTAssertThrowsError(try makeVideo(width: 100, fps: 20, frames: 0))
    }

    func testCodableDecodeCannotBypassVideoValidation() throws {
        let encoded = try JSONEncoder().encode(TestSupport.video())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["fps"] = 0

        XCTAssertThrowsError(
            try JSONDecoder().decode(LYSVGAVideo.self, from: JSONSerialization.data(withJSONObject: object))
        ) { error in
            guard case .invalidModel = error as? LYSVGAError else {
                return XCTFail("Expected invalidModel, got \(error)")
            }
        }
    }

    private func makeVideo(width: Double, fps: Int, frames: Int) throws -> LYSVGAVideo {
        try LYSVGAVideo(
            version: "test",
            canvasSize: LYSVGASize(width: width, height: 100),
            fps: fps,
            frameCount: frames,
            images: [:],
            audioData: [:],
            sprites: [],
            audios: []
        )
    }
}
