import Foundation

public struct LYSVGAFrame: Codable, Equatable, Sendable {
    public let alpha: Double
    public let layout: LYSVGARect
    public let transform: LYSVGATransform
    public let clipPath: String?
    public let shapes: [LYSVGAShape]

    public init(
        alpha: Double,
        layout: LYSVGARect,
        transform: LYSVGATransform,
        clipPath: String? = nil,
        shapes: [LYSVGAShape] = []
    ) {
        self.alpha = alpha
        self.layout = layout
        self.transform = transform
        self.clipPath = clipPath
        self.shapes = shapes
    }
}

public struct LYSVGASprite: Codable, Equatable, Sendable {
    public let imageKey: String
    public let frames: [LYSVGAFrame]
    public let matteKey: String?

    public init(imageKey: String, frames: [LYSVGAFrame], matteKey: String? = nil) {
        self.imageKey = imageKey
        self.frames = frames
        self.matteKey = matteKey
    }
}

public struct LYSVGAAudioCue: Codable, Equatable, Sendable {
    public let audioKey: String
    public let startFrame: Int
    public let endFrame: Int
    public let startTime: Int
    public let totalTime: Int

    public init(audioKey: String, startFrame: Int, endFrame: Int, startTime: Int, totalTime: Int) {
        self.audioKey = audioKey
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.startTime = startTime
        self.totalTime = totalTime
    }
}

public struct LYSVGAVideo: Codable, Equatable, Sendable {
    public let version: String
    public let canvasSize: LYSVGASize
    public let fps: Int
    public let frameCount: Int
    public let images: [String: Data]
    public let audioData: [String: Data]
    public let sprites: [LYSVGASprite]
    public let audios: [LYSVGAAudioCue]

    public var duration: TimeInterval {
        TimeInterval(frameCount) / TimeInterval(fps)
    }

    private enum CodingKeys: String, CodingKey {
        case version, canvasSize, fps, frameCount, images, audioData, sprites, audios
    }

    public init(
        version: String,
        canvasSize: LYSVGASize,
        fps: Int,
        frameCount: Int,
        images: [String: Data],
        audioData: [String: Data],
        sprites: [LYSVGASprite],
        audios: [LYSVGAAudioCue]
    ) throws {
        guard canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width > 0, canvasSize.height > 0 else {
            throw LYSVGAError.invalidModel("Canvas dimensions must be finite and greater than zero.")
        }
        guard fps > 0 else {
            throw LYSVGAError.invalidModel("FPS must be greater than zero.")
        }
        guard frameCount > 0 else {
            throw LYSVGAError.invalidModel("Frame count must be greater than zero.")
        }
        guard sprites.allSatisfy({ $0.frames.count <= frameCount }) else {
            throw LYSVGAError.invalidModel("A sprite contains more frames than the movie.")
        }
        guard audios.allSatisfy({ cue in
            cue.startFrame >= 0 && cue.endFrame >= cue.startFrame && cue.audioKey.isEmpty == false
        }) else {
            throw LYSVGAError.invalidModel("An audio cue contains an invalid frame range or key.")
        }

        self.version = version
        self.canvasSize = canvasSize
        self.fps = fps
        self.frameCount = frameCount
        self.images = images
        self.audioData = audioData
        self.sprites = sprites
        self.audios = audios
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try LYSVGAVideo(
            version: container.decode(String.self, forKey: .version),
            canvasSize: container.decode(LYSVGASize.self, forKey: .canvasSize),
            fps: container.decode(Int.self, forKey: .fps),
            frameCount: container.decode(Int.self, forKey: .frameCount),
            images: container.decode([String: Data].self, forKey: .images),
            audioData: container.decode([String: Data].self, forKey: .audioData),
            sprites: container.decode([LYSVGASprite].self, forKey: .sprites),
            audios: container.decode([LYSVGAAudioCue].self, forKey: .audios)
        )
    }
}
