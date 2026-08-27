import CoreGraphics
import Foundation

enum LYSVGASVGPathParser {
    static func parse(_ source: String) throws -> CGPath {
        var parser = Parser(source: source)
        return try parser.parse()
    }
}

private struct Parser {
    private enum PreviousCurve {
        case none
        case cubic(CGPoint)
        case quadratic(CGPoint)
    }

    private var scanner: PathScanner
    private let path = CGMutablePath()
    private var command: UInt8?
    private var currentPoint = CGPoint.zero
    private var subpathStart = CGPoint.zero
    private var hasCurrentPoint = false
    private var previousCurve = PreviousCurve.none

    init(source: String) {
        scanner = PathScanner(source: source)
    }

    mutating func parse() throws -> CGPath {
        scanner.skipSeparators()
        guard scanner.isAtEnd == false else {
            throw LYSVGAError.invalidPath("The path is empty.")
        }

        while true {
            scanner.skipSeparators()
            guard scanner.isAtEnd == false else {
                break
            }

            if let next = scanner.peek, PathScanner.isLetter(next) {
                scanner.advance()
                guard Self.supportedCommands.contains(next) else {
                    throw LYSVGAError.invalidPath("Unsupported command \(Character(UnicodeScalar(next))).")
                }
                if hasCurrentPoint == false, next != Self.upperM, next != Self.lowerM {
                    throw LYSVGAError.invalidPath("A path must begin with a move command.")
                }
                command = next
                if next == Self.upperZ || next == Self.lowerZ {
                    guard hasCurrentPoint else {
                        throw LYSVGAError.invalidPath("Close has no active subpath.")
                    }
                    path.closeSubpath()
                    currentPoint = subpathStart
                    previousCurve = .none
                    command = nil
                    continue
                }
            }

            guard let command else {
                throw LYSVGAError.invalidPath("Expected a path command.")
            }
            try execute(command)
        }

        return path.copy() ?? path
    }

    private mutating func execute(_ command: UInt8) throws {
        let relative = PathScanner.isLowercase(command)
        switch PathScanner.uppercased(command) {
        case Self.upperM:
            let point = try readPoint(relative: relative)
            path.move(to: point)
            currentPoint = point
            subpathStart = point
            hasCurrentPoint = true
            previousCurve = .none
            self.command = relative ? Self.lowerL : Self.upperL
        case Self.upperL:
            try ensureCurrentPoint()
            let point = try readPoint(relative: relative)
            path.addLine(to: point)
            currentPoint = point
            previousCurve = .none
        case Self.upperH:
            try ensureCurrentPoint()
            let value = try scanner.readNumber(named: "horizontal coordinate")
            let point = CGPoint(x: relative ? currentPoint.x + value : value, y: currentPoint.y)
            path.addLine(to: point)
            currentPoint = point
            previousCurve = .none
        case Self.upperV:
            try ensureCurrentPoint()
            let value = try scanner.readNumber(named: "vertical coordinate")
            let point = CGPoint(x: currentPoint.x, y: relative ? currentPoint.y + value : value)
            path.addLine(to: point)
            currentPoint = point
            previousCurve = .none
        case Self.upperC:
            try ensureCurrentPoint()
            let control1 = try readPoint(relative: relative)
            let control2 = try readPoint(relative: relative)
            let point = try readPoint(relative: relative)
            path.addCurve(to: point, control1: control1, control2: control2)
            currentPoint = point
            previousCurve = .cubic(control2)
        case Self.upperS:
            try ensureCurrentPoint()
            let control1: CGPoint
            if case let .cubic(previousControl) = previousCurve {
                control1 = reflected(previousControl, around: currentPoint)
            } else {
                control1 = currentPoint
            }
            let control2 = try readPoint(relative: relative)
            let point = try readPoint(relative: relative)
            path.addCurve(to: point, control1: control1, control2: control2)
            currentPoint = point
            previousCurve = .cubic(control2)
        case Self.upperQ:
            try ensureCurrentPoint()
            let control = try readPoint(relative: relative)
            let point = try readPoint(relative: relative)
            path.addQuadCurve(to: point, control: control)
            currentPoint = point
            previousCurve = .quadratic(control)
        case Self.upperT:
            try ensureCurrentPoint()
            let control: CGPoint
            if case let .quadratic(previousControl) = previousCurve {
                control = reflected(previousControl, around: currentPoint)
            } else {
                control = currentPoint
            }
            let point = try readPoint(relative: relative)
            path.addQuadCurve(to: point, control: control)
            currentPoint = point
            previousCurve = .quadratic(control)
        case Self.upperA:
            try ensureCurrentPoint()
            let radiusX = try scanner.readNumber(named: "arc x radius")
            let radiusY = try scanner.readNumber(named: "arc y radius")
            let rotation = try scanner.readNumber(named: "arc rotation")
            let largeArc = try scanner.readFlag(named: "large-arc flag")
            let sweep = try scanner.readFlag(named: "sweep flag")
            let point = try readPoint(relative: relative)
            addArc(
                from: currentPoint,
                to: point,
                radiusX: radiusX,
                radiusY: radiusY,
                rotation: rotation,
                largeArc: largeArc,
                sweep: sweep
            )
            currentPoint = point
            previousCurve = .none
        default:
            throw LYSVGAError.invalidPath("Unsupported path command.")
        }
    }

    private mutating func readPoint(relative: Bool) throws -> CGPoint {
        let x = try scanner.readNumber(named: "x coordinate")
        let y = try scanner.readNumber(named: "y coordinate")
        if relative {
            return CGPoint(x: currentPoint.x + x, y: currentPoint.y + y)
        }
        return CGPoint(x: x, y: y)
    }

    private func ensureCurrentPoint() throws {
        guard hasCurrentPoint else {
            throw LYSVGAError.invalidPath("A drawing command requires a current point.")
        }
    }

    private func reflected(_ point: CGPoint, around center: CGPoint) -> CGPoint {
        CGPoint(x: center.x * 2 - point.x, y: center.y * 2 - point.y)
    }

    private func addArc(
        from start: CGPoint,
        to end: CGPoint,
        radiusX requestedRadiusX: CGFloat,
        radiusY requestedRadiusY: CGFloat,
        rotation: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        var radiusX = abs(requestedRadiusX)
        var radiusY = abs(requestedRadiusY)
        guard radiusX > 0, radiusY > 0 else {
            path.addLine(to: end)
            return
        }
        guard start != end else {
            return
        }

        let angle = rotation.truncatingRemainder(dividingBy: 360) * .pi / 180
        let cosine = cos(angle)
        let sine = sin(angle)
        let halfDeltaX = (start.x - end.x) / 2
        let halfDeltaY = (start.y - end.y) / 2
        let transformedX = cosine * halfDeltaX + sine * halfDeltaY
        let transformedY = -sine * halfDeltaX + cosine * halfDeltaY

        let radiiScale = transformedX * transformedX / (radiusX * radiusX)
            + transformedY * transformedY / (radiusY * radiusY)
        if radiiScale > 1 {
            let scale = sqrt(radiiScale)
            radiusX *= scale
            radiusY *= scale
        }

        let radiusXSquared = radiusX * radiusX
        let radiusYSquared = radiusY * radiusY
        let transformedXSquared = transformedX * transformedX
        let transformedYSquared = transformedY * transformedY
        let denominator = radiusXSquared * transformedYSquared + radiusYSquared * transformedXSquared
        let numerator = max(
            0,
            radiusXSquared * radiusYSquared
                - radiusXSquared * transformedYSquared
                - radiusYSquared * transformedXSquared
        )
        let sign: CGFloat = largeArc == sweep ? -1 : 1
        let coefficient = denominator > 0 ? sign * sqrt(numerator / denominator) : 0
        let centerTransformedX = coefficient * radiusX * transformedY / radiusY
        let centerTransformedY = coefficient * -radiusY * transformedX / radiusX
        let center = CGPoint(
            x: cosine * centerTransformedX - sine * centerTransformedY + (start.x + end.x) / 2,
            y: sine * centerTransformedX + cosine * centerTransformedY + (start.y + end.y) / 2
        )

        let startVector = CGPoint(
            x: (transformedX - centerTransformedX) / radiusX,
            y: (transformedY - centerTransformedY) / radiusY
        )
        let endVector = CGPoint(
            x: (-transformedX - centerTransformedX) / radiusX,
            y: (-transformedY - centerTransformedY) / radiusY
        )
        let startAngle = vectorAngle(from: CGPoint(x: 1, y: 0), to: startVector)
        var deltaAngle = vectorAngle(from: startVector, to: endVector)
        if sweep == false, deltaAngle > 0 {
            deltaAngle -= 2 * .pi
        } else if sweep, deltaAngle < 0 {
            deltaAngle += 2 * .pi
        }

        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle)
            .scaledBy(x: radiusX, y: radiusY)
        path.addArc(
            center: .zero,
            radius: 1,
            startAngle: startAngle,
            endAngle: startAngle + deltaAngle,
            clockwise: sweep == false,
            transform: transform
        )
    }

    private func vectorAngle(from first: CGPoint, to second: CGPoint) -> CGFloat {
        atan2(
            first.x * second.y - first.y * second.x,
            first.x * second.x + first.y * second.y
        )
    }

    private static let upperM = UInt8(ascii: "M")
    private static let lowerM = UInt8(ascii: "m")
    private static let upperL = UInt8(ascii: "L")
    private static let lowerL = UInt8(ascii: "l")
    private static let upperH = UInt8(ascii: "H")
    private static let upperV = UInt8(ascii: "V")
    private static let upperC = UInt8(ascii: "C")
    private static let upperS = UInt8(ascii: "S")
    private static let upperQ = UInt8(ascii: "Q")
    private static let upperT = UInt8(ascii: "T")
    private static let upperA = UInt8(ascii: "A")
    private static let upperZ = UInt8(ascii: "Z")
    private static let lowerZ = UInt8(ascii: "z")
    private static let supportedCommands: Set<UInt8> = Set("MmLlHhVvCcSsQqTtAaZz".utf8)
}

private struct PathScanner {
    private let bytes: [UInt8]
    private(set) var index = 0

    init(source: String) {
        bytes = Array(source.utf8)
    }

    var peek: UInt8? {
        isAtEnd ? nil : bytes[index]
    }

    var isAtEnd: Bool {
        index >= bytes.count
    }

    mutating func advance() {
        index += 1
    }

    mutating func skipSeparators() {
        while let byte = peek, Self.isWhitespace(byte) || byte == UInt8(ascii: ",") {
            advance()
        }
    }

    mutating func readNumber(named name: String) throws -> CGFloat {
        skipSeparators()
        let start = index
        if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") {
            advance()
        }

        var hasDigits = consumeDigits()
        if peek == UInt8(ascii: ".") {
            advance()
            hasDigits = consumeDigits() || hasDigits
        }
        guard hasDigits else {
            throw LYSVGAError.invalidPath("Expected \(name).")
        }

        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            advance()
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") {
                advance()
            }
            guard consumeDigits() else {
                throw LYSVGAError.invalidPath("The exponent for \(name) is incomplete.")
            }
        }

        let token = String(decoding: bytes[start ..< index], as: UTF8.self)
        guard let value = Double(token), value.isFinite else {
            throw LYSVGAError.invalidPath("The \(name) is invalid.")
        }
        return CGFloat(value)
    }

    mutating func readFlag(named name: String) throws -> Bool {
        skipSeparators()
        guard let byte = peek, byte == UInt8(ascii: "0") || byte == UInt8(ascii: "1") else {
            throw LYSVGAError.invalidPath("The \(name) must be 0 or 1.")
        }
        advance()
        return byte == UInt8(ascii: "1")
    }

    private mutating func consumeDigits() -> Bool {
        let start = index
        while let byte = peek, byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
            advance()
        }
        return index > start
    }

    static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
    }

    static func isLowercase(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")
    }

    static func uppercased(_ byte: UInt8) -> UInt8 {
        isLowercase(byte) ? byte - 32 : byte
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ")
            || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\n")
            || byte == UInt8(ascii: "\r")
            || byte == 0x0C
    }
}
