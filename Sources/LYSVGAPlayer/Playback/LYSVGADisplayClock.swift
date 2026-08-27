import QuartzCore

@MainActor
protocol LYSVGADisplayClock: AnyObject {
    var timestamp: TimeInterval { get }

    func start()
    func pause()
    func invalidate()
}

@MainActor
final class LYSVGADisplayLinkClock: LYSVGADisplayClock {
    private let handler: (TimeInterval) -> Void
    private var displayLink: CADisplayLink?

    var timestamp: TimeInterval {
        CACurrentMediaTime()
    }

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
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func pause() {
        displayLink?.isPaused = true
    }

    func invalidate() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func tick(at timestamp: TimeInterval) {
        handler(timestamp)
    }

    isolated deinit {
        displayLink?.invalidate()
    }
}

@MainActor
private final class LYSVGADisplayLinkProxy: NSObject {
    weak var owner: LYSVGADisplayLinkClock?

    init(owner: LYSVGADisplayLinkClock) {
        self.owner = owner
    }

    @objc func tick(_ displayLink: CADisplayLink) {
        owner?.tick(at: displayLink.timestamp)
    }
}
