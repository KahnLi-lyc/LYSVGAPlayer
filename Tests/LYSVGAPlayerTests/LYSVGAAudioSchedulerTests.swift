import Foundation
import XCTest
@testable import LYSVGAPlayer

@MainActor
final class LYSVGAAudioSchedulerTests: XCTestCase {
    func testPrepareReportsMissingAudioDataWithoutCreatingPlayer() throws {
        let factory = FakeAudioPlayerFactory()
        let scheduler = LYSVGAAudioScheduler(factory: factory)

        XCTAssertThrowsError(try scheduler.prepare(video: video(cues: [cue(key: "missing")], audioData: [:]))) {
            XCTAssertEqual(
                $0 as? LYSVGAError,
                .audioPreparationFailure(audioKey: "missing", reason: "Audio data is missing.")
            )
        }
        XCTAssertEqual(factory.players.count, 0)
        XCTAssertEqual(scheduler.preparedPlayerCount, 0)
    }

    func testPrepareReportsFactoryAndPreparationFailuresAndCleansUp() throws {
        let factory = FakeAudioPlayerFactory()
        let scheduler = LYSVGAAudioScheduler(factory: factory)
        try scheduler.prepare(video: video(cues: [cue(key: "old")], audioData: ["old": Data([1])]))
        let oldPlayer = try XCTUnwrap(factory.players.last)

        factory.creationError = FakeAudioError.invalidBytes
        XCTAssertThrowsError(try scheduler.prepare(video: video(cues: [cue(key: "bad")], audioData: ["bad": Data([2])]))) {
            XCTAssertEqual(
                $0 as? LYSVGAError,
                .audioPreparationFailure(audioKey: "bad", reason: "Invalid audio bytes.")
            )
        }
        XCTAssertEqual(oldPlayer.stopCallCount, 1)
        XCTAssertEqual(scheduler.preparedPlayerCount, 0)

        factory.creationError = nil
        factory.prepareSucceeds = false
        XCTAssertThrowsError(try scheduler.prepare(video: video(cues: [cue(key: "unprepared")], audioData: ["unprepared": Data([3])]))) {
            XCTAssertEqual(
                $0 as? LYSVGAError,
                .audioPreparationFailure(audioKey: "unprepared", reason: "Audio player preparation failed.")
            )
        }
        XCTAssertEqual(factory.players.last?.stopCallCount, 1)
        XCTAssertEqual(scheduler.preparedPlayerCount, 0)
    }

    func testForwardSynchronizationUsesOffsetDurationClampAndExclusiveEndFrame() throws {
        let factory = FakeAudioPlayerFactory(duration: 1)
        let scheduler = LYSVGAAudioScheduler(factory: factory)
        try scheduler.prepare(video: video(
            cues: [cue(startFrame: 10, endFrame: 20, startTime: 500)],
            audioData: ["sound": Data([1])]
        ))
        let player = try XCTUnwrap(factory.players.first)

        scheduler.synchronize(frame: 9, reverse: false)
        XCTAssertEqual(player.playCallCount, 0)

        scheduler.synchronize(frame: 12, reverse: false)
        XCTAssertEqual(player.currentTime, 0.7, accuracy: 0.000_001)
        XCTAssertEqual(player.playCallCount, 1)

        scheduler.synchronize(frame: 20, reverse: false)
        XCTAssertEqual(player.stopCallCount, 1)

        scheduler.synchronize(frame: 19, reverse: false)
        XCTAssertEqual(player.currentTime, 1, accuracy: 0.000_001)
        XCTAssertEqual(player.playCallCount, 2)
    }

    func testReverseNeverStartsAudioAndStopsForwardPlayback() throws {
        let factory = FakeAudioPlayerFactory()
        let scheduler = LYSVGAAudioScheduler(factory: factory)
        try scheduler.prepare(video: video(
            cues: [cue(startFrame: 10, endFrame: 20)],
            audioData: ["sound": Data([1])]
        ))
        let player = try XCTUnwrap(factory.players.first)

        scheduler.synchronize(frame: 12, reverse: false)
        scheduler.synchronize(frame: 12, reverse: true)
        scheduler.synchronize(frame: 15, reverse: true)

        XCTAssertEqual(player.playCallCount, 1)
        XCTAssertEqual(player.stopCallCount, 1)
        XCTAssertFalse(player.isPlaying)
    }

    func testFailedInitialPlayRemainsInactiveAndRetriesWithinSameCue() throws {
        let factory = FakeAudioPlayerFactory(playResults: [false, true])
        let scheduler = LYSVGAAudioScheduler(factory: factory)
        try scheduler.prepare(video: video(cues: [cue()], audioData: ["sound": Data([1])]))
        let player = try XCTUnwrap(factory.players.first)

        scheduler.synchronize(frame: 2, reverse: false)
        XCTAssertFalse(player.isPlaying)
        scheduler.synchronize(frame: 2, reverse: false)

        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.playCallCount, 2)
    }

    func testPausePreservesPositionAndResumeContinuesActivePlayers() throws {
        let factory = FakeAudioPlayerFactory()
        let scheduler = LYSVGAAudioScheduler(factory: factory)
        try scheduler.prepare(video: video(cues: [cue()], audioData: ["sound": Data([1])]))
        let player = try XCTUnwrap(factory.players.first)
        scheduler.synchronize(frame: 2, reverse: false)
        player.currentTime = 0.75

        scheduler.pause()
        XCTAssertEqual(player.pauseCallCount, 1)
        XCTAssertEqual(player.currentTime, 0.75)

        scheduler.resume()
        XCTAssertEqual(player.playCallCount, 2)
        XCTAssertEqual(player.currentTime, 0.75)
    }

    func testFailedResumeBecomesInactiveAndRetriesOnSynchronization() throws {
        let factory = FakeAudioPlayerFactory(playResults: [true, false, true])
        let scheduler = LYSVGAAudioScheduler(factory: factory)
        try scheduler.prepare(video: video(cues: [cue()], audioData: ["sound": Data([1])]))
        let player = try XCTUnwrap(factory.players.first)

        scheduler.synchronize(frame: 2, reverse: false)
        scheduler.pause()
        scheduler.resume()
        XCTAssertFalse(player.isPlaying)
        scheduler.synchronize(frame: 2, reverse: false)

        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.playCallCount, 3)
    }

    func testSeekAndLoopForceCurrentFrameResynchronization() throws {
        let factory = FakeAudioPlayerFactory()
        let scheduler = LYSVGAAudioScheduler(factory: factory)
        try scheduler.prepare(video: video(
            cues: [cue(startFrame: 10, endFrame: 20, startTime: 500)],
            audioData: ["sound": Data([1])]
        ))
        let player = try XCTUnwrap(factory.players.first)

        scheduler.synchronize(frame: 10, reverse: false)
        scheduler.synchronize(frame: 12, reverse: false)
        XCTAssertEqual(player.currentTime, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(player.playCallCount, 1)

        scheduler.seek(to: 12, reverse: false)
        XCTAssertEqual(player.currentTime, 0.7, accuracy: 0.000_001)
        XCTAssertEqual(player.playCallCount, 2)

        scheduler.loop(at: 10, reverse: false)
        XCTAssertEqual(player.currentTime, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(player.playCallCount, 3)
        XCTAssertEqual(player.stopCallCount, 2)
    }

    func testMuteVolumeAndRateRemainIndependentFromPlayback() throws {
        let factory = FakeAudioPlayerFactory()
        let scheduler = LYSVGAAudioScheduler(factory: factory)
        scheduler.audioVolume = 2
        scheduler.playbackRate = 0.1
        scheduler.isMuted = true
        try scheduler.prepare(video: video(cues: [cue()], audioData: ["sound": Data([1])]))
        let player = try XCTUnwrap(factory.players.first)

        scheduler.synchronize(frame: 2, reverse: false)
        XCTAssertEqual(player.playCallCount, 1)
        XCTAssertTrue(player.enableRate)
        XCTAssertEqual(player.rate, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(player.volume, 0, accuracy: 0.000_001)

        scheduler.isMuted = false
        XCTAssertEqual(player.volume, 1, accuracy: 0.000_001)
        scheduler.audioVolume = -1
        XCTAssertEqual(player.volume, 0, accuracy: 0.000_001)
        scheduler.playbackRate = 3
        XCTAssertEqual(player.rate, 2, accuracy: 0.000_001)
    }

    func testOverlappingCuesWithSameKeyUseIndependentPlayers() throws {
        let factory = FakeAudioPlayerFactory()
        let scheduler = LYSVGAAudioScheduler(factory: factory)
        try scheduler.prepare(video: video(
            cues: [
                cue(startFrame: 0, endFrame: 10, startTime: 0),
                cue(startFrame: 5, endFrame: 15, startTime: 1_000),
            ],
            audioData: ["sound": Data([1])]
        ))

        XCTAssertEqual(factory.players.count, 2)
        scheduler.synchronize(frame: 5, reverse: false)
        XCTAssertEqual(factory.players[0].playCallCount, 1)
        XCTAssertEqual(factory.players[0].currentTime, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(factory.players[1].playCallCount, 1)
        XCTAssertEqual(factory.players[1].currentTime, 1, accuracy: 0.000_001)
    }

    func testPrepareReplacementStopAndClearReleasePreparedEntries() throws {
        let factory = FakeAudioPlayerFactory()
        let scheduler = LYSVGAAudioScheduler(factory: factory)
        try scheduler.prepare(video: video(cues: [cue(key: "first")], audioData: ["first": Data([1])]))
        let first = try XCTUnwrap(factory.players.last)

        try scheduler.prepare(video: video(cues: [cue(key: "second")], audioData: ["second": Data([2])]))
        let second = try XCTUnwrap(factory.players.last)
        XCTAssertEqual(first.stopCallCount, 1)
        XCTAssertEqual(scheduler.preparedPlayerCount, 1)

        scheduler.stop()
        XCTAssertEqual(second.stopCallCount, 1)
        scheduler.synchronize(frame: 1, reverse: false)
        XCTAssertEqual(second.playCallCount, 1)

        scheduler.clear()
        XCTAssertEqual(second.stopCallCount, 2)
        XCTAssertEqual(scheduler.preparedPlayerCount, 0)
    }

    private func video(
        cues: [LYSVGAAudioCue],
        audioData: [String: Data],
        fps: Int = 10
    ) throws -> LYSVGAVideo {
        try LYSVGAVideo(
            version: "test",
            canvasSize: LYSVGASize(width: 100, height: 100),
            fps: fps,
            frameCount: 100,
            images: [:],
            audioData: audioData,
            sprites: [],
            audios: cues
        )
    }

    private func cue(
        key: String = "sound",
        startFrame: Int = 0,
        endFrame: Int = 10,
        startTime: Int = 0
    ) -> LYSVGAAudioCue {
        LYSVGAAudioCue(
            audioKey: key,
            startFrame: startFrame,
            endFrame: endFrame,
            startTime: startTime,
            totalTime: 2_000
        )
    }
}

@MainActor
private final class FakeAudioPlayerFactory: LYSVGAAudioPlayerFactory {
    var creationError: Error?
    var prepareSucceeds = true
    let duration: TimeInterval
    let playResults: [Bool]
    private(set) var players: [FakeAudioPlayer] = []

    init(duration: TimeInterval = 10, playResults: [Bool] = []) {
        self.duration = duration
        self.playResults = playResults
    }

    func makePlayer(data _: Data) throws -> any LYSVGAAudioPlaying {
        if let creationError {
            throw creationError
        }
        let player = FakeAudioPlayer(
            duration: duration,
            prepareSucceeds: prepareSucceeds,
            playResults: playResults
        )
        players.append(player)
        return player
    }
}

@MainActor
private final class FakeAudioPlayer: LYSVGAAudioPlaying {
    let duration: TimeInterval
    var currentTime: TimeInterval = 0
    var volume: Float = 1
    var rate: Float = 1
    var enableRate = false
    private(set) var isPlaying = false
    private(set) var prepareCallCount = 0
    private(set) var playCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var stopCallCount = 0

    private let prepareSucceeds: Bool
    private var playResults: [Bool]

    init(duration: TimeInterval, prepareSucceeds: Bool, playResults: [Bool]) {
        self.duration = duration
        self.prepareSucceeds = prepareSucceeds
        self.playResults = playResults
    }

    func prepareToPlay() -> Bool {
        prepareCallCount += 1
        return prepareSucceeds
    }

    func play() -> Bool {
        playCallCount += 1
        let result = playResults.isEmpty ? true : playResults.removeFirst()
        isPlaying = result
        return result
    }

    func pause() {
        pauseCallCount += 1
        isPlaying = false
    }

    func stop() {
        stopCallCount += 1
        isPlaying = false
    }
}

private enum FakeAudioError: LocalizedError {
    case invalidBytes

    var errorDescription: String? {
        "Invalid audio bytes."
    }
}
