import Foundation
import SwiftProtobuf

enum LYSVGAV2Decoder {
    static func decode(_ protobufData: Data, resourceDirectory: URL? = nil) throws -> LYSVGAVideo {
        try decode(protobufData, resourceDirectory: resourceDirectory, resources: nil)
    }

    static func decode(_ protobufData: Data, resources: [String: Data]) throws -> LYSVGAVideo {
        try decode(protobufData, resourceDirectory: nil, resources: resources)
    }

    private static func decode(
        _ protobufData: Data,
        resourceDirectory: URL?,
        resources: [String: Data]?
    ) throws -> LYSVGAVideo {
        try Task.checkCancellation()
        let movie: Com_Opensource_Svga_MovieEntity
        do {
            movie = try Com_Opensource_Svga_MovieEntity(serializedBytes: protobufData)
        } catch {
            throw LYSVGAError.protobufFailure(error.localizedDescription)
        }
        try Task.checkCancellation()

        let audioKeys = movie.audios.map(\.audioKey)
        var images: [String: Data] = [:]
        var audioData: [String: Data] = [:]
        for (key, value) in movie.images {
            try Task.checkCancellation()
            let resolved = try resolve(
                value,
                key: key,
                resourceDirectory: resourceDirectory,
                resources: resources
            )
            if let audioKey = audioKeys.first(where: { resourceKey(key, matchesAudioKey: $0) }) {
                audioData[audioKey] = resolved
            } else {
                images[LYSVGAResourceKey.canonicalize(key)] = resolved
            }
        }

        let sprites = movie.sprites.map { sprite in
            LYSVGASprite(
                imageKey: sprite.imageKey,
                frames: sprite.frames.map(mapFrame),
                matteKey: sprite.matteKey.isEmpty ? nil : sprite.matteKey
            )
        }
        let audios = movie.audios.map {
            LYSVGAAudioCue(
                audioKey: $0.audioKey,
                startFrame: Int($0.startFrame),
                endFrame: Int($0.endFrame),
                startTime: Int($0.startTime),
                totalTime: Int($0.totalTime)
            )
        }

        return try LYSVGAVideo(
            version: movie.version,
            canvasSize: LYSVGASize(
                width: Double(movie.params.viewBoxWidth),
                height: Double(movie.params.viewBoxHeight)
            ),
            fps: Int(movie.params.fps),
            frameCount: Int(movie.params.frames),
            images: images,
            audioData: audioData,
            sprites: sprites,
            audios: audios
        )
    }

    private static func mapFrame(_ frame: Com_Opensource_Svga_FrameEntity) -> LYSVGAFrame {
        LYSVGAFrame(
            alpha: Double(frame.alpha),
            layout: LYSVGAModelMapper.rect(
                x: frame.layout.x, y: frame.layout.y,
                width: frame.layout.width, height: frame.layout.height
            ),
            transform: frame.hasTransform ? LYSVGAModelMapper.transform(frame.transform) : .identity,
            clipPath: frame.clipPath.isEmpty ? nil : frame.clipPath,
            shapes: frame.shapes.map(mapShape)
        )
    }

    private static func mapShape(_ shape: Com_Opensource_Svga_ShapeEntity) -> LYSVGAShape {
        let type: LYSVGAShapeType
        switch shape.type {
        case .shape:
            type = .path(LYSVGAShapePath(path: shape.shape.d))
        case .rect:
            type = .rect(LYSVGAShapeRect(
                rect: LYSVGAModelMapper.rect(
                    x: shape.rect.x, y: shape.rect.y,
                    width: shape.rect.width, height: shape.rect.height
                ),
                cornerRadius: Double(shape.rect.cornerRadius)
            ))
        case .ellipse:
            type = .ellipse(LYSVGAShapeEllipse(
                centerX: Double(shape.ellipse.x), centerY: Double(shape.ellipse.y),
                radiusX: Double(shape.ellipse.radiusX), radiusY: Double(shape.ellipse.radiusY)
            ))
        case .keep, .UNRECOGNIZED:
            type = .keep
        }

        let styles = shape.styles
        let style = LYSVGAShapeStyle(
            fill: shape.hasStyles && styles.hasFill ? LYSVGAModelMapper.color(styles.fill) : nil,
            stroke: shape.hasStyles && styles.hasStroke ? LYSVGAModelMapper.color(styles.stroke) : nil,
            strokeWidth: Double(styles.strokeWidth),
            lineCap: mapLineCap(styles.lineCap),
            lineJoin: mapLineJoin(styles.lineJoin),
            miterLimit: Double(styles.miterLimit),
            lineDash: [styles.lineDashI, styles.lineDashIi, styles.lineDashIii].map(Double.init)
        )
        return LYSVGAShape(
            type: type,
            style: style,
            transform: shape.hasTransform ? LYSVGAModelMapper.transform(shape.transform) : .identity
        )
    }

    private static func mapLineCap(_ value: Com_Opensource_Svga_ShapeEntity.ShapeStyle.LineCap) -> LYSVGALineCap {
        switch value {
        case .round: .round
        case .square: .square
        default: .butt
        }
    }

    private static func mapLineJoin(_ value: Com_Opensource_Svga_ShapeEntity.ShapeStyle.LineJoin) -> LYSVGALineJoin {
        switch value {
        case .round: .round
        case .bevel: .bevel
        default: .miter
        }
    }

    private static func resolve(
        _ value: Data,
        key: String,
        resourceDirectory: URL?,
        resources: [String: Data]?
    ) throws -> Data {
        guard resourceDirectory != nil || resources != nil else {
            return value
        }
        guard let filename = String(data: value, encoding: .utf8),
              filename.isEmpty == false,
              filename.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) == false }) else {
            return value
        }
        if let resources {
            return try LYSVGAResourceResolver.resolve(
                filename: filename,
                key: key,
                resources: resources,
                fallbackExtension: "png"
            )
        }
        return try LYSVGAResourceResolver.resolve(
            filename: filename,
            key: key,
            directory: resourceDirectory!,
            fallbackExtension: "png"
        )
    }

    private static func resourceKey(_ resourceKey: String, matchesAudioKey audioKey: String) -> Bool {
        resourceKey == audioKey
            || (resourceKey as NSString).lastPathComponent == (audioKey as NSString).lastPathComponent
            || deletingPathExtension(resourceKey) == deletingPathExtension(audioKey)
    }

    private static func deletingPathExtension(_ value: String) -> String {
        (value as NSString).deletingPathExtension
    }
}
