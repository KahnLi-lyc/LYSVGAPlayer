import Foundation

enum LYSVGAV1Decoder {
    static func decode(_ data: Data, resourceDirectory: URL) throws -> LYSVGAVideo {
        try decode(data) { filename, key, fallbackExtension in
            try LYSVGAResourceResolver.resolve(
                filename: filename,
                key: key,
                directory: resourceDirectory,
                fallbackExtension: fallbackExtension
            )
        }
    }

    static func decode(_ data: Data, resources: [String: Data]) throws -> LYSVGAVideo {
        try decode(data) { filename, key, fallbackExtension in
            try LYSVGAResourceResolver.resolve(
                filename: filename,
                key: key,
                resources: resources,
                fallbackExtension: fallbackExtension
            )
        }
    }

    private static func decode(
        _ data: Data,
        resolveResource: (_ filename: String, _ key: String, _ fallbackExtension: String?) throws -> Data
    ) throws -> LYSVGAVideo {
        let spec: V1Spec
        do {
            spec = try JSONDecoder().decode(V1Spec.self, from: data)
        } catch {
            throw LYSVGAError.jsonFailure(error.localizedDescription)
        }
        try Task.checkCancellation()

        var images: [String: Data] = [:]
        for (key, filename) in spec.images {
            try Task.checkCancellation()
            images[LYSVGAResourceKey.canonicalize(key)] = try resolveResource(filename, key, "png")
        }

        var audioData: [String: Data] = [:]
        for audio in spec.audios where audio.audioKey.isEmpty == false {
            let candidates = [audio.audioKey, (audio.audioKey as NSString).appendingPathExtension("mp3")]
                .compactMap { $0 }
            for filename in candidates {
                do {
                    audioData[audio.audioKey] = try resolveResource(filename, audio.audioKey, nil)
                    break
                } catch LYSVGAError.missingResource(_) {
                    continue
                }
            }
        }

        return try LYSVGAVideo(
            version: spec.ver,
            canvasSize: LYSVGASize(width: spec.movie.viewBox.width, height: spec.movie.viewBox.height),
            fps: spec.movie.fps,
            frameCount: spec.movie.frames,
            images: images,
            audioData: audioData,
            sprites: spec.sprites.map(mapSprite),
            audios: spec.audios.map {
                LYSVGAAudioCue(
                    audioKey: $0.audioKey,
                    startFrame: $0.startFrame,
                    endFrame: $0.endFrame,
                    startTime: $0.startTime,
                    totalTime: $0.totalTime
                )
            }
        )
    }

    private static func mapSprite(_ sprite: V1Sprite) -> LYSVGASprite {
        LYSVGASprite(
            imageKey: sprite.imageKey,
            frames: sprite.frames.map(mapFrame),
            matteKey: sprite.matteKey.isEmpty ? nil : sprite.matteKey
        )
    }

    private static func mapFrame(_ frame: V1Frame) -> LYSVGAFrame {
        LYSVGAFrame(
            alpha: frame.alpha,
            layout: LYSVGARect(
                x: frame.layout.x, y: frame.layout.y,
                width: frame.layout.width, height: frame.layout.height
            ),
            transform: mapTransform(frame.transform),
            clipPath: frame.clipPath?.isEmpty == false ? frame.clipPath : nil,
            shapes: frame.shapes.map(mapShape)
        )
    }

    private static func mapShape(_ shape: V1Shape) -> LYSVGAShape {
        let type: LYSVGAShapeType
        switch shape.type.lowercased() {
        case "rect":
            type = .rect(LYSVGAShapeRect(
                rect: LYSVGARect(
                    x: shape.args.x, y: shape.args.y,
                    width: shape.args.width, height: shape.args.height
                ),
                cornerRadius: shape.args.cornerRadius
            ))
        case "ellipse":
            type = .ellipse(LYSVGAShapeEllipse(
                centerX: shape.args.x, centerY: shape.args.y,
                radiusX: shape.args.radiusX, radiusY: shape.args.radiusY
            ))
        case "keep":
            type = .keep
        default:
            type = .path(LYSVGAShapePath(path: shape.args.d))
        }

        let style = LYSVGAShapeStyle(
            fill: color(shape.styles.fill),
            stroke: color(shape.styles.stroke),
            strokeWidth: shape.styles.strokeWidth,
            lineCap: LYSVGALineCap(rawValue: shape.styles.lineCap.lowercased()) ?? .butt,
            lineJoin: LYSVGALineJoin(rawValue: shape.styles.lineJoin.lowercased()) ?? .miter,
            miterLimit: shape.styles.miterLimit,
            lineDash: shape.styles.lineDash
        )
        return LYSVGAShape(type: type, style: style, transform: mapTransform(shape.transform))
    }

    private static func color(_ components: [Double]?) -> LYSVGAColor? {
        guard let components, components.count >= 4 else { return nil }
        return LYSVGAColor(
            red: components[0], green: components[1],
            blue: components[2], alpha: components[3]
        )
    }

    private static func mapTransform(_ value: V1Transform) -> LYSVGATransform {
        LYSVGATransform(a: value.a, b: value.b, c: value.c, d: value.d, tx: value.tx, ty: value.ty)
    }

}

private struct V1Spec: Decodable {
    let ver: String
    let movie: V1Movie
    let images: [String: String]
    let sprites: [V1Sprite]
    let audios: [V1Audio]

    private enum CodingKeys: String, CodingKey { case ver, movie, images, sprites, audios }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ver = try container.decodeIfPresent(String.self, forKey: .ver) ?? "1.0"
        movie = try container.decode(V1Movie.self, forKey: .movie)
        images = try container.decodeIfPresent([String: String].self, forKey: .images) ?? [:]
        sprites = try container.decodeIfPresent([V1Sprite].self, forKey: .sprites) ?? []
        audios = try container.decodeIfPresent([V1Audio].self, forKey: .audios) ?? []
    }
}

private struct V1Movie: Decodable {
    let viewBox: V1Rect
    let fps: Int
    let frames: Int
}

private struct V1Sprite: Decodable {
    let imageKey: String
    let frames: [V1Frame]
    let matteKey: String

    private enum CodingKeys: String, CodingKey { case imageKey, frames, matteKey }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        imageKey = try container.decodeIfPresent(String.self, forKey: .imageKey) ?? ""
        frames = try container.decodeIfPresent([V1Frame].self, forKey: .frames) ?? []
        matteKey = try container.decodeIfPresent(String.self, forKey: .matteKey) ?? ""
    }
}

private struct V1Frame: Decodable {
    let alpha: Double
    let layout: V1Rect
    let transform: V1Transform
    let clipPath: String?
    let shapes: [V1Shape]

    private enum CodingKeys: String, CodingKey { case alpha, layout, transform, clipPath, shapes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alpha = try container.decodeIfPresent(Double.self, forKey: .alpha) ?? 0
        layout = try container.decodeIfPresent(V1Rect.self, forKey: .layout) ?? V1Rect()
        transform = try container.decodeIfPresent(V1Transform.self, forKey: .transform) ?? V1Transform()
        clipPath = try container.decodeIfPresent(String.self, forKey: .clipPath)
        shapes = try container.decodeIfPresent([V1Shape].self, forKey: .shapes) ?? []
    }
}

private struct V1Shape: Decodable {
    let type: String
    let args: V1ShapeArgs
    let styles: V1Style
    let transform: V1Transform

    private enum CodingKeys: String, CodingKey { case type, args, styles, transform }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "shape"
        args = try container.decodeIfPresent(V1ShapeArgs.self, forKey: .args) ?? V1ShapeArgs()
        styles = try container.decodeIfPresent(V1Style.self, forKey: .styles) ?? V1Style()
        transform = try container.decodeIfPresent(V1Transform.self, forKey: .transform) ?? V1Transform()
    }
}

private struct V1Rect: Decodable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 0
    var height: Double = 0

    private enum CodingKeys: String, CodingKey { case x, y, width, height }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 0
        height = try container.decodeIfPresent(Double.self, forKey: .height) ?? 0
    }
}

private struct V1Transform: Decodable {
    var a: Double = 1
    var b: Double = 0
    var c: Double = 0
    var d: Double = 1
    var tx: Double = 0
    var ty: Double = 0

    private enum CodingKeys: String, CodingKey { case a, b, c, d, tx, ty }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        a = try container.decodeIfPresent(Double.self, forKey: .a) ?? 1
        b = try container.decodeIfPresent(Double.self, forKey: .b) ?? 0
        c = try container.decodeIfPresent(Double.self, forKey: .c) ?? 0
        d = try container.decodeIfPresent(Double.self, forKey: .d) ?? 1
        tx = try container.decodeIfPresent(Double.self, forKey: .tx) ?? 0
        ty = try container.decodeIfPresent(Double.self, forKey: .ty) ?? 0
    }
}

private struct V1ShapeArgs: Decodable {
    var d: String = ""
    var x: Double = 0
    var y: Double = 0
    var width: Double = 0
    var height: Double = 0
    var cornerRadius: Double = 0
    var radiusX: Double = 0
    var radiusY: Double = 0

    private enum CodingKeys: String, CodingKey {
        case d, x, y, width, height, cornerRadius, radiusX, radiusY
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        d = try container.decodeIfPresent(String.self, forKey: .d) ?? ""
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 0
        height = try container.decodeIfPresent(Double.self, forKey: .height) ?? 0
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        radiusX = try container.decodeIfPresent(Double.self, forKey: .radiusX) ?? 0
        radiusY = try container.decodeIfPresent(Double.self, forKey: .radiusY) ?? 0
    }
}

private struct V1Style: Decodable {
    var fill: [Double]?
    var stroke: [Double]?
    var strokeWidth: Double = 0
    var lineCap: String = "butt"
    var lineJoin: String = "miter"
    var miterLimit: Double = 0
    var lineDash: [Double] = []

    private enum CodingKeys: String, CodingKey {
        case fill, stroke, strokeWidth, lineCap, lineJoin, miterLimit
        case lineDash
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fill = try container.decodeIfPresent([Double].self, forKey: .fill)
        stroke = try container.decodeIfPresent([Double].self, forKey: .stroke)
        strokeWidth = try container.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 0
        lineCap = try container.decodeIfPresent(String.self, forKey: .lineCap) ?? "butt"
        lineJoin = try container.decodeIfPresent(String.self, forKey: .lineJoin) ?? "miter"
        miterLimit = try container.decodeIfPresent(Double.self, forKey: .miterLimit) ?? 0
        lineDash = try container.decodeIfPresent([Double].self, forKey: .lineDash) ?? []
    }
}

private struct V1Audio: Decodable {
    var audioKey: String = ""
    var startFrame: Int = 0
    var endFrame: Int = 0
    var startTime: Int = 0
    var totalTime: Int = 0

    private enum CodingKeys: String, CodingKey {
        case audioKey, startFrame, endFrame, startTime, totalTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        audioKey = try container.decodeIfPresent(String.self, forKey: .audioKey) ?? ""
        startFrame = try container.decodeIfPresent(Int.self, forKey: .startFrame) ?? 0
        endFrame = try container.decodeIfPresent(Int.self, forKey: .endFrame) ?? 0
        startTime = try container.decodeIfPresent(Int.self, forKey: .startTime) ?? 0
        totalTime = try container.decodeIfPresent(Int.self, forKey: .totalTime) ?? 0
    }
}
