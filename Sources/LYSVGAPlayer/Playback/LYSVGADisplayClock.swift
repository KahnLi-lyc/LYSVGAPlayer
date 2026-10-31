import Foundation
import QuartzCore

@MainActor
protocol LYSVGADisplayClock: AnyObject {
    var timestamp: TimeInterval { get }
    var runLoopMode: RunLoop.Mode { get set }
    /// Content frame rate (video FPS × playback rate); `0` leaves the system default.
    var preferredFramesPerSecond: Double { get set }

    func start()
    func pause()
    func invalidate()
}

extension LYSVGADisplayClock {
    var preferredFramesPerSecond: Double {
        get { 0 }
        set {}
    }
}

@MainActor
final class LYSVGADisplayLinkClock: LYSVGADisplayClock {
    private let handler: (TimeInterval) -> Void
    private var displayLink: CADisplayLink?

    var runLoopMode: RunLoop.Mode = .common {
        didSet {
            guard runLoopMode != oldValue, let displayLink else { return }
            displayLink.remove(from: .main, forMode: oldValue)
            displayLink.add(to: .main, forMode: runLoopMode)
            scheduledRunLoopModeForTesting = runLoopMode
        }
    }

    var preferredFramesPerSecond: Double = 0 {
        didSet {
            guard preferredFramesPerSecond != oldValue, let displayLink else { return }
            displayLink.preferredFrameRateRange = Self.frameRateRange(for: preferredFramesPerSecond)
        }
    }

    var timestamp: TimeInterval {
        CACurrentMediaTime()
    }

    var preferredFrameRateRangeForTesting: CAFrameRateRange? {
        displayLink?.preferredFrameRateRange
    }

    /// Lets the system tick at the content rate (for example 20 Hz for a 20 FPS movie) instead of
    /// the full display refresh rate, which saves main-thread wakeups and allows ProMotion to idle.
    static func frameRateRange(for framesPerSecond: Double) -> CAFrameRateRange {
        guard framesPerSecond.isFinite, framesPerSecond > 0 else { return .default }
        let preferred = Float(min(framesPerSecond.rounded(.up), 120))
        return CAFrameRateRange(minimum: preferred, maximum: min(preferred * 2, 120), preferred: preferred)
    }

    var hasScheduledDisplayLinkForTesting: Bool {
        displayLink != nil
    }

    private(set) var scheduledRunLoopModeForTesting: RunLoop.Mode?

    init(handler: @escaping (TimeInterval) -> Void) {
        self.handler = handler
    }

    func start() {
        if let displayLink {
            displayLink.isPaused = false
            return
        }

        let proxy = LYSVGADisplayLinkProxy(owner: self)
        let displayLink = CADisplayLink(target: proxy, selector: #selector(LYSVGADisplayLinkProxy.tick(_:)))
        displayLink.preferredFrameRateRange = Self.frameRateRange(for: preferredFramesPerSecond)
        displayLink.add(to: .main, forMode: runLoopMode)
        self.displayLink = displayLink
        scheduledRunLoopModeForTesting = runLoopMode
    }

    func pause() {
        displayLink?.invalidate()
        displayLink = nil
        scheduledRunLoopModeForTesting = nil
    }

    func invalidate() {
        displayLink?.invalidate()
        displayLink = nil
        scheduledRunLoopModeForTesting = nil
    }

    fileprivate func tick(at timestamp: TimeInterval) {
        handler(timestamp)
    }
}

@MainActor
private final class LYSVGADisplayLinkProxy: NSObject {
    weak var owner: LYSVGADisplayLinkClock?

    init(owner: LYSVGADisplayLinkClock) {
        self.owner = owner
    }

    @objc func tick(_ displayLink: CADisplayLink) {
        guard let owner else {
            displayLink.invalidate()
            return
        }
        owner.tick(at: displayLink.timestamp)
    }
}
