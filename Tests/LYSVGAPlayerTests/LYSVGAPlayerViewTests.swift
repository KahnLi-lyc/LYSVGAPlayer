import UIKit
import XCTest
@testable import LYSVGAPlayer

@MainActor
final class LYSVGAPlayerViewTests: XCTestCase {
    func testInitialStateAndInstallingVideoDisplaysFrameZero() async throws {
        let view = LYSVGAPlayerView(frame: CGRect(x: 0, y: 0, width: 120, height: 80))
        let video = try makePlayerVideo(fps: 10, frameCount: 4)

        XCTAssertEqual(view.playbackState, .idle)
        XCTAssertNil(view.video)
        XCTAssertNil(view.currentFrame)
        XCTAssertEqual(view.currentProgress, 0)
        XCTAssertFalse(view.isReversePlayback)

        try await view.setVideo(video)

        XCTAssertEqual(view.playbackState, .ready)
        XCTAssertEqual(view.video, video)
        XCTAssertEqual(view.currentFrame, 0)
        XCTAssertEqual(view.currentProgress, 0)
        XCTAssertTrue(view.layer.sublayers?.contains(where: { $0 === view.rendererRootLayerForTesting }) == true)
    }

    func testPlayStartsAtAbsoluteRangeBoundaryForEachDirection() async throws {
        let view = LYSVGAPlayerView()
        try await view.setVideo(try makePlayerVideo(fps: 10, frameCount: 6))

        try view.play(range: 2...4)

        XCTAssertEqual(view.playbackState, .playing)
        XCTAssertEqual(view.currentFrame, 2)
        XCTAssertEqual(view.currentProgress, 0.4, accuracy: 0.000_001)
        XCTAssertFalse(view.isReversePlayback)

        try view.play(range: 2...4, reverse: true)

        XCTAssertEqual(view.currentFrame, 4)
        XCTAssertEqual(view.currentProgress, 0.8, accuracy: 0.000_001)
        XCTAssertTrue(view.isReversePlayback)
    }

    func testPlayRejectsMissingVideoOutOfBoundsRangeAndZeroRepeatCount() async throws {
        let view = LYSVGAPlayerView()

        XCTAssertThrowsError(try view.play()) { error in
            guard case .invalidPlaybackConfiguration = error as? LYSVGAError else {
                return XCTFail("Expected invalid playback configuration, got \(error)")
            }
        }

        try await view.setVideo(try makePlayerVideo(fps: 10, frameCount: 4))
        XCTAssertThrowsError(try view.play(range: -1...2)) { error in
            guard case .invalidPlaybackConfiguration = error as? LYSVGAError else {
                return XCTFail("Expected invalid playback configuration, got \(error)")
            }
        }

        view.repeatMode = .count(0)
        XCTAssertThrowsError(try view.play()) { error in
            guard case .invalidPlaybackConfiguration = error as? LYSVGAError else {
                return XCTFail("Expected invalid playback configuration, got \(error)")
            }
        }
    }

    func testTimestampTicksReportFramesCrossedLoopsAndFinishOnce() async throws {
        let view = LYSVGAPlayerView()
        let delegate = PlayerViewDelegateSpy()
        view.delegate = delegate
        view.repeatMode = .count(2)
        try await view.setVideo(try makePlayerVideo(fps: 2, frameCount: 4))
        try view.play(range: 1...2)

        view.tickForTesting(at: 10)
        view.tickForTesting(at: 10.5)
        view.tickForTesting(at: 11)
        view.tickForTesting(at: 11.5)
        view.tickForTesting(at: 12)
        view.tickForTesting(at: 13)

        XCTAssertEqual(delegate.frames.map(\.frame), [0, 1, 2, 1, 2, 2])
        XCTAssertEqual(delegate.frames.map(\.progress), [0, 1.0 / 3.0, 2.0 / 3.0, 1.0 / 3.0, 2.0 / 3.0, 2.0 / 3.0])
        XCTAssertEqual(delegate.loopCrossings, [1])
        XCTAssertEqual(delegate.finishCount, 1)
        XCTAssertEqual(view.playbackState, .finished)
        XCTAssertEqual(view.currentFrame, 2)
    }

    func testPauseSettlesCurrentTimestampAndResumeUsesFreshBaseline() async throws {
        let clock = PlayerViewTestClock()
        let view = LYSVGAPlayerView(clockFactory: { _ in clock })
        try await view.setVideo(try makePlayerVideo(fps: 10, frameCount: 10))
        try view.play()
        clock.timestamp = 100
        view.tickForTesting(at: 100)
        clock.timestamp = 100.2

        view.pause()

        XCTAssertEqual(view.playbackState, .paused)
        XCTAssertEqual(view.currentFrame, 2)

        clock.timestamp = 200
        view.resume()
        view.tickForTesting(at: 200.1)

        XCTAssertEqual(view.playbackState, .playing)
        XCTAssertEqual(view.currentFrame, 3)
    }

    func testEndBehaviorsUseAbsolutePlaybackRangeForStop() async throws {
        let video = try makePlayerVideo(fps: 10, frameCount: 6)

        for (behavior, expectedFrame) in [
            (LYSVGAEndBehavior.clear, nil),
            (.holdStartFrame, 2),
            (.holdEndFrame, 4),
        ] {
            let view = LYSVGAPlayerView()
            view.endBehavior = behavior
            try await view.setVideo(video)
            try view.play(range: 2...4, reverse: true)

            view.stop()

            XCTAssertEqual(view.playbackState, .ready)
            XCTAssertEqual(view.currentFrame, expectedFrame)
            XCTAssertEqual(view.video, video)
        }
    }

    func testNaturalFinishAppliesEachEndBehaviorUsingAbsoluteRange() async throws {
        let video = try makePlayerVideo(fps: 10, frameCount: 6)

        for (behavior, expectedFrame) in [
            (LYSVGAEndBehavior.clear, nil),
            (.holdStartFrame, 2),
            (.holdEndFrame, 4),
        ] {
            let view = LYSVGAPlayerView()
            view.endBehavior = behavior
            try await view.setVideo(video)
            try view.play(range: 2...4, reverse: true)
            view.tickForTesting(at: 10)
            view.tickForTesting(at: 10.3)

            XCTAssertEqual(view.playbackState, .finished)
            XCTAssertEqual(view.currentFrame, expectedFrame)
        }
    }

    func testSeekClampsToPlaybackRangeAndAndPlayContinuesFromSeekFrame() async throws {
        let clock = PlayerViewTestClock()
        let view = LYSVGAPlayerView(clockFactory: { _ in clock })
        try await view.setVideo(try makePlayerVideo(fps: 10, frameCount: 10))
        try view.play(range: 2...8)
        view.tickForTesting(at: 100)
        view.pause()
        let startsBeforeSeek = clock.startCount

        view.seek(toFrame: -10)

        XCTAssertEqual(view.currentFrame, 2)
        XCTAssertEqual(view.playbackState, .paused)
        XCTAssertEqual(clock.startCount, startsBeforeSeek)

        clock.timestamp = 200
        view.seek(toProgress: 0.5, andPlay: true)
        XCTAssertEqual(view.currentFrame, 5)
        XCTAssertEqual(view.playbackState, .playing)

        view.tickForTesting(at: 200)
        view.tickForTesting(at: 200.1)

        XCTAssertEqual(view.currentFrame, 6)
    }

    func testSeekWithoutAndPlayPausesActivePlaybackAtTargetFrame() async throws {
        let clock = PlayerViewTestClock()
        let audioFactory = PlayerViewAudioFactory()
        let view = LYSVGAPlayerView(
            clockFactory: { _ in clock },
            candidateFactory: {
                LYSVGAPlayerPreparationCandidate(
                    renderer: LYSVGARenderer(),
                    audioScheduler: LYSVGAAudioScheduler(factory: audioFactory)
                )
            }
        )
        try await view.setVideo(try makePlayerVideoWithAudio(fps: 10, frameCount: 10))
        try view.play(range: 2...8)
        view.tickForTesting(at: 10)
        let playCountBeforeSeek = audioFactory.player.playCount

        view.seek(toFrame: 6)

        XCTAssertEqual(view.currentFrame, 6)
        XCTAssertEqual(view.playbackState, .paused)
        XCTAssertFalse(clock.isRunning)
        XCTAssertEqual(audioFactory.player.playCount, playCountBeforeSeek)
        view.tickForTesting(at: 20)
        XCTAssertEqual(view.currentFrame, 6)
    }

    func testSeekWithoutAndPlayFromReadyPausesWithoutStartingAudioAndResumeContinuesTargetCue() async throws {
        let clock = PlayerViewTestClock()
        let audioFactory = PlayerViewAudioFactory()
        let view = LYSVGAPlayerView(
            clockFactory: { _ in clock },
            candidateFactory: {
                LYSVGAPlayerPreparationCandidate(
                    renderer: LYSVGARenderer(),
                    audioScheduler: LYSVGAAudioScheduler(factory: audioFactory)
                )
            }
        )
        try await view.setVideo(try makePlayerVideoWithAudio(fps: 10, frameCount: 10))
        clock.timestamp = 100

        view.seek(toFrame: 5)

        XCTAssertEqual(view.playbackState, .paused)
        XCTAssertEqual(view.currentFrame, 5)
        XCTAssertFalse(clock.isRunning)
        XCTAssertEqual(audioFactory.player.playCount, 0)
        XCTAssertFalse(audioFactory.player.isPlaying)
        XCTAssertEqual(audioFactory.player.currentTime, 0.5, accuracy: 0.000_001)

        view.resume()
        view.tickForTesting(at: 100.1)

        XCTAssertEqual(view.playbackState, .playing)
        XCTAssertEqual(view.currentFrame, 6)
        XCTAssertEqual(audioFactory.player.playCount, 1)
    }

    func testSeekWithoutAndPlayFromFinishedPausesAndResumeContinuesFromProgressFrame() async throws {
        let clock = PlayerViewTestClock()
        let view = LYSVGAPlayerView(clockFactory: { _ in clock })
        try await view.setVideo(try makePlayerVideo(fps: 10, frameCount: 10))
        try view.play()
        view.tickForTesting(at: 10)
        view.tickForTesting(at: 11)
        XCTAssertEqual(view.playbackState, .finished)

        clock.timestamp = 20
        view.seek(toProgress: 0.5)

        XCTAssertEqual(view.playbackState, .paused)
        XCTAssertEqual(view.currentFrame, 5)
        XCTAssertFalse(clock.isRunning)

        view.resume()
        view.tickForTesting(at: 20.1)
        XCTAssertEqual(view.currentFrame, 6)
    }

    func testExplicitPlayWhilePausedRestartsAudioScheduler() async throws {
        let audioFactory = PlayerViewAudioFactory()
        let view = LYSVGAPlayerView(candidateFactory: {
            LYSVGAPlayerPreparationCandidate(
                renderer: LYSVGARenderer(),
                audioScheduler: LYSVGAAudioScheduler(factory: audioFactory)
            )
        })
        try await view.setVideo(try makePlayerVideoWithAudio(fps: 10, frameCount: 4))
        try view.play()
        view.pause()
        let playCountAfterPause = audioFactory.player.playCount

        try view.play()

        XCTAssertEqual(view.playbackState, .playing)
        XCTAssertEqual(audioFactory.player.playCount, playCountAfterPause + 1)
        XCTAssertTrue(audioFactory.player.isPlaying)
    }

    func testProgressSeekHandlesMaximumFrameCountWithoutIntegerConversionOverflow() async throws {
        let view = LYSVGAPlayerView()
        try await view.setVideo(try makePlayerVideo(fps: 10, frameCount: Int.max))

        view.seek(toProgress: 1)
        XCTAssertEqual(view.currentFrame, Int.max - 1)

        view.seek(toProgress: 0)
        XCTAssertEqual(view.currentFrame, 0)
    }

    func testRuntimePropertiesClampAndUpdateActiveTimelineAndAudio() async throws {
        let clock = PlayerViewTestClock()
        let audioFactory = PlayerViewAudioFactory()
        let view = LYSVGAPlayerView(
            clockFactory: { _ in clock },
            candidateFactory: {
                LYSVGAPlayerPreparationCandidate(
                    renderer: LYSVGARenderer(),
                    audioScheduler: LYSVGAAudioScheduler(factory: audioFactory)
                )
            }
        )
        try await view.setVideo(try makePlayerVideoWithAudio(fps: 10, frameCount: 10))

        view.playbackRate = 100
        view.audioVolume = -5
        XCTAssertEqual(view.playbackRate, 2)
        XCTAssertEqual(view.audioVolume, 0)
        XCTAssertEqual(audioFactory.player.rate, 2)
        XCTAssertEqual(audioFactory.player.volume, 0)

        view.audioVolume = 0.75
        view.isMuted = true
        XCTAssertEqual(audioFactory.player.volume, 0)
        view.isMuted = false
        XCTAssertEqual(audioFactory.player.volume, 0.75)

        try view.play()
        clock.timestamp = 10
        view.tickForTesting(at: 10)
        clock.timestamp = 10.1
        view.playbackRate = 0.5
        XCTAssertEqual(view.currentFrame, 2)
        XCTAssertEqual(audioFactory.player.rate, 0.5)

        view.allowsFrameSkipping = false
        view.tickForTesting(at: 11)
        XCTAssertEqual(view.currentFrame, 3)
    }

    func testPlaybackRateChangeWhileReadyDoesNotAdvanceStoppedTimeline() async throws {
        let clock = PlayerViewTestClock()
        let view = LYSVGAPlayerView(clockFactory: { _ in clock })
        view.endBehavior = .holdStartFrame
        try await view.setVideo(try makePlayerVideo(fps: 10, frameCount: 10))
        try view.play()
        clock.timestamp = 10
        view.tickForTesting(at: 10)
        view.stop()
        XCTAssertEqual(view.currentFrame, 0)

        clock.timestamp = 100
        view.playbackRate = 0.75

        XCTAssertEqual(view.playbackState, .ready)
        XCTAssertEqual(view.currentFrame, 0)
    }

    func testLayoutReusesRendererLayerAndAppliesViewLayoutProperties() async throws {
        let view = LYSVGAPlayerView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        try await view.setVideo(try makePlayerVideo(fps: 10, frameCount: 4))
        let rootLayer = try XCTUnwrap(view.rendererRootLayerForTesting)
        let canvasLayer = try XCTUnwrap(rootLayer.sublayers?.first)

        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.bounds = CGRect(x: 0, y: 0, width: 300, height: 120)
        view.layoutIfNeeded()
        view.layoutSubviews()

        XCTAssertTrue(view.rendererRootLayerForTesting === rootLayer)
        XCTAssertTrue(rootLayer.sublayers?.first === canvasLayer)
        XCTAssertEqual(rootLayer.frame, view.bounds)
        XCTAssertTrue(rootLayer.masksToBounds)
    }

    func testContentModeAndClippingChangesTriggerRelayoutWithoutBoundsChange() async throws {
        let view = LYSVGAPlayerView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        try await view.setVideo(try makePlayerVideo(fps: 10, frameCount: 4))
        let rootLayer = try XCTUnwrap(view.rendererRootLayerForTesting)
        let canvasLayer = try XCTUnwrap(rootLayer.sublayers?.first)
        let fillTransform = canvasLayer.affineTransform()

        view.contentMode = .center
        view.layoutIfNeeded()

        XCTAssertNotEqual(canvasLayer.affineTransform(), fillTransform)

        view.clipsToBounds = true
        view.layoutIfNeeded()

        XCTAssertTrue(rootLayer.masksToBounds)
    }

    func testApplicationInterruptionsResumeOnlyAfterAllReasonsClear() async throws {
        let center = NotificationCenter()
        let view = LYSVGAPlayerView(notificationCenter: center)
        try await view.setVideo(try makePlayerVideo(fps: 10, frameCount: 4))
        try view.play()

        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertEqual(view.playbackState, .paused)

        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(view.playbackState, .paused)

        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(view.playbackState, .playing)
    }

    func testApplicationAndWindowInterruptionsResumeOnlyAfterReattachment() async throws {
        let center = NotificationCenter()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let container = UIView(frame: window.bounds)
        let view = LYSVGAPlayerView(notificationCenter: center)
        window.addSubview(container)
        container.addSubview(view)
        try await view.setVideo(try makePlayerVideo(fps: 10, frameCount: 4))
        try view.play()

        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertEqual(view.playbackState, .paused)
        view.removeFromSuperview()
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(view.playbackState, .paused)

        container.addSubview(view)
        XCTAssertEqual(view.playbackState, .playing)
    }

    func testPauseAndResumeAreIdempotent() async throws {
        let clock = PlayerViewTestClock()
        let view = LYSVGAPlayerView(clockFactory: { _ in clock })
        try await view.setVideo(try makePlayerVideo(fps: 10, frameCount: 4))
        try view.play()

        view.pause()
        view.pause()
        XCTAssertEqual(clock.pauseCount, 1)

        view.resume()
        view.resume()
        XCTAssertEqual(clock.startCount, 2)
        XCTAssertEqual(view.playbackState, .playing)
    }

    func testUserPauseCancelsAutomaticResumeIntent() async throws {
        let center = NotificationCenter()
        let view = LYSVGAPlayerView(notificationCenter: center)
        try await view.setVideo(try makePlayerVideo(fps: 10, frameCount: 4))
        try view.play()
        center.post(name: UIApplication.willResignActiveNotification, object: nil)

        view.pause()
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(view.playbackState, .paused)
    }

    func testStopCancelsAutomaticResumeIntent() async throws {
        let center = NotificationCenter()
        let view = LYSVGAPlayerView(notificationCenter: center)
        try await view.setVideo(try makePlayerVideo(fps: 10, frameCount: 4))
        try view.play()
        center.post(name: UIApplication.willResignActiveNotification, object: nil)

        view.stop()
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(view.playbackState, .ready)
    }

    func testWindowRemovalPausesAndReattachmentResumesOnlyPlayingView() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let container = UIView(frame: window.bounds)
        let view = LYSVGAPlayerView(frame: container.bounds)
        window.addSubview(container)
        container.addSubview(view)
        try await view.setVideo(try makePlayerVideo(fps: 10, frameCount: 4))
        try view.play()

        view.removeFromSuperview()
        XCTAssertEqual(view.playbackState, .paused)

        container.addSubview(view)
        XCTAssertEqual(view.playbackState, .playing)

        view.pause()
        view.removeFromSuperview()
        container.addSubview(view)
        XCTAssertEqual(view.playbackState, .paused)
    }

    func testClearInvalidatesClockRemovesInstalledResourcesAndReturnsIdle() async throws {
        let clock = PlayerViewTestClock()
        weak var installedScheduler: LYSVGAAudioScheduler?
        let audioFactory = PlayerViewAudioFactory()
        let view = LYSVGAPlayerView(
            clockFactory: { _ in clock },
            candidateFactory: {
                let scheduler = LYSVGAAudioScheduler(factory: audioFactory)
                installedScheduler = scheduler
                return LYSVGAPlayerPreparationCandidate(renderer: LYSVGARenderer(), audioScheduler: scheduler)
            }
        )
        try await view.setVideo(try makePlayerVideoWithAudio(fps: 10, frameCount: 4))
        let rootLayer = try XCTUnwrap(view.rendererRootLayerForTesting)
        try view.play()

        view.clear()

        XCTAssertEqual(view.playbackState, .idle)
        XCTAssertNil(view.video)
        XCTAssertNil(view.currentFrame)
        XCTAssertNil(rootLayer.superlayer)
        XCTAssertTrue(clock.isInvalidated)
        XCTAssertNil(installedScheduler)
        XCTAssertGreaterThan(audioFactory.player.stopCount, 0)
    }

    func testDisplayLinkOwnershipDoesNotRetainPlayerView() async throws {
        weak var weakView: LYSVGAPlayerView?
        var view: LYSVGAPlayerView? = LYSVGAPlayerView()
        weakView = view
        try await view?.setVideo(try makePlayerVideo(fps: 10, frameCount: 4))
        try view?.play()

        view = nil
        await Task.yield()

        XCTAssertNil(weakView)
    }
}

@MainActor
private final class PlayerViewDelegateSpy: LYSVGAPlayerViewDelegate {
    var states: [LYSVGAPlaybackState] = []
    var frames: [(frame: Int, progress: Double)] = []
    var loopCrossings: [UInt] = []
    var finishCount = 0
    var errors: [LYSVGAError] = []

    func playerView(_ playerView: LYSVGAPlayerView, didChangePlaybackState state: LYSVGAPlaybackState) {
        states.append(state)
    }

    func playerView(_ playerView: LYSVGAPlayerView, didDisplayFrame frame: Int, progress: Double) {
        frames.append((frame, progress))
    }

    func playerView(_ playerView: LYSVGAPlayerView, didCrossLoops count: UInt) {
        loopCrossings.append(count)
    }

    func playerViewDidFinish(_ playerView: LYSVGAPlayerView) {
        finishCount += 1
    }

    func playerView(_ playerView: LYSVGAPlayerView, didFailWith error: LYSVGAError) {
        errors.append(error)
    }
}

@MainActor
private final class PlayerViewTestClock: LYSVGADisplayClock {
    var timestamp: TimeInterval = 0
    private(set) var isRunning = false
    private(set) var isInvalidated = false
    private(set) var startCount = 0
    private(set) var pauseCount = 0

    func start() {
        startCount += 1
        isRunning = true
    }

    func pause() {
        pauseCount += 1
        isRunning = false
    }

    func invalidate() {
        isRunning = false
        isInvalidated = true
    }
}

@MainActor
private final class PlayerViewAudioFactory: LYSVGAAudioPlayerFactory {
    let player = PlayerViewAudioPlayer()

    func makePlayer(data: Data) throws -> any LYSVGAAudioPlaying {
        player
    }
}

@MainActor
private final class PlayerViewAudioPlayer: LYSVGAAudioPlaying {
    let duration: TimeInterval = 10
    var currentTime: TimeInterval = 0
    var volume: Float = 1
    var rate: Float = 1
    var enableRate = false
    private(set) var isPlaying = false
    private(set) var stopCount = 0
    private(set) var playCount = 0

    func prepareToPlay() -> Bool { true }

    func play() -> Bool {
        playCount += 1
        isPlaying = true
        return true
    }

    func pause() {
        isPlaying = false
    }

    func stop() {
        stopCount += 1
        isPlaying = false
    }
}

private func makePlayerVideo(fps: Int, frameCount: Int) throws -> LYSVGAVideo {
    try LYSVGAVideo(
        version: "player-view-test",
        canvasSize: LYSVGASize(width: 100, height: 100),
        fps: fps,
        frameCount: frameCount,
        images: [:],
        audioData: [:],
        sprites: [],
        audios: []
    )
}

private func makePlayerVideoWithAudio(fps: Int, frameCount: Int) throws -> LYSVGAVideo {
    try LYSVGAVideo(
        version: "player-view-audio-test",
        canvasSize: LYSVGASize(width: 100, height: 100),
        fps: fps,
        frameCount: frameCount,
        images: [:],
        audioData: ["audio": Data([1])],
        sprites: [],
        audios: [LYSVGAAudioCue(
            audioKey: "audio",
            startFrame: 0,
            endFrame: frameCount,
            startTime: 0,
            totalTime: frameCount * 100
        )]
    )
}
