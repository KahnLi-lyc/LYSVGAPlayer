import Foundation

@MainActor
final class LYSVGAAudioScheduler {
    private struct Entry {
        let cue: LYSVGAAudioCue
        let player: any LYSVGAAudioPlaying
        var isActive = false
    }

    private let factory: any LYSVGAAudioPlayerFactory
    private var entries: [Entry] = []
    private var fps = 1
    private var isPaused = false
    private var storedPlaybackRate = 1.0
    private var storedAudioVolume = 1.0

    var playbackRate: Double {
        get { storedPlaybackRate }
        set {
            storedPlaybackRate = LYSVGAPlaybackRate.clamped(newValue)
            applyRate()
        }
    }

    var audioVolume: Double {
        get { storedAudioVolume }
        set {
            storedAudioVolume = clampedVolume(newValue)
            applyVolume()
        }
    }

    var isMuted = false {
        didSet { applyVolume() }
    }

    var preparedPlayerCount: Int {
        entries.count
    }

    init(factory: any LYSVGAAudioPlayerFactory = LYSVGASystemAudioPlayerFactory()) {
        self.factory = factory
    }

    func prepare(video: LYSVGAVideo) throws {
        clear()
        fps = video.fps

        var preparedEntries: [Entry] = []
        do {
            for cue in video.audios {
                guard let data = video.audioData[cue.audioKey] else {
                    throw LYSVGAError.audioPreparationFailure(
                        audioKey: cue.audioKey,
                        reason: "Audio data is missing."
                    )
                }

                let player: any LYSVGAAudioPlaying
                do {
                    player = try factory.makePlayer(data: data)
                } catch {
                    throw LYSVGAError.audioPreparationFailure(
                        audioKey: cue.audioKey,
                        reason: error.localizedDescription
                    )
                }
                configure(player)
                guard player.prepareToPlay() else {
                    player.stop()
                    throw LYSVGAError.audioPreparationFailure(
                        audioKey: cue.audioKey,
                        reason: "Audio player preparation failed."
                    )
                }
                preparedEntries.append(Entry(cue: cue, player: player))
            }
        } catch {
            preparedEntries.forEach { $0.player.stop() }
            throw error
        }

        entries = preparedEntries
    }

    func synchronize(frame: Int, reverse: Bool) {
        synchronize(frame: frame, reverse: reverse, force: false)
    }

    func seek(to frame: Int, reverse: Bool) {
        synchronize(frame: frame, reverse: reverse, force: true)
    }

    func loop(at frame: Int, reverse: Bool) {
        synchronize(frame: frame, reverse: reverse, force: true)
    }

    func pause() {
        guard isPaused == false else { return }
        isPaused = true
        for entry in entries where entry.isActive {
            entry.player.pause()
        }
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        for index in entries.indices where entries[index].isActive {
            entries[index].isActive = entries[index].player.play()
        }
    }

    func stop() {
        for index in entries.indices {
            entries[index].player.stop()
            entries[index].isActive = false
        }
        isPaused = false
    }

    func clear() {
        entries.forEach { $0.player.stop() }
        entries.removeAll()
        isPaused = false
    }

    private func synchronize(frame: Int, reverse: Bool, force: Bool) {
        if force {
            for index in entries.indices {
                entries[index].player.stop()
                entries[index].isActive = false
            }
        }

        for index in entries.indices {
            let cue = entries[index].cue
            let isInCueRange = reverse == false && frame >= cue.startFrame && frame < cue.endFrame
            if isInCueRange {
                guard entries[index].isActive == false else { continue }
                entries[index].player.currentTime = currentTime(
                    for: cue,
                    frame: frame,
                    duration: entries[index].player.duration
                )
                entries[index].isActive = isPaused || entries[index].player.play()
            } else if entries[index].isActive {
                entries[index].player.stop()
                entries[index].isActive = false
            }
        }
    }

    private func currentTime(for cue: LYSVGAAudioCue, frame: Int, duration: TimeInterval) -> TimeInterval {
        let rawOffset = TimeInterval(cue.startTime) / 1_000
            + TimeInterval(frame - cue.startFrame) / TimeInterval(fps)
        let validDuration = duration.isFinite ? max(0, duration) : 0
        return min(validDuration, max(0, rawOffset))
    }

    private func configure(_ player: any LYSVGAAudioPlaying) {
        player.enableRate = true
        player.rate = Float(storedPlaybackRate)
        player.volume = Float(isMuted ? 0 : storedAudioVolume)
    }

    private func applyRate() {
        for entry in entries {
            entry.player.enableRate = true
            entry.player.rate = Float(storedPlaybackRate)
        }
    }

    private func applyVolume() {
        let volume = Float(isMuted ? 0 : storedAudioVolume)
        entries.forEach { $0.player.volume = volume }
    }

    private func clampedVolume(_ value: Double) -> Double {
        guard value.isNaN == false else { return 1 }
        return min(1, max(0, value))
    }
}
