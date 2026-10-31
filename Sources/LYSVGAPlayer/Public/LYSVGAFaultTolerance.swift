import Foundation

/// Controls how damaged or incomplete resources inside an SVGA file are handled.
///
/// SVGAPlayer-iOS silently skips images that cannot be decoded, missing archive files and
/// audio that cannot be created, and keeps playing the rest of the animation. `.lenient`
/// follows that behavior but reports every skipped item as an ``LYSVGAWarning``.
/// `.strict` fails the whole load or preparation on the first resource problem.
public enum LYSVGAFaultTolerance: Equatable, Sendable {
    case lenient
    case strict
}

/// A recoverable problem that was skipped while decoding or preparing an SVGA file.
public enum LYSVGAWarning: Equatable, Sendable {
    /// A resource referenced by the movie is missing from the archive or directory.
    case missingResource(key: String)
    /// An image could not be decoded; sprites using it render without a bitmap.
    case imageDecodingFailed(key: String)
    /// An audio cue could not be prepared; playback continues without that audio.
    case audioUnavailable(audioKey: String, reason: String)
    /// A sprite contained more frames than the movie; the extra frames were dropped.
    case spriteFramesTrimmed(imageKey: String, frameCount: Int)
    /// An audio cue had an empty key or an invalid frame range and was ignored.
    case invalidAudioCueSkipped(audioKey: String)
}

/// Repairs model-level inconsistencies before a decoded movie is validated.
enum LYSVGAModelSanitizer {
    static func sanitize(
        sprites: [LYSVGASprite],
        audios: [LYSVGAAudioCue],
        frameCount: Int,
        faultTolerance: LYSVGAFaultTolerance
    ) -> (sprites: [LYSVGASprite], audios: [LYSVGAAudioCue], warnings: [LYSVGAWarning]) {
        guard faultTolerance == .lenient else {
            return (sprites, audios, [])
        }

        var warnings: [LYSVGAWarning] = []
        var sanitizedSprites = sprites
        if frameCount > 0 {
            for index in sanitizedSprites.indices where sanitizedSprites[index].frames.count > frameCount {
                let sprite = sanitizedSprites[index]
                sanitizedSprites[index] = LYSVGASprite(
                    imageKey: sprite.imageKey,
                    frames: Array(sprite.frames.prefix(frameCount)),
                    matteKey: sprite.matteKey
                )
                warnings.append(.spriteFramesTrimmed(imageKey: sprite.imageKey, frameCount: sprite.frames.count))
            }
        }

        var sanitizedAudios: [LYSVGAAudioCue] = []
        sanitizedAudios.reserveCapacity(audios.count)
        for cue in audios {
            if cue.audioKey.isEmpty == false, cue.startFrame >= 0, cue.endFrame >= cue.startFrame {
                sanitizedAudios.append(cue)
            } else {
                warnings.append(.invalidAudioCueSkipped(audioKey: cue.audioKey))
            }
        }
        return (sanitizedSprites, sanitizedAudios, warnings)
    }
}
