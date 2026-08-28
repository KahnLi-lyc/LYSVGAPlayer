import Combine
import Foundation
import UIKit

@MainActor
public final class LYSVGAPlayerController: NSObject, ObservableObject {
    @Published public private(set) var playbackState: LYSVGAPlaybackState
    @Published public private(set) var currentFrame: Int?
    @Published public private(set) var currentProgress: Double
    @Published public private(set) var lastError: LYSVGAError?

    public let playerView: LYSVGAPlayerView
    public weak var delegate: (any LYSVGAPlayerViewDelegate)?

    public var video: LYSVGAVideo? { playerView.video }

    public var repeatMode: LYSVGARepeatMode {
        get { playerView.repeatMode }
        set { playerView.repeatMode = newValue }
    }

    public var endBehavior: LYSVGAEndBehavior {
        get { playerView.endBehavior }
        set { playerView.endBehavior = newValue }
    }

    public var playbackRate: Double {
        get { playerView.playbackRate }
        set { playerView.playbackRate = newValue }
    }

    public var allowsFrameSkipping: Bool {
        get { playerView.allowsFrameSkipping }
        set { playerView.allowsFrameSkipping = newValue }
    }

    public var isMuted: Bool {
        get { playerView.isMuted }
        set { playerView.isMuted = newValue }
    }

    public var audioVolume: Double {
        get { playerView.audioVolume }
        set { playerView.audioVolume = newValue }
    }

    public override convenience init() {
        self.init(playerView: LYSVGAPlayerView())
    }

    init(playerView: LYSVGAPlayerView) {
        self.playerView = playerView
        playbackState = playerView.playbackState
        currentFrame = playerView.currentFrame
        currentProgress = playerView.currentProgress
        super.init()
        playerView.delegate = self
    }

    public func setVideo(_ video: LYSVGAVideo) async throws {
        try await playerView.setVideo(video)
    }

    public func load(
        _ source: LYSVGASource,
        using loader: LYSVGAAssetLoader,
        cachePolicy: LYSVGACachePolicy = .automatic,
        autoplay: Bool = false
    ) async throws {
        try await playerView.load(
            source,
            using: loader,
            cachePolicy: cachePolicy,
            autoplay: autoplay
        )
    }

    public func play(range: ClosedRange<Int>? = nil, reverse: Bool = false) throws {
        try playerView.play(range: range, reverse: reverse)
    }

    public func pause() {
        playerView.pause()
    }

    public func resume() {
        playerView.resume()
    }

    public func stop() {
        playerView.stop()
    }

    public func clear() {
        playerView.clear()
    }

    public func seek(toFrame frame: Int, andPlay: Bool = false) {
        playerView.seek(toFrame: frame, andPlay: andPlay)
    }

    public func seek(toProgress progress: Double, andPlay: Bool = false) {
        playerView.seek(toProgress: progress, andPlay: andPlay)
    }
}

@MainActor
extension LYSVGAPlayerController: LYSVGAPlayerViewDelegate {
    public func playerView(
        _ playerView: LYSVGAPlayerView,
        didChangePlaybackState state: LYSVGAPlaybackState
    ) {
        playbackState = state
        currentFrame = playerView.currentFrame
        currentProgress = playerView.currentProgress
        if state == .loading {
            lastError = nil
        }
        delegate?.playerView(playerView, didChangePlaybackState: state)
    }

    public func playerView(
        _ playerView: LYSVGAPlayerView,
        didDisplayFrame frame: Int,
        progress: Double
    ) {
        currentFrame = frame
        currentProgress = progress
        delegate?.playerView(playerView, didDisplayFrame: frame, progress: progress)
    }

    public func playerView(_ playerView: LYSVGAPlayerView, didCrossLoops count: UInt) {
        delegate?.playerView(playerView, didCrossLoops: count)
    }

    public func playerViewDidFinish(_ playerView: LYSVGAPlayerView) {
        delegate?.playerViewDidFinish(playerView)
    }

    public func playerView(_ playerView: LYSVGAPlayerView, didFailWith error: LYSVGAError) {
        lastError = error
        delegate?.playerView(playerView, didFailWith: error)
    }
}
