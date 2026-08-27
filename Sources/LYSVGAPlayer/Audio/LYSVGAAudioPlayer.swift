import AVFoundation
import Foundation

@MainActor
protocol LYSVGAAudioPlaying: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var volume: Float { get set }
    var rate: Float { get set }
    var enableRate: Bool { get set }
    var isPlaying: Bool { get }

    func prepareToPlay() -> Bool
    func play() -> Bool
    func pause()
    func stop()
}

@MainActor
protocol LYSVGAAudioPlayerFactory {
    func makePlayer(data: Data) throws -> any LYSVGAAudioPlaying
}

@MainActor
struct LYSVGASystemAudioPlayerFactory: LYSVGAAudioPlayerFactory {
    func makePlayer(data: Data) throws -> any LYSVGAAudioPlaying {
        try LYSVGASystemAudioPlayer(player: AVAudioPlayer(data: data))
    }
}

@MainActor
private final class LYSVGASystemAudioPlayer: LYSVGAAudioPlaying {
    private let player: AVAudioPlayer

    var duration: TimeInterval { player.duration }
    var isPlaying: Bool { player.isPlaying }

    var currentTime: TimeInterval {
        get { player.currentTime }
        set { player.currentTime = newValue }
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    var enableRate: Bool {
        get { player.enableRate }
        set { player.enableRate = newValue }
    }

    init(player: AVAudioPlayer) {
        self.player = player
    }

    func prepareToPlay() -> Bool {
        player.prepareToPlay()
    }

    func play() -> Bool {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.stop()
    }
}
