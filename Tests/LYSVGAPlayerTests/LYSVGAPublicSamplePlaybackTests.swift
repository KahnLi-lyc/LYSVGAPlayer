import UIKit
import XCTest
@testable import LYSVGAPlayer

@MainActor
final class LYSVGAPublicSamplePlaybackTests: XCTestCase {
    func testPublicSamplesInstallAndEnterPlayback() async throws {
        let fixtures = ["rose_2.0.0", "rose_1.5.0", "matteBitmap", "audio_biling"]

        for fixture in fixtures {
            let video = try LYSVGAFormatDecoder.decode(TestSupport.fixture(fixture))
            let playerView = LYSVGAPlayerView(frame: CGRect(x: 0, y: 0, width: 256, height: 256))
            playerView.contentMode = .scaleAspectFit
            try await playerView.setVideo(video)

            XCTAssertEqual(playerView.playbackState, .ready, fixture)
            XCTAssertEqual(playerView.video, video, fixture)
            XCTAssertNotNil(playerView.rendererRootLayerForTesting, fixture)

            try playerView.play()
            XCTAssertEqual(playerView.playbackState, .playing, fixture)
            XCTAssertEqual(playerView.currentFrame, 0, fixture)

            playerView.seek(toProgress: 0.5)
            XCTAssertNotNil(playerView.currentFrame, fixture)
            XCTAssertGreaterThanOrEqual(playerView.currentProgress, 0, fixture)
            XCTAssertLessThanOrEqual(playerView.currentProgress, 1, fixture)

            playerView.stop()
            XCTAssertEqual(playerView.playbackState, .ready, fixture)
            playerView.clear()
            XCTAssertEqual(playerView.playbackState, .idle, fixture)
            XCTAssertNil(playerView.video, fixture)
        }
    }
}
