import Foundation

enum LYSVGAPlaybackRate {
    static let minimum = 0.5
    static let maximum = 2.0

    static func clamped(_ value: Double) -> Double {
        guard value.isNaN == false else { return 1 }
        return min(maximum, max(minimum, value))
    }
}

struct LYSVGATimelineConfiguration: Equatable, Sendable {
    let fps: Int
    let frameCount: Int
    let frameRange: ClosedRange<Int>
    let reverse: Bool
    let repeatMode: LYSVGARepeatMode
    let allowsFrameSkipping: Bool
    let playbackRate: Double

    init(
        fps: Int,
        frameCount: Int,
        frameRange: ClosedRange<Int>? = nil,
        reverse: Bool = false,
        repeatMode: LYSVGARepeatMode = .once,
        allowsFrameSkipping: Bool = true,
        playbackRate: Double = 1
    ) throws {
        guard fps > 0 else {
            throw LYSVGAError.invalidPlaybackConfiguration("FPS must be greater than zero.")
        }
        guard frameCount > 0 else {
            throw LYSVGAError.invalidPlaybackConfiguration("Frame count must be greater than zero.")
        }

        let resolvedRange = frameRange ?? 0...(frameCount - 1)
        guard resolvedRange.lowerBound <= resolvedRange.upperBound else {
            throw LYSVGAError.invalidPlaybackConfiguration("Frame range lower bound must not exceed its upper bound.")
        }
        guard resolvedRange.lowerBound >= 0, resolvedRange.upperBound < frameCount else {
            throw LYSVGAError.invalidPlaybackConfiguration("Frame range must be within 0..<frameCount.")
        }
        if case .count(0) = repeatMode {
            throw LYSVGAError.invalidPlaybackConfiguration("Repeat count must be greater than zero.")
        }

        self.fps = fps
        self.frameCount = frameCount
        self.frameRange = resolvedRange
        self.reverse = reverse
        self.repeatMode = repeatMode
        self.allowsFrameSkipping = allowsFrameSkipping
        self.playbackRate = LYSVGAPlaybackRate.clamped(playbackRate)
    }
}
