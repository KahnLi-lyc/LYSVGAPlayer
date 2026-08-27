import QuartzCore
import UIKit

struct LYSVGAShapeDescriptor {
    let path: CGPath
    let fillColor: CGColor?
    let strokeColor: CGColor?
    let lineWidth: CGFloat
    let lineCap: CAShapeLayerLineCap
    let lineJoin: CAShapeLayerLineJoin
    let miterLimit: CGFloat
    let lineDashPattern: [NSNumber]?
    let lineDashPhase: CGFloat
    let transform: CGAffineTransform

    @MainActor
    init?(shape: LYSVGAShape) {
        guard let path = Self.makePath(shape.type) else {
            return nil
        }

        self.path = path
        fillColor = Self.makeColor(shape.style.fill)
        strokeColor = Self.makeColor(shape.style.stroke)
        lineWidth = Self.nonnegative(shape.style.strokeWidth)
        lineCap = Self.makeLineCap(shape.style.lineCap)
        lineJoin = Self.makeLineJoin(shape.style.lineJoin)
        miterLimit = Self.nonnegative(shape.style.miterLimit)
        let dash = Self.makeDash(shape.style.lineDash)
        lineDashPattern = dash.pattern
        lineDashPhase = dash.phase
        transform = shape.transform.finiteAffineTransform ?? .identity
    }

    @MainActor
    private static func makePath(_ type: LYSVGAShapeType) -> CGPath? {
        switch type {
        case let .path(value):
            return try? LYSVGASVGPathParser.parse(value.path)
        case let .rect(value):
            guard let rect = value.rect.finiteCGRect,
                  value.cornerRadius.isFinite else {
                return nil
            }
            let radius = max(0, CGFloat(value.cornerRadius))
            return CGPath(
                roundedRect: rect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
        case let .ellipse(value):
            guard value.centerX.isFinite, value.centerY.isFinite,
                  value.radiusX.isFinite, value.radiusY.isFinite,
                  value.radiusX >= 0, value.radiusY >= 0 else {
                return nil
            }
            let rect = CGRect(
                x: value.centerX - value.radiusX,
                y: value.centerY - value.radiusY,
                width: value.radiusX * 2,
                height: value.radiusY * 2
            )
            return CGPath(ellipseIn: rect, transform: nil)
        case .keep:
            return nil
        }
    }

    @MainActor
    private static func makeColor(_ color: LYSVGAColor?) -> CGColor? {
        guard let color,
              color.red.isFinite, color.green.isFinite,
              color.blue.isFinite, color.alpha.isFinite else {
            return nil
        }
        return UIColor(
            red: color.red.clampedToUnit,
            green: color.green.clampedToUnit,
            blue: color.blue.clampedToUnit,
            alpha: color.alpha.clampedToUnit
        ).cgColor
    }

    private static func nonnegative(_ value: Double) -> CGFloat {
        guard value.isFinite else { return 0 }
        return max(0, CGFloat(value))
    }

    private static func makeDash(_ values: [Double]) -> (pattern: [NSNumber]?, phase: CGFloat) {
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return (nil, 0)
        }
        if values.count >= 3 {
            let pattern = values.dropLast().map { NSNumber(value: $0) }
            return (pattern.isEmpty ? nil : pattern, CGFloat(values.last ?? 0))
        }
        let pattern = values.map { NSNumber(value: $0) }
        return (pattern.isEmpty ? nil : pattern, 0)
    }

    private static func makeLineCap(_ value: LYSVGALineCap) -> CAShapeLayerLineCap {
        switch value {
        case .butt: .butt
        case .round: .round
        case .square: .square
        }
    }

    private static func makeLineJoin(_ value: LYSVGALineJoin) -> CAShapeLayerLineJoin {
        switch value {
        case .miter: .miter
        case .round: .round
        case .bevel: .bevel
        }
    }
}

extension LYSVGARect {
    var finiteCGRect: CGRect? {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width >= 0, height >= 0 else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

extension LYSVGATransform {
    var finiteAffineTransform: CGAffineTransform? {
        guard a.isFinite, b.isFinite, c.isFinite, d.isFinite,
              tx.isFinite, ty.isFinite else {
            return nil
        }
        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}

private extension Double {
    var clampedToUnit: CGFloat {
        CGFloat(min(max(self, 0), 1))
    }
}
