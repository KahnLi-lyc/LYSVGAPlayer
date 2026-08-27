import Foundation

public enum LYSVGALineCap: String, Codable, CaseIterable, Sendable {
    case butt
    case round
    case square
}

public enum LYSVGALineJoin: String, Codable, CaseIterable, Sendable {
    case miter
    case round
    case bevel
}

public struct LYSVGAShapeStyle: Codable, Equatable, Sendable {
    public let fill: LYSVGAColor?
    public let stroke: LYSVGAColor?
    public let strokeWidth: Double
    public let lineCap: LYSVGALineCap
    public let lineJoin: LYSVGALineJoin
    public let miterLimit: Double
    public let lineDash: [Double]

    public init(
        fill: LYSVGAColor? = nil,
        stroke: LYSVGAColor? = nil,
        strokeWidth: Double = 0,
        lineCap: LYSVGALineCap = .butt,
        lineJoin: LYSVGALineJoin = .miter,
        miterLimit: Double = 0,
        lineDash: [Double] = []
    ) {
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.lineCap = lineCap
        self.lineJoin = lineJoin
        self.miterLimit = miterLimit
        self.lineDash = lineDash
    }
}

public struct LYSVGAShapePath: Codable, Equatable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

public struct LYSVGAShapeRect: Codable, Equatable, Sendable {
    public let rect: LYSVGARect
    public let cornerRadius: Double

    public init(rect: LYSVGARect, cornerRadius: Double) {
        self.rect = rect
        self.cornerRadius = cornerRadius
    }
}

public struct LYSVGAShapeEllipse: Codable, Equatable, Sendable {
    public let centerX: Double
    public let centerY: Double
    public let radiusX: Double
    public let radiusY: Double

    public init(centerX: Double, centerY: Double, radiusX: Double, radiusY: Double) {
        self.centerX = centerX
        self.centerY = centerY
        self.radiusX = radiusX
        self.radiusY = radiusY
    }
}

public enum LYSVGAShapeType: Codable, Equatable, Sendable {
    case path(LYSVGAShapePath)
    case rect(LYSVGAShapeRect)
    case ellipse(LYSVGAShapeEllipse)
    case keep
}

public struct LYSVGAShape: Codable, Equatable, Sendable {
    public let type: LYSVGAShapeType
    public let style: LYSVGAShapeStyle
    public let transform: LYSVGATransform

    public init(
        type: LYSVGAShapeType,
        style: LYSVGAShapeStyle = LYSVGAShapeStyle(),
        transform: LYSVGATransform = .identity
    ) {
        self.type = type
        self.style = style
        self.transform = transform
    }
}
