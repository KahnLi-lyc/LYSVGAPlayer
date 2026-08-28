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
            consume(output, revision: mutationRevision)
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
    private var mutationRevision: UInt = 0
    private var didReportFinish = false
    private var notificationsInstalled = false
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
            beginInterruption(.windowDetached)
        } else {
            endInterruption(.windowDetached)
        }
    }

    public func setVideo(_ video: LYSVGAVideo) async throws {
        let request = beginLoadingRequest()
        try await prepareAndInstall(
            video,
            generation: request.generation,
            revision: request.revision,
            autoplay: false
        )
    }

    public func load(
        _ source: LYSVGASource,
        using loader: LYSVGAAssetLoader,
        cachePolicy: LYSVGACachePolicy = .automatic,
        autoplay: Bool = false
    ) async throws {
        let request = beginLoadingRequest()
        let video: LYSVGAVideo
        do {
            video = try await loader.load(source, cachePolicy: cachePolicy)
            try ensureCurrent(generation: request.generation, revision: request.revision)
        } catch {
            throw finishLoadingFailure(
                error,
                generation: request.generation,
                revision: request.revision
            )
        }
        try await prepareAndInstall(
            video,
            generation: request.generation,
            revision: request.revision,
            autoplay: autoplay
        )
    }

    public func play(range: ClosedRange<Int>? = nil, reverse: Bool = false) throws {
        guard video != nil else {
            throw LYSVGAError.invalidPlaybackConfiguration("A video must be installed before playback.")
        }
        let revision = beginMutation()
        try play(range: range, reverse: reverse, revision: revision)
    }

    public func pause() {
        if timeline?.isFinished == true {
            shouldResumeAfterInterruption = false
            return
        }
        guard playbackState == .playing || shouldResumeAfterInterruption else { return }
        let revision = beginMutation()
        pause(cancelAutomaticResume: true, revision: revision)
    }

    public func resume() {
        guard playbackState == .paused, interruptionReasons.isEmpty, timeline != nil else { return }
        let revision = beginMutation()
        resume(revision: revision)
    }

    public func stop() {
        guard video != nil else { return }
        let revision = beginMutation()
        shouldResumeAfterInterruption = false
        clock?.pause()
        audioScheduler?.stop()
        guard applyEndBehavior(revision: revision) else { return }
        _ = changeState(.ready, revision: revision)
    }

    public func clear() {
        let revision = beginMutation()
        generation &+= 1
        shouldResumeAfterInterruption = false
        interruptionReasons = interruptionReasons.intersection([.windowDetached])
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
        _ = changeState(.idle, revision: revision)
    }

    public func seek(toFrame frame: Int, andPlay: Bool = false) {
        guard playbackState != .loading, video != nil else { return }
        let revision = beginMutation()
        seek(toFrame: frame, andPlay: andPlay, revision: revision)
    }

    public func seek(toProgress progress: Double, andPlay: Bool = false) {
        guard playbackState != .loading, let video else { return }
        let revision = beginMutation()
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
        seek(toFrame: frame, andPlay: andPlay, revision: revision)
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

    func beginMutation() -> UInt {
        mutationRevision &+= 1
        return mutationRevision
    }

    func beginLoadingRequest() -> (generation: UInt, revision: UInt) {
        installNotificationsIfNeeded()
        let revision = beginMutation()
        generation &+= 1
        let requestGeneration = generation
        shouldResumeAfterInterruption = false
        clock?.pause()
        audioScheduler?.pause()
        _ = changeState(.loading, revision: revision)
        return (requestGeneration, revision)
    }

    func prepareAndInstall(
        _ video: LYSVGAVideo,
        generation requestGeneration: UInt,
        revision requestRevision: UInt,
        autoplay: Bool
    ) async throws {
        let candidate = candidateFactory()
        var ownsCandidate = true

        do {
            try ensureCurrent(generation: requestGeneration, revision: requestRevision)
            if let preparationHook {
                try await preparationHook(video)
            }
            try ensureCurrent(generation: requestGeneration, revision: requestRevision)
            try await candidate.renderer.prepare(video: video)
            try ensureCurrent(generation: requestGeneration, revision: requestRevision)

            let preparedPlaybackRate = playbackRate
            candidate.audioScheduler.playbackRate = preparedPlaybackRate
            candidate.audioScheduler.audioVolume = audioVolume
            candidate.audioScheduler.isMuted = isMuted
            try candidate.audioScheduler.prepare(video: video)
            try Task.checkCancellation()
            try ensureCurrent(generation: requestGeneration, revision: requestRevision)
            if autoplay {
                _ = try LYSVGATimelineConfiguration(
                    fps: video.fps,
                    frameCount: video.frameCount,
                    reverse: false,
                    repeatMode: repeatMode,
                    allowsFrameSkipping: allowsFrameSkipping,
                    playbackRate: preparedPlaybackRate
                )
            }

            let installationRemainsCurrent = install(
                candidate,
                video: video,
                revision: requestRevision
            )
            ownsCandidate = false
            guard installationRemainsCurrent else {
                throw LYSVGAError.cancelled
            }
            if autoplay {
                try play(range: nil, reverse: false, revision: requestRevision)
            }
        } catch {
            if ownsCandidate {
                candidate.audioScheduler.clear()
                candidate.renderer.rootLayer.removeFromSuperlayer()
            }
            throw finishLoadingFailure(
                error,
                generation: requestGeneration,
                revision: requestRevision
            )
        }
    }

    func install(
        _ candidate: LYSVGAPlayerPreparationCandidate,
        video: LYSVGAVideo,
        revision: UInt
    ) -> Bool {
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
        guard display(frame: 0, forceDelegate: true, revision: revision) else { return false }
        return changeState(.ready, revision: revision)
    }

    func isCurrent(revision: UInt, generation requestGeneration: UInt? = nil) -> Bool {
        guard mutationRevision == revision else { return false }
        return requestGeneration.map { generation == $0 } ?? true
    }

    func ensureCurrent(generation requestGeneration: UInt, revision: UInt) throws {
        try Task.checkCancellation()
        guard isCurrent(revision: revision, generation: requestGeneration) else {
            throw LYSVGAError.cancelled
        }
    }

    func finishLoadingFailure(
        _ error: Error,
        generation requestGeneration: UInt,
        revision requestRevision: UInt
    ) -> LYSVGAError {
        let resolved = Self.playerError(from: error)
        guard isCurrent(revision: requestRevision, generation: requestGeneration) else { return .cancelled }
        guard changeState(.failed, revision: requestRevision) else { return .cancelled }
        delegate?.playerView(self, didFailWith: resolved)
        return isCurrent(revision: requestRevision, generation: requestGeneration) ? resolved : .cancelled
    }

    func play(range: ClosedRange<Int>?, reverse: Bool, revision: UInt) throws {
        guard isCurrent(revision: revision) else { return }
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
        guard display(
            frame: timeline.currentFrame,
            forceDelegate: true,
            revision: revision
        ) else { return }

        audioScheduler?.stop()
        if interruptionReasons.isEmpty {
            audioScheduler?.seek(to: timeline.currentFrame, reverse: reverse)
            ensureClock().start()
            _ = changeState(.playing, revision: revision)
        } else {
            var pausedTimeline = timeline
            _ = pausedTimeline.pause(at: clockTimestamp)
            self.timeline = pausedTimeline
            clock?.pause()
            audioScheduler?.pause()
            audioScheduler?.seek(to: timeline.currentFrame, reverse: reverse)
            shouldResumeAfterInterruption = true
            _ = changeState(.paused, revision: revision)
        }
    }

    func resume(revision: UInt) {
        guard isCurrent(revision: revision) else { return }
        guard playbackState == .paused, interruptionReasons.isEmpty else { return }
        guard var timeline else { return }
        let clock = ensureClock()
        timeline.resume(at: clock.timestamp)
        self.timeline = timeline
        audioScheduler?.resume()
        clock.start()
        shouldResumeAfterInterruption = false
        _ = changeState(.playing, revision: revision)
    }

    func seek(toFrame frame: Int, andPlay: Bool, revision: UInt) {
        guard isCurrent(revision: revision), playbackState != .loading, let video else { return }
        let range = playbackRange ?? 0...(video.frameCount - 1)
        let target = min(range.upperBound, max(range.lowerBound, frame))
        ensureTimelineForSeeking(video: video, range: range)
        timeline?.seek(toFrame: target)
        guard display(frame: target, forceDelegate: true, revision: revision) else { return }

        if andPlay {
            startPlaybackAfterSeek(at: target, revision: revision)
        } else {
            if var timeline {
                _ = timeline.pause(at: clockTimestamp)
                self.timeline = timeline
            }
            clock?.pause()
            audioScheduler?.pause()
            audioScheduler?.seek(to: target, reverse: isReversePlayback)
            shouldResumeAfterInterruption = false
            _ = changeState(.paused, revision: revision)
        }
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
        let revision = mutationRevision
        let output = timeline.tick(at: timestamp)
        self.timeline = timeline
        consume(output, revision: revision)
    }

    func consume(_ output: LYSVGATimelineOutput, revision: UInt) {
        guard isCurrent(revision: revision), timeline != nil else { return }
        let frameChanged = currentFrame != output.frame
        if output.completedLoops > 0 {
            audioScheduler?.loop(at: output.frame, reverse: isReversePlayback)
        } else if frameChanged {
            audioScheduler?.synchronize(frame: output.frame, reverse: isReversePlayback)
        }
        if frameChanged || output.didFinish {
            guard display(frame: output.frame, forceDelegate: true, revision: revision) else { return }
        }
        if output.completedLoops > 0 {
            delegate?.playerView(self, didCrossLoops: output.completedLoops)
            guard isCurrent(revision: revision) else { return }
        }
        if output.didFinish {
            finishNaturally(revision: revision)
        }
    }

    func finishNaturally(revision: UInt) {
        guard isCurrent(revision: revision), didReportFinish == false else { return }
        didReportFinish = true
        shouldResumeAfterInterruption = false
        clock?.pause()
        audioScheduler?.stop()
        guard applyEndBehavior(revision: revision) else { return }
        guard changeState(.finished, revision: revision) else { return }
        delegate?.playerViewDidFinish(self)
        guard isCurrent(revision: revision) else { return }
    }

    func display(frame: Int, forceDelegate: Bool, revision: UInt) -> Bool {
        renderer?.display(frame: frame)
        currentFrame = renderer?.currentFrame
        guard let currentFrame else {
            currentProgress = 0
            return isCurrent(revision: revision)
        }
        currentProgress = absoluteProgress(for: currentFrame)
        if forceDelegate {
            delegate?.playerView(self, didDisplayFrame: currentFrame, progress: currentProgress)
        }
        return isCurrent(revision: revision)
    }

    func absoluteProgress(for frame: Int) -> Double {
        guard let video, video.frameCount > 1 else { return 0 }
        return Double(frame) / Double(video.frameCount - 1)
    }

    func pause(cancelAutomaticResume: Bool, revision: UInt) {
        guard isCurrent(revision: revision) else { return }
        guard playbackState == .playing, var timeline else {
            if cancelAutomaticResume { shouldResumeAfterInterruption = false }
            return
        }
        let output = timeline.pause(at: clockTimestamp)
        self.timeline = timeline
        consume(output, revision: revision)
        guard isCurrent(revision: revision), playbackState == .playing else { return }
        clock?.pause()
        audioScheduler?.pause()
        if cancelAutomaticResume { shouldResumeAfterInterruption = false }
        _ = changeState(.paused, revision: revision)
    }

    func applyEndBehavior(revision: UInt) -> Bool {
        guard isCurrent(revision: revision), let video else { return false }
        let range = playbackRange ?? 0...(video.frameCount - 1)
        switch endBehavior {
        case .clear:
            renderer?.display(frame: -1)
            currentFrame = nil
            currentProgress = 0
            return isCurrent(revision: revision)
        case .holdStartFrame:
            return display(
                frame: range.lowerBound,
                forceDelegate: currentFrame != range.lowerBound,
                revision: revision
            )
        case .holdEndFrame:
            return display(
                frame: range.upperBound,
                forceDelegate: currentFrame != range.upperBound,
                revision: revision
            )
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

    func startPlaybackAfterSeek(at frame: Int, revision: UInt) {
        guard isCurrent(revision: revision), var timeline else { return }
        didReportFinish = false
        shouldResumeAfterInterruption = false
        if interruptionReasons.isEmpty {
            timeline.resume(at: clockTimestamp)
            self.timeline = timeline
            audioScheduler?.seek(to: frame, reverse: isReversePlayback)
            audioScheduler?.resume()
            ensureClock().start()
            _ = changeState(.playing, revision: revision)
        } else {
            _ = timeline.pause(at: clockTimestamp)
            self.timeline = timeline
            clock?.pause()
            audioScheduler?.pause()
            audioScheduler?.seek(to: frame, reverse: isReversePlayback)
            shouldResumeAfterInterruption = true
            _ = changeState(.paused, revision: revision)
        }
    }

    func changeState(_ state: LYSVGAPlaybackState, revision: UInt) -> Bool {
        guard isCurrent(revision: revision) else { return false }
        guard playbackState != state else { return true }
        playbackState = state
        delegate?.playerView(self, didChangePlaybackState: state)
        return isCurrent(revision: revision)
    }

    func installNotificationsIfNeeded() {
        guard notificationsInstalled == false else { return }
        notificationCenter.addObserver(
            self,
            selector: #selector(applicationWillResignActive(_:)),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground(_:)),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground(_:)),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        notificationsInstalled = true
    }

    func removeNotifications() {
        guard notificationsInstalled else { return }
        notificationCenter.removeObserver(self)
        notificationsInstalled = false
    }

    @objc nonisolated func applicationWillResignActive(_ notification: Notification) {
        MainActor.assumeIsolated { beginInterruption(.applicationInactive) }
    }

    @objc nonisolated func applicationDidEnterBackground(_ notification: Notification) {
        MainActor.assumeIsolated { beginInterruption(.applicationBackground) }
    }

    @objc nonisolated func applicationWillEnterForeground(_ notification: Notification) {
        MainActor.assumeIsolated { endInterruption(.applicationBackground) }
    }

    @objc nonisolated func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { endInterruption(.applicationInactive) }
    }

    func beginInterruption(_ reason: LYSVGAPlayerInterruptionReason) {
        interruptionReasons.insert(reason)
        guard playbackState == .playing else { return }
        let revision = beginMutation()
        shouldResumeAfterInterruption = true
        pause(cancelAutomaticResume: false, revision: revision)
    }

    func endInterruption(_ reason: LYSVGAPlayerInterruptionReason) {
        interruptionReasons.remove(reason)
        guard interruptionReasons.isEmpty, shouldResumeAfterInterruption else { return }
        let revision = beginMutation()
        resume(revision: revision)
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
