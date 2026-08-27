import UIKit

/// Receives player events on the main actor.
@MainActor
public protocol LYSVGAPlayerViewDelegate: AnyObject {
    func playerView(_ playerView: LYSVGAPlayerView, didChangePlaybackState state: LYSVGAPlaybackState)
    func playerView(_ playerView: LYSVGAPlayerView, didDisplayFrame frame: Int, progress: Double)

    /// Reports the number of loop boundaries crossed by the current display tick.
    func playerView(_ playerView: LYSVGAPlayerView, didCrossLoops count: UInt)
    func playerViewDidFinish(_ playerView: LYSVGAPlayerView)
    func playerView(_ playerView: LYSVGAPlayerView, didFailWith error: LYSVGAError)
}

public extension LYSVGAPlayerViewDelegate {
    func playerView(_ playerView: LYSVGAPlayerView, didChangePlaybackState state: LYSVGAPlaybackState) {}
    func playerView(_ playerView: LYSVGAPlayerView, didDisplayFrame frame: Int, progress: Double) {}
    func playerView(_ playerView: LYSVGAPlayerView, didCrossLoops count: UInt) {}
    func playerViewDidFinish(_ playerView: LYSVGAPlayerView) {}
    func playerView(_ playerView: LYSVGAPlayerView, didFailWith error: LYSVGAError) {}
}

@MainActor
public final class LYSVGAPlayerView: UIView {
    typealias ClockFactory = (@escaping (TimeInterval) -> Void) -> any LYSVGADisplayClock
    typealias CandidateFactory = () -> LYSVGAPlayerPreparationCandidate
    typealias PreparationHook = (LYSVGAVideo) async throws -> Void

    public weak var delegate: (any LYSVGAPlayerViewDelegate)?

    public private(set) var playbackState: LYSVGAPlaybackState = .idle
    public private(set) var currentFrame: Int?
    public private(set) var currentProgress = 0.0
    public private(set) var video: LYSVGAVideo?
    public private(set) var isReversePlayback = false

    public override var contentMode: UIView.ContentMode {
        didSet { setNeedsLayout() }
    }

    public override var clipsToBounds: Bool {
        didSet { setNeedsLayout() }
    }

    public var repeatMode: LYSVGARepeatMode = .once
    public var endBehavior: LYSVGAEndBehavior = .holdEndFrame

    public var playbackRate = 1.0 {
        didSet {
            let clamped = LYSVGAPlaybackRate.clamped(playbackRate)
            if playbackRate != clamped {
                playbackRate = clamped
            }
            audioScheduler?.playbackRate = clamped
            guard var timeline else { return }
            let timestamp = playbackState == .playing ? clockTimestamp : .nan
            let output = timeline.updatePlaybackRate(clamped, at: timestamp)
            self.timeline = timeline
            consume(output)
        }
    }

    public var allowsFrameSkipping = true {
        didSet {
            timeline?.updateAllowsFrameSkipping(allowsFrameSkipping)
        }
    }

    public var isMuted = false {
        didSet { audioScheduler?.isMuted = isMuted }
    }

    public var audioVolume = 1.0 {
        didSet {
            let clamped = Self.clampedVolume(audioVolume)
            if audioVolume != clamped {
                audioVolume = clamped
            }
            audioScheduler?.audioVolume = clamped
        }
    }

    private let clockFactory: ClockFactory
    private let candidateFactory: CandidateFactory
    private let preparationHook: PreparationHook?
    private let notificationCenter: NotificationCenter

    private var renderer: LYSVGARenderer?
    private var audioScheduler: LYSVGAAudioScheduler?
    private var timeline: LYSVGATimeline?
    private var playbackRange: ClosedRange<Int>?
    private var clock: (any LYSVGADisplayClock)?
    private var generation: UInt = 0
    private var didReportFinish = false
    private var notificationTokens: [NSObjectProtocol] = []
    private var interruptionReasons: Set<LYSVGAPlayerInterruptionReason> = []
    private var shouldResumeAfterInterruption = false

    public override init(frame: CGRect) {
        clockFactory = Self.defaultClockFactory
        candidateFactory = Self.defaultCandidateFactory
        preparationHook = nil
        notificationCenter = .default
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        clockFactory = Self.defaultClockFactory
        candidateFactory = Self.defaultCandidateFactory
        preparationHook = nil
        notificationCenter = .default
        super.init(coder: coder)
        commonInit()
    }

    init(
        clockFactory: @escaping ClockFactory = LYSVGAPlayerView.defaultClockFactory,
        candidateFactory: @escaping CandidateFactory = LYSVGAPlayerView.defaultCandidateFactory,
        preparationHook: PreparationHook? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.clockFactory = clockFactory
        self.candidateFactory = candidateFactory
        self.preparationHook = preparationHook
        self.notificationCenter = notificationCenter
        super.init(frame: .zero)
        commonInit()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        renderer?.layout(in: bounds, contentMode: contentMode, clipsToBounds: clipsToBounds)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            guard playbackState == .playing || interruptionReasons.contains(.windowDetached) else { return }
            beginInterruption(.windowDetached)
        } else {
            endInterruption(.windowDetached)
        }
    }

    public func setVideo(_ video: LYSVGAVideo) async throws {
        let requestGeneration = beginLoadingRequest()
        try await prepareAndInstall(video, generation: requestGeneration, autoplay: false)
    }

    public func load(
        _ source: LYSVGASource,
        using loader: LYSVGAAssetLoader,
        cachePolicy: LYSVGACachePolicy = .automatic,
        autoplay: Bool = false
    ) async throws {
        let requestGeneration = beginLoadingRequest()
        let video: LYSVGAVideo
        do {
            video = try await loader.load(source, cachePolicy: cachePolicy)
            try ensureCurrent(requestGeneration)
        } catch {
            throw finishLoadingFailure(error, generation: requestGeneration)
        }
        try await prepareAndInstall(video, generation: requestGeneration, autoplay: autoplay)
    }

    public func play(range: ClosedRange<Int>? = nil, reverse: Bool = false) throws {
        guard let video else {
            throw LYSVGAError.invalidPlaybackConfiguration("A video must be installed before playback.")
        }
        let configuration = try LYSVGATimelineConfiguration(
            fps: video.fps,
            frameCount: video.frameCount,
            frameRange: range,
            reverse: reverse,
            repeatMode: repeatMode,
            allowsFrameSkipping: allowsFrameSkipping,
            playbackRate: playbackRate
        )
        let timeline = LYSVGATimeline(configuration: configuration)
        self.timeline = timeline
        playbackRange = configuration.frameRange
        isReversePlayback = reverse
        didReportFinish = false
        shouldResumeAfterInterruption = false
        display(frame: timeline.currentFrame, forceDelegate: true)
        audioScheduler?.stop()
        audioScheduler?.seek(to: timeline.currentFrame, reverse: reverse)
        ensureClock().start()
        changeState(.playing)
    }

    public func pause() {
        pause(cancelAutomaticResume: true)
    }

    public func resume() {
        guard playbackState == .paused, interruptionReasons.isEmpty else { return }
        guard var timeline else { return }
        timeline.resume(at: clockTimestamp)
        self.timeline = timeline
        audioScheduler?.resume()
        ensureClock().start()
        shouldResumeAfterInterruption = false
        changeState(.playing)
    }

    public func stop() {
        guard video != nil else { return }
        shouldResumeAfterInterruption = false
        clock?.pause()
        audioScheduler?.stop()
        applyEndBehavior()
        changeState(.ready)
    }

    public func clear() {
        generation &+= 1
        shouldResumeAfterInterruption = false
        interruptionReasons.removeAll()
        clock?.invalidate()
        clock = nil
        audioScheduler?.clear()
        audioScheduler = nil
        renderer?.rootLayer.removeFromSuperlayer()
        renderer = nil
        timeline = nil
        playbackRange = nil
        video = nil
        currentFrame = nil
        currentProgress = 0
        isReversePlayback = false
        didReportFinish = false
        removeNotifications()
        changeState(.idle)
    }

    public func seek(toFrame frame: Int, andPlay: Bool = false) {
        guard let video else { return }
        let range = playbackRange ?? 0...(video.frameCount - 1)
        let target = min(range.upperBound, max(range.lowerBound, frame))
        let wasPlaying = playbackState == .playing
        ensureTimelineForSeeking(video: video, range: range)
        timeline?.seek(toFrame: target)
        display(frame: target, forceDelegate: true)

        if andPlay {
            startPlaybackAfterSeek(at: target)
        } else if wasPlaying {
            if var timeline {
                _ = timeline.pause(at: clockTimestamp)
                self.timeline = timeline
            }
            clock?.pause()
            audioScheduler?.pause()
            audioScheduler?.seek(to: target, reverse: isReversePlayback)
            shouldResumeAfterInterruption = false
            changeState(.paused)
        } else if playbackState == .paused {
            shouldResumeAfterInterruption = false
            audioScheduler?.seek(to: target, reverse: isReversePlayback)
        } else {
            audioScheduler?.stop()
        }
    }

    public func seek(toProgress progress: Double, andPlay: Bool = false) {
        guard let video else { return }
        let normalized = Self.clampedProgress(progress)
        let lastFrame = video.frameCount - 1
        let frame: Int
        if normalized <= 0 {
            frame = 0
        } else if normalized >= 1 {
            frame = lastFrame
        } else {
            let maximumConvertible = Double(Int.max).nextDown
            frame = Int(min(maximumConvertible, (normalized * Double(lastFrame)).rounded()))
        }
        seek(toFrame: frame, andPlay: andPlay)
    }

    isolated deinit {
        notificationTokens.forEach(notificationCenter.removeObserver)
        clock?.invalidate()
        audioScheduler?.clear()
        renderer?.rootLayer.removeFromSuperlayer()
    }
}

@MainActor
struct LYSVGAPlayerPreparationCandidate {
    let renderer: LYSVGARenderer
    let audioScheduler: LYSVGAAudioScheduler
}

private enum LYSVGAPlayerInterruptionReason: Hashable {
    case applicationInactive
    case applicationBackground
    case windowDetached
}

@MainActor
extension LYSVGAPlayerView {
    static var defaultClockFactory: ClockFactory {
        { handler in LYSVGADisplayLinkClock(handler: handler) }
    }

    static var defaultCandidateFactory: CandidateFactory {
        { LYSVGAPlayerPreparationCandidate(renderer: LYSVGARenderer(), audioScheduler: LYSVGAAudioScheduler()) }
    }

    var clockTimestamp: TimeInterval {
        clock?.timestamp ?? CACurrentMediaTime()
    }

    var rendererRootLayerForTesting: CALayer? {
        renderer?.rootLayer
    }

    func tickForTesting(at timestamp: TimeInterval) {
        tick(at: timestamp)
    }
}

@MainActor
private extension LYSVGAPlayerView {
    func commonInit() {
        installNotificationsIfNeeded()
    }

    func beginLoadingRequest() -> UInt {
        installNotificationsIfNeeded()
        generation &+= 1
        let requestGeneration = generation
        shouldResumeAfterInterruption = false
        clock?.pause()
        audioScheduler?.pause()
        changeState(.loading)
        return requestGeneration
    }

    func prepareAndInstall(
        _ video: LYSVGAVideo,
        generation requestGeneration: UInt,
        autoplay: Bool
    ) async throws {
        let candidate = candidateFactory()
        candidate.audioScheduler.playbackRate = playbackRate
        candidate.audioScheduler.audioVolume = audioVolume
        candidate.audioScheduler.isMuted = isMuted

        do {
            try Task.checkCancellation()
            if let preparationHook {
                try await preparationHook(video)
            }
            try Task.checkCancellation()
            try await candidate.renderer.prepare(video: video)
            try Task.checkCancellation()
            try candidate.audioScheduler.prepare(video: video)
            try Task.checkCancellation()
            try ensureCurrent(requestGeneration)
            if autoplay {
                _ = try LYSVGATimelineConfiguration(
                    fps: video.fps,
                    frameCount: video.frameCount,
                    reverse: false,
                    repeatMode: repeatMode,
                    allowsFrameSkipping: allowsFrameSkipping,
                    playbackRate: playbackRate
                )
            }

            install(candidate, video: video)
            if autoplay {
                try play()
            }
        } catch {
            candidate.audioScheduler.clear()
            candidate.renderer.rootLayer.removeFromSuperlayer()
            throw finishLoadingFailure(error, generation: requestGeneration)
        }
    }

    func install(_ candidate: LYSVGAPlayerPreparationCandidate, video: LYSVGAVideo) {
        clock?.pause()
        audioScheduler?.clear()
        renderer?.rootLayer.removeFromSuperlayer()

        renderer = candidate.renderer
        audioScheduler = candidate.audioScheduler
        self.video = video
        timeline = nil
        playbackRange = nil
        isReversePlayback = false
        didReportFinish = false
        layer.addSublayer(candidate.renderer.rootLayer)
        candidate.renderer.layout(in: bounds, contentMode: contentMode, clipsToBounds: clipsToBounds)
        display(frame: 0, forceDelegate: true)
        changeState(.ready)
    }

    func ensureCurrent(_ requestGeneration: UInt) throws {
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw LYSVGAError.cancelled }
    }

    func finishLoadingFailure(_ error: Error, generation requestGeneration: UInt) -> LYSVGAError {
        let resolved = Self.playerError(from: error)
        guard generation == requestGeneration else { return .cancelled }
        changeState(.failed)
        delegate?.playerView(self, didFailWith: resolved)
        return resolved
    }

    func ensureClock() -> any LYSVGADisplayClock {
        if let clock { return clock }
        let clock = clockFactory { [weak self] timestamp in
            self?.tick(at: timestamp)
        }
        self.clock = clock
        return clock
    }

    func tick(at timestamp: TimeInterval) {
        guard playbackState == .playing, var timeline else { return }
        let output = timeline.tick(at: timestamp)
        self.timeline = timeline
        consume(output)
    }

    func consume(_ output: LYSVGATimelineOutput) {
        guard timeline != nil else { return }
        let frameChanged = currentFrame != output.frame
        if output.completedLoops > 0 {
            audioScheduler?.loop(at: output.frame, reverse: isReversePlayback)
        } else if frameChanged {
            audioScheduler?.synchronize(frame: output.frame, reverse: isReversePlayback)
        }
        if frameChanged || output.didFinish {
            display(frame: output.frame, forceDelegate: true)
        }
        if output.completedLoops > 0 {
            delegate?.playerView(self, didCrossLoops: output.completedLoops)
        }
        if output.didFinish {
            finishNaturally()
        }
    }

    func finishNaturally() {
        guard didReportFinish == false else { return }
        didReportFinish = true
        shouldResumeAfterInterruption = false
        clock?.pause()
        audioScheduler?.stop()
        applyEndBehavior()
        changeState(.finished)
        delegate?.playerViewDidFinish(self)
    }

    func display(frame: Int, forceDelegate: Bool) {
        renderer?.display(frame: frame)
        currentFrame = renderer?.currentFrame
        guard let currentFrame else {
            currentProgress = 0
            return
        }
        currentProgress = absoluteProgress(for: currentFrame)
        if forceDelegate {
            delegate?.playerView(self, didDisplayFrame: currentFrame, progress: currentProgress)
        }
    }

    func absoluteProgress(for frame: Int) -> Double {
        guard let video, video.frameCount > 1 else { return 0 }
        return Double(frame) / Double(video.frameCount - 1)
    }

    func pause(cancelAutomaticResume: Bool) {
        guard playbackState == .playing, var timeline else {
            if cancelAutomaticResume { shouldResumeAfterInterruption = false }
            return
        }
        let output = timeline.pause(at: clockTimestamp)
        self.timeline = timeline
        consume(output)
        guard playbackState == .playing else { return }
        clock?.pause()
        audioScheduler?.pause()
        if cancelAutomaticResume { shouldResumeAfterInterruption = false }
        changeState(.paused)
    }

    func applyEndBehavior() {
        guard let video else { return }
        let range = playbackRange ?? 0...(video.frameCount - 1)
        switch endBehavior {
        case .clear:
            renderer?.display(frame: -1)
            currentFrame = nil
            currentProgress = 0
        case .holdStartFrame:
            display(frame: range.lowerBound, forceDelegate: currentFrame != range.lowerBound)
        case .holdEndFrame:
            display(frame: range.upperBound, forceDelegate: currentFrame != range.upperBound)
        }
    }

    func ensureTimelineForSeeking(video: LYSVGAVideo, range: ClosedRange<Int>) {
        guard timeline == nil else { return }
        timeline = try? LYSVGATimeline(configuration: LYSVGATimelineConfiguration(
            fps: video.fps,
            frameCount: video.frameCount,
            frameRange: range,
            reverse: isReversePlayback,
            repeatMode: repeatMode,
            allowsFrameSkipping: allowsFrameSkipping,
            playbackRate: playbackRate
        ))
        playbackRange = range
    }

    func startPlaybackAfterSeek(at frame: Int) {
        guard var timeline else { return }
        if playbackState == .paused {
            timeline.resume(at: clockTimestamp)
        }
        self.timeline = timeline
        didReportFinish = false
        shouldResumeAfterInterruption = false
        audioScheduler?.seek(to: frame, reverse: isReversePlayback)
        audioScheduler?.resume()
        ensureClock().start()
        changeState(.playing)
    }

    func changeState(_ state: LYSVGAPlaybackState) {
        guard playbackState != state else { return }
        playbackState = state
        delegate?.playerView(self, didChangePlaybackState: state)
    }

    func installNotificationsIfNeeded() {
        guard notificationTokens.isEmpty else { return }
        notificationTokens = [
            notificationCenter.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.beginInterruption(.applicationInactive) }
            },
            notificationCenter.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.beginInterruption(.applicationBackground) }
            },
            notificationCenter.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.endInterruption(.applicationBackground) }
            },
            notificationCenter.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.endInterruption(.applicationInactive) }
            },
        ]
    }

    func removeNotifications() {
        notificationTokens.forEach(notificationCenter.removeObserver)
        notificationTokens.removeAll()
    }

    func beginInterruption(_ reason: LYSVGAPlayerInterruptionReason) {
        interruptionReasons.insert(reason)
        guard playbackState == .playing else { return }
        shouldResumeAfterInterruption = true
        pause(cancelAutomaticResume: false)
    }

    func endInterruption(_ reason: LYSVGAPlayerInterruptionReason) {
        interruptionReasons.remove(reason)
        guard interruptionReasons.isEmpty, shouldResumeAfterInterruption else { return }
        resume()
    }

    static func clampedVolume(_ value: Double) -> Double {
        guard value.isNaN == false else { return 1 }
        return min(1, max(0, value))
    }

    static func clampedProgress(_ value: Double) -> Double {
        guard value.isNaN == false else { return 0 }
        return min(1, max(0, value))
    }

    static func playerError(from error: Error) -> LYSVGAError {
        if error is CancellationError { return .cancelled }
        if let error = error as? LYSVGAError { return error }
        return .invalidPlaybackConfiguration(error.localizedDescription)
    }
}
