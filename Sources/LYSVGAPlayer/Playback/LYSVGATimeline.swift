import Foundation

struct LYSVGATimelineOutput: Equatable, Sendable {
    let frame: Int
    let completedLoops: UInt
    let didFinish: Bool

    init(frame: Int, completedLoops: UInt = 0, didFinish: Bool = false) {
        self.frame = frame
        self.completedLoops = completedLoops
        self.didFinish = didFinish
    }
}

struct LYSVGATimeline: Sendable {
    let configuration: LYSVGATimelineConfiguration

    private(set) var currentFrame: Int
    private(set) var isFinished = false
    private(set) var playbackRate: Double
    private(set) var allowsFrameSkipping: Bool

    private var currentStep: UInt = 0
    private var baselineStep: UInt = 0
    private var baselineTimestamp: TimeInterval?
    private var isPaused = false

    var currentProgress: Double {
        let range = configuration.frameRange
        guard range.lowerBound < range.upperBound else { return 0 }
        return Double(currentFrame - range.lowerBound) / Double(range.upperBound - range.lowerBound)
    }

    init(configuration: LYSVGATimelineConfiguration) {
        self.configuration = configuration
        playbackRate = configuration.playbackRate
        allowsFrameSkipping = configuration.allowsFrameSkipping
        currentFrame = configuration.reverse
            ? configuration.frameRange.upperBound
            : configuration.frameRange.lowerBound
    }

    mutating func tick(at timestamp: TimeInterval) -> LYSVGATimelineOutput {
        guard isFinished == false, isPaused == false else {
            return LYSVGATimelineOutput(frame: currentFrame)
        }
        guard let baselineTimestamp else {
            self.baselineTimestamp = timestamp
            baselineStep = currentStep
            return LYSVGATimelineOutput(frame: currentFrame)
        }

        let elapsed = max(0, timestamp - baselineTimestamp)
        let elapsedSteps = integralSteps(elapsed * Double(configuration.fps) * playbackRate)
        let targetStep = max(currentStep, addingWithoutOverflow(baselineStep, elapsedSteps))
        let nextStep: UInt
        if allowsFrameSkipping {
            nextStep = targetStep
        } else if targetStep > currentStep {
            nextStep = addingWithoutOverflow(currentStep, 1)
        } else {
            nextStep = currentStep
        }
        return advance(to: nextStep)
    }

    mutating func pause(at timestamp: TimeInterval) -> LYSVGATimelineOutput {
        let output = tick(at: timestamp)
        isPaused = true
        return output
    }

    mutating func resume(at timestamp: TimeInterval) {
        guard isPaused else { return }
        isPaused = false
        baselineTimestamp = timestamp
        baselineStep = currentStep
    }

    mutating func updatePlaybackRate(_ playbackRate: Double, at timestamp: TimeInterval) -> LYSVGATimelineOutput {
        let output: LYSVGATimelineOutput
        if isPaused || isFinished {
            output = LYSVGATimelineOutput(frame: currentFrame)
        } else {
            output = tick(at: timestamp)
        }

        self.playbackRate = LYSVGAPlaybackRate.clamped(playbackRate)
        if isPaused == false, isFinished == false {
            baselineTimestamp = timestamp
            baselineStep = currentStep
        }
        return output
    }

    mutating func updateAllowsFrameSkipping(_ allowsFrameSkipping: Bool) {
        self.allowsFrameSkipping = allowsFrameSkipping
    }

    mutating func seek(toFrame frame: Int) {
        let range = configuration.frameRange
        let targetFrame = min(range.upperBound, max(range.lowerBound, frame))
        let traversal = currentTraversalForSeek()
        let offset = configuration.reverse
            ? range.upperBound - targetFrame
            : targetFrame - range.lowerBound
        currentStep = addingWithoutOverflow(
            multiplyingWithoutOverflow(traversal, UInt(frameSpan)),
            UInt(offset)
        )
        currentFrame = targetFrame
        isFinished = false
        resetTimestampBaseline()
    }

    mutating func seek(toProgress progress: Double) {
        let normalized: Double
        if progress.isNaN {
            normalized = 0
        } else {
            normalized = min(1, max(0, progress))
        }
        let range = configuration.frameRange
        let offset = Int((normalized * Double(range.upperBound - range.lowerBound)).rounded())
        seek(toFrame: range.lowerBound + offset)
    }

    mutating func reset() {
        currentStep = 0
        currentFrame = configuration.reverse
            ? configuration.frameRange.upperBound
            : configuration.frameRange.lowerBound
        isFinished = false
        isPaused = false
        resetTimestampBaseline()
    }

    private var frameSpan: Int {
        configuration.frameRange.upperBound - configuration.frameRange.lowerBound + 1
    }

    private var totalTraversals: UInt? {
        switch configuration.repeatMode {
        case .once: 1
        case let .count(count): count
        case .forever: nil
        }
    }

    private var totalSteps: UInt? {
        totalTraversals.map { multiplyingWithoutOverflow($0, UInt(frameSpan)) }
    }

    private mutating func advance(to requestedStep: UInt) -> LYSVGATimelineOutput {
        let oldStep = currentStep
        let nextStep = totalSteps.map { min(requestedStep, $0) } ?? requestedStep
        currentStep = nextStep

        let didFinish: Bool
        if let totalSteps, oldStep < totalSteps, nextStep >= totalSteps {
            isFinished = true
            didFinish = true
            currentFrame = configuration.reverse
                ? configuration.frameRange.lowerBound
                : configuration.frameRange.upperBound
        } else {
            didFinish = false
            let offset = Int(nextStep % UInt(frameSpan))
            currentFrame = configuration.reverse
                ? configuration.frameRange.upperBound - offset
                : configuration.frameRange.lowerBound + offset
        }

        return LYSVGATimelineOutput(
            frame: currentFrame,
            completedLoops: completedLoops(from: oldStep, to: nextStep),
            didFinish: didFinish
        )
    }

    private func completedLoops(from oldStep: UInt, to newStep: UInt) -> UInt {
        let span = UInt(frameSpan)
        let oldBoundaryCount = oldStep / span
        let newBoundaryCount = newStep / span
        let maximumLoopCount = totalTraversals.map { $0 - 1 } ?? UInt.max
        let oldLoops = min(oldBoundaryCount, maximumLoopCount)
        let newLoops = min(newBoundaryCount, maximumLoopCount)
        return newLoops - oldLoops
    }

    private func currentTraversalForSeek() -> UInt {
        let traversal = currentStep / UInt(frameSpan)
        guard let totalTraversals else { return traversal }
        return min(traversal, totalTraversals - 1)
    }

    private mutating func resetTimestampBaseline() {
        baselineTimestamp = nil
        baselineStep = currentStep
    }

    private func integralSteps(_ value: Double) -> UInt {
        guard value.isNaN == false, value > 0 else { return 0 }
        guard value < Double(UInt.max) else { return UInt.max }
        let nearestInteger = value.rounded()
        let tolerance = max(1, abs(value)) * 1e-9
        let integralValue = abs(value - nearestInteger) <= tolerance
            ? nearestInteger
            : value.rounded(.down)
        return UInt(integralValue)
    }

    private func addingWithoutOverflow(_ lhs: UInt, _ rhs: UInt) -> UInt {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt.max : result
    }

    private func multiplyingWithoutOverflow(_ lhs: UInt, _ rhs: UInt) -> UInt {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? UInt.max : result
    }
}
