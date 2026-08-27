import XCTest
@testable import LYSVGAPlayer

final class LYSVGAPlaybackTimelineTests: XCTestCase {
    func testPublicPlaybackValuesAreEquatableAndSendable() {
        assertEquatableAndSendable(LYSVGARepeatMode.once)
        assertEquatableAndSendable(LYSVGARepeatMode.count(2))
        assertEquatableAndSendable(LYSVGARepeatMode.forever)
        assertEquatableAndSendable(LYSVGAEndBehavior.clear)
        assertEquatableAndSendable(LYSVGAEndBehavior.holdStartFrame)
        assertEquatableAndSendable(LYSVGAEndBehavior.holdEndFrame)
        assertEquatableAndSendable(LYSVGAPlaybackState.idle)
        assertEquatableAndSendable(LYSVGAPlaybackState.loading)
        assertEquatableAndSendable(LYSVGAPlaybackState.ready)
        assertEquatableAndSendable(LYSVGAPlaybackState.playing)
        assertEquatableAndSendable(LYSVGAPlaybackState.paused)
        assertEquatableAndSendable(LYSVGAPlaybackState.finished)
        assertEquatableAndSendable(LYSVGAPlaybackState.failed)
    }

    func testConfigurationValidatesFrameRangeAndRepeatCount() throws {
        XCTAssertThrowsError(try configuration(frameCount: 5, frameRange: -1...2)) {
            XCTAssertEqual($0 as? LYSVGAError, .invalidPlaybackConfiguration("Frame range must be within 0..<frameCount."))
        }
        XCTAssertThrowsError(try configuration(frameCount: 5, frameRange: 2...5)) {
            XCTAssertEqual($0 as? LYSVGAError, .invalidPlaybackConfiguration("Frame range must be within 0..<frameCount."))
        }
        XCTAssertThrowsError(try configuration(frameCount: 5, repeatMode: .count(0))) {
            XCTAssertEqual($0 as? LYSVGAError, .invalidPlaybackConfiguration("Repeat count must be greater than zero."))
        }

        XCTAssertEqual(try configuration(playbackRate: 0.1).playbackRate, 0.5)
        XCTAssertEqual(try configuration(playbackRate: 3).playbackRate, 2)
        XCTAssertEqual(LYSVGAPlaybackRate.clamped(.nan), 1)
    }

    func testTimestampStartsAtStartFrameAndSkippingCatchesUp() throws {
        var timeline = LYSVGATimeline(configuration: try configuration(fps: 10, frameCount: 10))

        XCTAssertEqual(timeline.tick(at: 100), .init(frame: 0))
        XCTAssertEqual(timeline.tick(at: 100.35), .init(frame: 3))
        XCTAssertEqual(timeline.tick(at: 101), .init(frame: 9, didFinish: true))
        XCTAssertEqual(timeline.tick(at: 102), .init(frame: 9))
    }

    func testNonFiniteFirstTickNeverPollutesBaseline() throws {
        for timestamp in [Double.nan, Double.infinity, -Double.infinity] {
            var timeline = LYSVGATimeline(configuration: try configuration(
                fps: 10,
                frameCount: 10,
                repeatMode: .forever
            ))

            XCTAssertEqual(timeline.tick(at: timestamp), .init(frame: 0))
            XCTAssertEqual(timeline.tick(at: 100), .init(frame: 0))
            XCTAssertEqual(timeline.tick(at: 100.1), .init(frame: 1))
        }
    }

    func testDisablingFrameSkippingAdvancesAtMostOneFramePerTick() throws {
        var timeline = LYSVGATimeline(configuration: try configuration(
            fps: 10,
            frameCount: 10,
            allowsFrameSkipping: false
        ))

        XCTAssertEqual(timeline.tick(at: 0).frame, 0)
        XCTAssertEqual(timeline.tick(at: 10).frame, 1)
        XCTAssertEqual(timeline.tick(at: 20).frame, 2)
    }

    func testRuntimeFrameSkippingUpdatePreservesTimelinePositionAndCatchesUp() throws {
        var timeline = LYSVGATimeline(configuration: try configuration(
            fps: 10,
            frameCount: 10,
            repeatMode: .forever,
            allowsFrameSkipping: false
        ))

        XCTAssertEqual(timeline.tick(at: 0).frame, 0)
        XCTAssertEqual(timeline.tick(at: 1).frame, 1)
        timeline.updateAllowsFrameSkipping(true)
        XCTAssertTrue(timeline.allowsFrameSkipping)
        XCTAssertEqual(timeline.tick(at: 1), .init(frame: 0, completedLoops: 1))
    }

    func testRuntimePlaybackRateSettlesOldRateThenResetsBaseline() throws {
        var timeline = LYSVGATimeline(configuration: try configuration(fps: 2, frameCount: 20))

        XCTAssertEqual(timeline.tick(at: 0).frame, 0)
        XCTAssertEqual(timeline.updatePlaybackRate(3, at: 1).frame, 2)
        XCTAssertEqual(timeline.playbackRate, 2)
        XCTAssertEqual(timeline.tick(at: 1.5).frame, 4)
    }

    func testPlaybackRateUpdateWhilePausedWaitsForResumeBaseline() throws {
        var timeline = LYSVGATimeline(configuration: try configuration(fps: 2, frameCount: 20))

        XCTAssertEqual(timeline.tick(at: 0).frame, 0)
        XCTAssertEqual(timeline.pause(at: 1).frame, 2)
        XCTAssertEqual(timeline.updatePlaybackRate(2, at: 100).frame, 2)
        XCTAssertEqual(timeline.tick(at: 200).frame, 2)
        timeline.resume(at: 200)
        XCTAssertEqual(timeline.tick(at: 200.5).frame, 4)
    }

    func testNonFiniteResumeClearsBaselineUntilNextFiniteTick() throws {
        var timeline = LYSVGATimeline(configuration: try configuration(
            fps: 10,
            frameCount: 10,
            repeatMode: .forever
        ))

        XCTAssertEqual(timeline.tick(at: 0).frame, 0)
        XCTAssertEqual(timeline.pause(at: 0.1).frame, 1)
        timeline.resume(at: .nan)
        XCTAssertEqual(timeline.tick(at: 100), .init(frame: 1))
        XCTAssertEqual(timeline.tick(at: 100.1), .init(frame: 2))
    }

    func testNonFiniteRateUpdateDoesNotAdvanceForeverTimelineOrStoreBaseline() throws {
        var timeline = LYSVGATimeline(configuration: try configuration(
            fps: 10,
            frameCount: 10,
            repeatMode: .forever
        ))

        XCTAssertEqual(timeline.tick(at: 0), .init(frame: 0))
        XCTAssertEqual(timeline.updatePlaybackRate(2, at: .infinity), .init(frame: 0))
        XCTAssertEqual(timeline.playbackRate, 2)
        XCTAssertEqual(timeline.tick(at: 100), .init(frame: 0))
        XCTAssertEqual(timeline.tick(at: 100.1), .init(frame: 2))
    }

    func testReverseRangeCountUsesAbsoluteProgressAndDoesNotRewindBeforeFinish() throws {
        var timeline = LYSVGATimeline(configuration: try configuration(
            fps: 1,
            frameCount: 8,
            frameRange: 2...4,
            reverse: true,
            repeatMode: .count(2)
        ))

        XCTAssertEqual(timeline.tick(at: 0), .init(frame: 4))
        XCTAssertEqual(timeline.currentProgress, 1)
        XCTAssertEqual(timeline.tick(at: 1), .init(frame: 3))
        XCTAssertEqual(timeline.tick(at: 2), .init(frame: 2))
        XCTAssertEqual(timeline.tick(at: 3), .init(frame: 4, completedLoops: 1))
        XCTAssertEqual(timeline.tick(at: 5), .init(frame: 2))
        XCTAssertEqual(timeline.tick(at: 6), .init(frame: 2, didFinish: true))
        XCTAssertEqual(timeline.currentProgress, 0)
    }

    func testHugeTimestampReportsAllLoopsForFiniteAndForeverPlayback() throws {
        var finite = LYSVGATimeline(configuration: try configuration(
            fps: 10,
            frameCount: 10,
            frameRange: 1...3,
            repeatMode: .count(3)
        ))
        XCTAssertEqual(finite.tick(at: 0).frame, 1)
        XCTAssertEqual(finite.tick(at: 1_000), .init(frame: 3, completedLoops: 2, didFinish: true))

        var forever = LYSVGATimeline(configuration: try configuration(
            fps: 10,
            frameCount: 10,
            frameRange: 1...3,
            repeatMode: .forever
        ))
        XCTAssertEqual(forever.tick(at: 0).frame, 1)
        XCTAssertEqual(forever.tick(at: 1_000), .init(frame: 2, completedLoops: 3_333))
    }

    func testSingleFrameRangeLoopsAndFinishesDeterministically() throws {
        var timeline = LYSVGATimeline(configuration: try configuration(
            fps: 2,
            frameCount: 5,
            frameRange: 3...3,
            repeatMode: .count(2)
        ))

        XCTAssertEqual(timeline.tick(at: 0), .init(frame: 3))
        XCTAssertEqual(timeline.tick(at: 0.5), .init(frame: 3, completedLoops: 1))
        XCTAssertEqual(timeline.tick(at: 1), .init(frame: 3, didFinish: true))
    }

    func testCountOneMatchesOnceCompletion() throws {
        var once = LYSVGATimeline(configuration: try configuration(fps: 2, frameCount: 2))
        var countOne = LYSVGATimeline(configuration: try configuration(
            fps: 2,
            frameCount: 2,
            repeatMode: .count(1)
        ))

        XCTAssertEqual(once.tick(at: 0), countOne.tick(at: 0))
        XCTAssertEqual(once.tick(at: 0.5), countOne.tick(at: 0.5))
        XCTAssertEqual(once.tick(at: 1), countOne.tick(at: 1))
    }

    func testPauseAndResumeExcludePausedTimeFromElapsedTime() throws {
        var timeline = LYSVGATimeline(configuration: try configuration(fps: 10, frameCount: 10))

        XCTAssertEqual(timeline.tick(at: 0).frame, 0)
        XCTAssertEqual(timeline.pause(at: 0.2).frame, 2)
        XCTAssertEqual(timeline.tick(at: 100).frame, 2)
        timeline.resume(at: 100)
        XCTAssertEqual(timeline.tick(at: 100.1).frame, 3)
    }

    func testSeekClampsFrameAndProgressAndResetsTimestampBaseline() throws {
        var timeline = LYSVGATimeline(configuration: try configuration(
            fps: 10,
            frameCount: 10,
            frameRange: 2...6,
            reverse: true
        ))

        timeline.seek(toFrame: 3)
        XCTAssertEqual(timeline.currentFrame, 3)
        XCTAssertEqual(timeline.currentProgress, 0.25)
        XCTAssertEqual(timeline.tick(at: 10).frame, 3)
        XCTAssertEqual(timeline.tick(at: 10.11).frame, 2)

        timeline.seek(toProgress: 0.5)
        XCTAssertEqual(timeline.currentFrame, 4)
        XCTAssertEqual(timeline.currentProgress, 0.5)
        XCTAssertEqual(timeline.tick(at: 20).frame, 4)

        timeline.seek(toProgress: -1)
        XCTAssertEqual(timeline.currentFrame, 2)
        timeline.seek(toProgress: 2)
        XCTAssertEqual(timeline.currentFrame, 6)
        timeline.seek(toFrame: 100)
        XCTAssertEqual(timeline.currentFrame, 6)
    }

    func testSeekProgressHandlesIntMaxFrameRangeWithoutConversionTrap() throws {
        var timeline = LYSVGATimeline(configuration: try configuration(
            fps: 1,
            frameCount: Int.max,
            repeatMode: .forever
        ))

        timeline.seek(toProgress: 0)
        XCTAssertEqual(timeline.currentFrame, 0)
        timeline.seek(toProgress: 0.5)
        XCTAssertGreaterThan(timeline.currentFrame, 0)
        XCTAssertLessThan(timeline.currentFrame, Int.max - 1)
        timeline.seek(toProgress: 1)
        XCTAssertEqual(timeline.currentFrame, Int.max - 1)
    }

    private func configuration(
        fps: Int = 20,
        frameCount: Int = 10,
        frameRange: ClosedRange<Int>? = nil,
        reverse: Bool = false,
        repeatMode: LYSVGARepeatMode = .once,
        allowsFrameSkipping: Bool = true,
        playbackRate: Double = 1
    ) throws -> LYSVGATimelineConfiguration {
        try LYSVGATimelineConfiguration(
            fps: fps,
            frameCount: frameCount,
            frameRange: frameRange,
            reverse: reverse,
            repeatMode: repeatMode,
            allowsFrameSkipping: allowsFrameSkipping,
            playbackRate: playbackRate
        )
    }

    private func assertEquatableAndSendable<T: Equatable & Sendable>(_ value: T) {
        XCTAssertEqual(value, value)
    }
}
