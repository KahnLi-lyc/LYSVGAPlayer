import SwiftUI
import UIKit
import XCTest
@testable import LYSVGAPlayer

@MainActor
final class LYSVGASwiftUITests: XCTestCase {
    func testControllerOwnsOnePlayerAndMirrorsConfigurationAndFrameState() async throws {
        let controller = LYSVGAPlayerController()
        let player = controller.playerView

        controller.repeatMode = .count(2)
        controller.endBehavior = .holdStartFrame
        controller.playbackRate = 3
        controller.allowsFrameSkipping = false
        controller.isMuted = true
        controller.audioVolume = -1

        XCTAssertTrue(controller.playerView === player)
        XCTAssertEqual(player.repeatMode, .count(2))
        XCTAssertEqual(player.endBehavior, .holdStartFrame)
        XCTAssertEqual(player.playbackRate, 2)
        XCTAssertFalse(player.allowsFrameSkipping)
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.audioVolume, 0)

        try await controller.setVideo(try video())
        XCTAssertEqual(controller.playbackState, .ready)
        XCTAssertEqual(controller.currentFrame, 0)
        XCTAssertEqual(controller.currentProgress, 0)

        controller.seek(toProgress: 1)
        XCTAssertEqual(controller.currentFrame, 2)
        XCTAssertEqual(controller.currentProgress, 1)

        controller.clear()
        XCTAssertEqual(controller.playbackState, .idle)
        XCTAssertNil(controller.video)
        XCTAssertNil(controller.currentFrame)
        XCTAssertEqual(controller.currentProgress, 0)
    }

    func testControllerForwardsDelegateEventsAndPublishesErrors() {
        let controller = LYSVGAPlayerController()
        let spy = SwiftUIDelegateSpy()
        controller.delegate = spy
        let error = LYSVGAError.invalidPlaybackConfiguration("test")

        controller.playerView(controller.playerView, didChangePlaybackState: .failed)
        controller.playerView(controller.playerView, didDisplayFrame: 4, progress: 0.5)
        controller.playerView(controller.playerView, didCrossLoops: 2)
        controller.playerViewDidFinish(controller.playerView)
        controller.playerView(controller.playerView, didFailWith: error)

        XCTAssertEqual(controller.playbackState, .failed)
        XCTAssertEqual(controller.currentFrame, 4)
        XCTAssertEqual(controller.currentProgress, 0.5)
        XCTAssertEqual(controller.lastError, error)
        XCTAssertEqual(spy.states, [.failed])
        XCTAssertEqual(spy.frames, [4])
        XCTAssertEqual(spy.loopCounts, [2])
        XCTAssertEqual(spy.finishCount, 1)
        XCTAssertEqual(spy.errors, [error])
    }

    func testRepresentableEmbedsControllersUniquePlayerAndAppliesUIKitLayoutOptions() async {
        let controller = LYSVGAPlayerController()
        let hostingController = UIHostingController(rootView: LYSVGAView(
            controller: controller,
            contentMode: .bottomRight,
            clipsToBounds: true
        ))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        window.rootViewController = hostingController
        window.makeKeyAndVisible()

        hostingController.loadViewIfNeeded()
        hostingController.view.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        hostingController.view.layoutIfNeeded()
        for _ in 0..<5 {
            await Task.yield()
            hostingController.view.layoutIfNeeded()
        }

        let embedded = hostingController.view.firstDescendant(of: LYSVGAPlayerView.self)
        XCTAssertTrue(embedded === controller.playerView)
        XCTAssertEqual(embedded?.contentMode, .bottomRight)
        XCTAssertEqual(embedded?.clipsToBounds, true)
    }

    private func video() throws -> LYSVGAVideo {
        let frames = (0..<3).map { index in
            LYSVGAFrame(
                alpha: 1,
                layout: LYSVGARect(x: Double(index), y: 0, width: 10, height: 10),
                transform: .identity
            )
        }
        return try LYSVGAVideo(
            version: "swiftui",
            canvasSize: LYSVGASize(width: 10, height: 10),
            fps: 20,
            frameCount: 3,
            images: [:],
            audioData: [:],
            sprites: [LYSVGASprite(imageKey: "shape.vector", frames: frames)],
            audios: []
        )
    }
}

@MainActor
private final class SwiftUIDelegateSpy: LYSVGAPlayerViewDelegate {
    var states: [LYSVGAPlaybackState] = []
    var frames: [Int] = []
    var loopCounts: [UInt] = []
    var finishCount = 0
    var errors: [LYSVGAError] = []

    func playerView(_ playerView: LYSVGAPlayerView, didChangePlaybackState state: LYSVGAPlaybackState) {
        states.append(state)
    }

    func playerView(_ playerView: LYSVGAPlayerView, didDisplayFrame frame: Int, progress: Double) {
        frames.append(frame)
    }

    func playerView(_ playerView: LYSVGAPlayerView, didCrossLoops count: UInt) {
        loopCounts.append(count)
    }

    func playerViewDidFinish(_ playerView: LYSVGAPlayerView) {
        finishCount += 1
    }

    func playerView(_ playerView: LYSVGAPlayerView, didFailWith error: LYSVGAError) {
        errors.append(error)
    }
}

private extension UIView {
    func firstDescendant<T: UIView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let match = subview.firstDescendant(of: type) { return match }
        }
        return nil
    }
}
