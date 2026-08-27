import UIKit
import XCTest
@testable import LYSVGAPlayer

@MainActor
final class LYSVGAPlayerViewPreparationTests: XCTestCase {
    func testLastRequestWinsWhenOlderPreparationFinishesLast() async throws {
        let oldStarted = expectation(description: "old preparation started")
        var resumeOld: CheckedContinuation<Void, Never>?
        var candidateCount = 0
        let view = LYSVGAPlayerView(
            candidateFactory: {
                candidateCount += 1
                return LYSVGAPlayerPreparationCandidate(
                    renderer: LYSVGARenderer(),
                    audioScheduler: LYSVGAAudioScheduler()
                )
            },
            preparationHook: { video in
                guard video.version == "old" else { return }
                oldStarted.fulfill()
                await withCheckedContinuation { resumeOld = $0 }
            }
        )
        let oldVideo = try preparationVideo(version: "old")
        let newVideo = try preparationVideo(version: "new")

        let oldTask = Task { try await view.setVideo(oldVideo) }
        await fulfillment(of: [oldStarted])
        try await view.setVideo(newVideo)
        let installedLayer = view.rendererRootLayerForTesting
        resumeOld?.resume()

        do {
            try await oldTask.value
            XCTFail("The stale request must be cancelled.")
        } catch {
            XCTAssertEqual(error as? LYSVGAError, .cancelled)
        }

        XCTAssertEqual(candidateCount, 2)
        XCTAssertEqual(view.video, newVideo)
        XCTAssertEqual(view.playbackState, .ready)
        XCTAssertTrue(view.rendererRootLayerForTesting === installedLayer)
    }

    func testSeekDuringLoadingDoesNotReplaceLoadingStateOrInstalledFrame() async throws {
        let loadingStarted = expectation(description: "loading preparation started")
        var resumeLoading: CheckedContinuation<Void, Never>?
        let view = LYSVGAPlayerView(preparationHook: { video in
            guard video.version == "loading" else { return }
            loadingStarted.fulfill()
            await withCheckedContinuation { resumeLoading = $0 }
        })
        try await view.setVideo(try preparationVideo(version: "installed"))
        view.seek(toFrame: 1)
        let loadingTask = Task { try await view.setVideo(try preparationVideo(version: "loading")) }
        await fulfillment(of: [loadingStarted])
        XCTAssertEqual(view.playbackState, .loading)

        view.seek(toFrame: 2)
        view.seek(toProgress: 1)

        XCTAssertEqual(view.playbackState, .loading)
        XCTAssertEqual(view.currentFrame, 1)

        resumeLoading?.resume()
        try await loadingTask.value
        XCTAssertEqual(view.playbackState, .ready)
    }

    func testAudioPreparationFailureKeepsPreviousInstallationAtomicAndEntersFailed() async throws {
        let failingFactory = FailingPreparationAudioFactory()
        var candidateIndex = 0
        let view = LYSVGAPlayerView(candidateFactory: {
            defer { candidateIndex += 1 }
            let scheduler = candidateIndex == 0
                ? LYSVGAAudioScheduler()
                : LYSVGAAudioScheduler(factory: failingFactory)
            return LYSVGAPlayerPreparationCandidate(renderer: LYSVGARenderer(), audioScheduler: scheduler)
        })
        let installedVideo = try preparationVideo(version: "installed")
        try await view.setVideo(installedVideo)
        let installedLayer = view.rendererRootLayerForTesting

        do {
            try await view.setVideo(try preparationAudioVideo(version: "failing"))
            XCTFail("Audio preparation must fail.")
        } catch {
            guard case .audioPreparationFailure = error as? LYSVGAError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(view.playbackState, .failed)
        XCTAssertEqual(view.video, installedVideo)
        XCTAssertEqual(view.currentFrame, 0)
        XCTAssertTrue(view.rendererRootLayerForTesting === installedLayer)
        XCTAssertTrue(installedLayer?.superlayer === view.layer)
        XCTAssertGreaterThan(failingFactory.player.stopCount, 0)
    }

    func testLoadReportsCurrentGenerationPreparationFailureOnce() async throws {
        let failingFactory = FailingPreparationAudioFactory()
        let video = try preparationAudioVideo(version: "load-failing")
        let loader = LYSVGAAssetLoader(
            session: .shared,
            cacheConfiguration: .init(directory: TestSupport.temporaryDirectory()),
            reader: { _, _ in Data([1]) },
            decoder: { _ in video }
        )
        let delegate = PreparationDelegateSpy()
        let view = LYSVGAPlayerView(candidateFactory: {
            LYSVGAPlayerPreparationCandidate(
                renderer: LYSVGARenderer(),
                audioScheduler: LYSVGAAudioScheduler(factory: failingFactory)
            )
        })
        view.delegate = delegate

        do {
            try await view.load(.data(Data([1])), using: loader, cachePolicy: .noCache)
            XCTFail("Audio preparation must fail.")
        } catch {
            guard case .audioPreparationFailure = error as? LYSVGAError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(delegate.failureCount, 1)
        XCTAssertEqual(view.playbackState, .failed)
    }

    func testClearFromFailedStateCallbackPreventsStaleFailureCallback() async throws {
        let failingFactory = FailingPreparationAudioFactory()
        let delegate = PreparationDelegateSpy()
        let view = LYSVGAPlayerView(candidateFactory: {
            LYSVGAPlayerPreparationCandidate(
                renderer: LYSVGARenderer(),
                audioScheduler: LYSVGAAudioScheduler(factory: failingFactory)
            )
        })
        delegate.onState = { playerView, state in
            guard state == .failed else { return }
            delegate.onState = nil
            playerView.clear()
        }
        view.delegate = delegate

        do {
            try await view.setVideo(try preparationAudioVideo(version: "reentrant-failure"))
            XCTFail("Audio preparation must fail.")
        } catch {
            XCTAssertEqual(error as? LYSVGAError, .cancelled)
        }

        XCTAssertEqual(view.playbackState, .idle)
        XCTAssertNil(view.video)
        XCTAssertEqual(delegate.failureCount, 0)
    }

    func testCurrentRequestTaskCancellationReportsCancelledOnceAndFails() async throws {
        let preparationStarted = expectation(description: "preparation started")
        let delegate = PreparationDelegateSpy()
        let view = LYSVGAPlayerView(preparationHook: { _ in
            preparationStarted.fulfill()
            try await Task.sleep(for: .seconds(10))
        })
        view.delegate = delegate
        let task = Task { try await view.setVideo(try preparationVideo(version: "cancelled")) }
        await fulfillment(of: [preparationStarted])

        task.cancel()

        do {
            try await task.value
            XCTFail("Cancelled preparation must throw.")
        } catch {
            XCTAssertEqual(error as? LYSVGAError, .cancelled)
        }
        XCTAssertEqual(view.playbackState, .failed)
        XCTAssertEqual(delegate.failureCount, 1)
    }

    func testLoadAutoplayInstallsVideoAndStartsPlayback() async throws {
        let video = try preparationVideo(version: "autoplay")
        let loader = LYSVGAAssetLoader(
            session: .shared,
            cacheConfiguration: .init(directory: TestSupport.temporaryDirectory()),
            reader: { _, _ in Data([1]) },
            decoder: { _ in video }
        )
        let view = LYSVGAPlayerView()

        try await view.load(.data(Data([1])), using: loader, cachePolicy: .noCache, autoplay: true)

        XCTAssertEqual(view.video, video)
        XCTAssertEqual(view.playbackState, .playing)
        XCTAssertEqual(view.currentFrame, 0)
    }

    func testPreparationAppliesLatestRuntimePropertiesToAudioAndAutoplayTimeline() async throws {
        let preparationStarted = expectation(description: "preparation started")
        var resumePreparation: CheckedContinuation<Void, Never>?
        let clock = PreparationTestClock()
        let audioFactory = PreparationTrackingAudioFactory()
        let video = try preparationAudioVideo(version: "latest-properties", frameCount: 10)
        let loader = LYSVGAAssetLoader(
            session: .shared,
            cacheConfiguration: .init(directory: TestSupport.temporaryDirectory()),
            reader: { _, _ in Data([1]) },
            decoder: { _ in video }
        )
        let view = LYSVGAPlayerView(
            clockFactory: { _ in clock },
            candidateFactory: {
                LYSVGAPlayerPreparationCandidate(
                    renderer: LYSVGARenderer(),
                    audioScheduler: LYSVGAAudioScheduler(factory: audioFactory)
                )
            },
            preparationHook: { _ in
                preparationStarted.fulfill()
                await withCheckedContinuation { resumePreparation = $0 }
            }
        )
        let loadTask = Task {
            try await view.load(.data(Data([1])), using: loader, cachePolicy: .noCache, autoplay: true)
        }
        await fulfillment(of: [preparationStarted])

        view.playbackRate = 1.75
        view.audioVolume = 0.4
        view.isMuted = true
        resumePreparation?.resume()
        try await loadTask.value

        XCTAssertEqual(audioFactory.player.rate, 1.75)
        XCTAssertEqual(audioFactory.player.volume, 0)
        view.tickForTesting(at: 10)
        view.tickForTesting(at: 10.2)
        XCTAssertEqual(view.currentFrame, 3)

        view.isMuted = false
        XCTAssertEqual(audioFactory.player.volume, 0.4, accuracy: 0.000_001)
    }

    func testAutoplayDuringMultipleApplicationInterruptionsWaitsUntilAllReasonsClear() async throws {
        let preparationStarted = expectation(description: "preparation started")
        var resumePreparation: CheckedContinuation<Void, Never>?
        let center = NotificationCenter()
        let clock = PreparationTestClock()
        let audioFactory = PreparationTrackingAudioFactory()
        let video = try preparationAudioVideo(version: "interrupted-autoplay", frameCount: 10)
        let loader = LYSVGAAssetLoader(
            session: .shared,
            cacheConfiguration: .init(directory: TestSupport.temporaryDirectory()),
            reader: { _, _ in Data([1]) },
            decoder: { _ in video }
        )
        let view = LYSVGAPlayerView(
            clockFactory: { _ in clock },
            candidateFactory: {
                LYSVGAPlayerPreparationCandidate(
                    renderer: LYSVGARenderer(),
                    audioScheduler: LYSVGAAudioScheduler(factory: audioFactory)
                )
            },
            preparationHook: { _ in
                preparationStarted.fulfill()
                await withCheckedContinuation { resumePreparation = $0 }
            },
            notificationCenter: center
        )
        let loadTask = Task {
            try await view.load(.data(Data([1])), using: loader, cachePolicy: .noCache, autoplay: true)
        }
        await fulfillment(of: [preparationStarted])
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        resumePreparation?.resume()

        try await loadTask.value

        XCTAssertEqual(view.playbackState, .paused)
        XCTAssertEqual(view.currentFrame, 0)
        XCTAssertFalse(clock.isRunning)
        XCTAssertEqual(audioFactory.player.playCount, 0)

        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(view.playbackState, .paused)
        XCTAssertFalse(clock.isRunning)
        XCTAssertEqual(audioFactory.player.playCount, 0)

        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(view.playbackState, .playing)
        XCTAssertTrue(clock.isRunning)
        XCTAssertEqual(audioFactory.player.playCount, 1)
    }

    func testInvalidAutoplayConfigurationDoesNotPartiallyReplaceInstalledVideo() async throws {
        let installedVideo = try preparationVideo(version: "installed-before-autoplay")
        let autoplayVideo = try preparationVideo(version: "invalid-autoplay")
        let loader = LYSVGAAssetLoader(
            session: .shared,
            cacheConfiguration: .init(directory: TestSupport.temporaryDirectory()),
            reader: { _, _ in Data([1]) },
            decoder: { _ in autoplayVideo }
        )
        let view = LYSVGAPlayerView()
        try await view.setVideo(installedVideo)
        let installedLayer = view.rendererRootLayerForTesting
        view.repeatMode = .count(0)

        do {
            try await view.load(.data(Data([1])), using: loader, cachePolicy: .noCache, autoplay: true)
            XCTFail("Invalid autoplay configuration must fail.")
        } catch {
            guard case .invalidPlaybackConfiguration = error as? LYSVGAError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(view.playbackState, .failed)
        XCTAssertEqual(view.video, installedVideo)
        XCTAssertTrue(view.rendererRootLayerForTesting === installedLayer)
        XCTAssertTrue(installedLayer?.superlayer === view.layer)
    }
}

@MainActor
private final class PreparationDelegateSpy: LYSVGAPlayerViewDelegate {
    private(set) var failureCount = 0
    var onState: ((LYSVGAPlayerView, LYSVGAPlaybackState) -> Void)?

    func playerView(_ playerView: LYSVGAPlayerView, didChangePlaybackState state: LYSVGAPlaybackState) {
        onState?(playerView, state)
    }

    func playerView(_ playerView: LYSVGAPlayerView, didFailWith error: LYSVGAError) {
        failureCount += 1
    }
}

@MainActor
private final class FailingPreparationAudioFactory: LYSVGAAudioPlayerFactory {
    let player = FailingPreparationAudioPlayer()

    func makePlayer(data: Data) throws -> any LYSVGAAudioPlaying {
        player
    }
}

@MainActor
private final class FailingPreparationAudioPlayer: LYSVGAAudioPlaying {
    let duration: TimeInterval = 1
    var currentTime: TimeInterval = 0
    var volume: Float = 1
    var rate: Float = 1
    var enableRate = false
    var isPlaying = false
    private(set) var stopCount = 0

    func prepareToPlay() -> Bool { false }
    func play() -> Bool { false }
    func pause() {}
    func stop() { stopCount += 1 }
}

@MainActor
private final class PreparationTrackingAudioFactory: LYSVGAAudioPlayerFactory {
    let player = PreparationTrackingAudioPlayer()

    func makePlayer(data: Data) throws -> any LYSVGAAudioPlaying {
        player
    }
}

@MainActor
private final class PreparationTrackingAudioPlayer: LYSVGAAudioPlaying {
    let duration: TimeInterval = 10
    var currentTime: TimeInterval = 0
    var volume: Float = 1
    var rate: Float = 1
    var enableRate = false
    private(set) var isPlaying = false
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
        isPlaying = false
    }
}

@MainActor
private final class PreparationTestClock: LYSVGADisplayClock {
    var timestamp: TimeInterval = 0
    private(set) var isRunning = false
    private(set) var isInvalidated = false

    func start() {
        isRunning = true
    }

    func pause() {
        isRunning = false
    }

    func invalidate() {
        isRunning = false
        isInvalidated = true
    }
}

private func preparationVideo(version: String) throws -> LYSVGAVideo {
    try LYSVGAVideo(
        version: version,
        canvasSize: LYSVGASize(width: 100, height: 100),
        fps: 10,
        frameCount: 3,
        images: [:],
        audioData: [:],
        sprites: [],
        audios: []
    )
}

private func preparationAudioVideo(version: String, frameCount: Int = 3) throws -> LYSVGAVideo {
    try LYSVGAVideo(
        version: version,
        canvasSize: LYSVGASize(width: 100, height: 100),
        fps: 10,
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
