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
        scanner.skipWhitespace()
        guard scanner.isAtEnd == false else {
            throw LYSVGAError.invalidPath("The path is empty.")
        }

        while true {
            scanner.skipWhitespace()
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
                scanner.beginCommand()
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
            let x = relative ? try checkedAdd(currentPoint.x, value) : value
            let point = CGPoint(x: x, y: currentPoint.y)
            path.addLine(to: point)
            currentPoint = point
            previousCurve = .none
        case Self.upperV:
            try ensureCurrentPoint()
            let value = try scanner.readNumber(named: "vertical coordinate")
            let y = relative ? try checkedAdd(currentPoint.y, value) : value
            let point = CGPoint(x: currentPoint.x, y: y)
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
                control1 = try reflected(previousControl, around: currentPoint)
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
                control = try reflected(previousControl, around: currentPoint)
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
            try addArc(
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
            return CGPoint(
                x: try checkedAdd(currentPoint.x, x),
                y: try checkedAdd(currentPoint.y, y)
            )
        }
        return CGPoint(x: x, y: y)
    }

    private func ensureCurrentPoint() throws {
        guard hasCurrentPoint else {
            throw LYSVGAError.invalidPath("A drawing command requires a current point.")
        }
    }

    private func reflected(_ point: CGPoint, around center: CGPoint) throws -> CGPoint {
        CGPoint(
            x: try checkedSubtract(try checkedMultiply(center.x, 2), point.x),
            y: try checkedSubtract(try checkedMultiply(center.y, 2), point.y)
        )
    }

    private func addArc(
        from start: CGPoint,
        to end: CGPoint,
        radiusX requestedRadiusX: CGFloat,
        radiusY requestedRadiusY: CGFloat,
        rotation: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) throws {
        var radiusX = abs(requestedRadiusX)
        var radiusY = abs(requestedRadiusY)
        guard radiusX > 0, radiusY > 0 else {
            path.addLine(to: end)
            return
        }
        guard start != end else {
            return
        }

        let angle = try checkedMultiply(
            try checkedDivide(rotation.truncatingRemainder(dividingBy: 360), 180),
            .pi
        )
        let cosine = cos(angle)
        let sine = sin(angle)
        let halfDeltaX = try checkedDivide(try checkedSubtract(start.x, end.x), 2)
        let halfDeltaY = try checkedDivide(try checkedSubtract(start.y, end.y), 2)
        let transformedX = try checkedAdd(
            try checkedMultiply(cosine, halfDeltaX),
            try checkedMultiply(sine, halfDeltaY)
        )
        let transformedY = try checkedAdd(
            try checkedMultiply(-sine, halfDeltaX),
            try checkedMultiply(cosine, halfDeltaY)
        )

        let transformedXSquared = try checkedMultiply(transformedX, transformedX)
        let transformedYSquared = try checkedMultiply(transformedY, transformedY)
        var radiusXSquared = try checkedMultiply(radiusX, radiusX)
        var radiusYSquared = try checkedMultiply(radiusY, radiusY)
        let radiiScale = try checkedAdd(
            try checkedDivide(transformedXSquared, radiusXSquared),
            try checkedDivide(transformedYSquared, radiusYSquared)
        )
        if radiiScale > 1 {
            let scale = sqrt(radiiScale)
            radiusX = try checkedMultiply(radiusX, scale)
            radiusY = try checkedMultiply(radiusY, scale)
            radiusXSquared = try checkedMultiply(radiusX, radiusX)
            radiusYSquared = try checkedMultiply(radiusY, radiusY)
        }

        let denominator = try checkedAdd(
            try checkedMultiply(radiusXSquared, transformedYSquared),
            try checkedMultiply(radiusYSquared, transformedXSquared)
        )
        let numerator = max(
            0,
            try checkedSubtract(
                try checkedSubtract(
                    try checkedMultiply(radiusXSquared, radiusYSquared),
                    try checkedMultiply(radiusXSquared, transformedYSquared)
                ),
                try checkedMultiply(radiusYSquared, transformedXSquared)
            )
        )
        let sign: CGFloat = largeArc == sweep ? -1 : 1
        let coefficient = denominator > 0
            ? try checkedMultiply(sign, sqrt(try checkedDivide(numerator, denominator)))
            : 0
        let centerTransformedX = try checkedDivide(
            try checkedMultiply(try checkedMultiply(coefficient, radiusX), transformedY),
            radiusY
        )
        let centerTransformedY = try checkedDivide(
            try checkedMultiply(try checkedMultiply(coefficient, -radiusY), transformedX),
            radiusX
        )
        let midpointX = try checkedDivide(try checkedAdd(start.x, end.x), 2)
        let midpointY = try checkedDivide(try checkedAdd(start.y, end.y), 2)
        let center = CGPoint(
            x: try checkedAdd(
                try checkedSubtract(
                    try checkedMultiply(cosine, centerTransformedX),
                    try checkedMultiply(sine, centerTransformedY)
                ),
                midpointX
            ),
            y: try checkedAdd(
                try checkedAdd(
                    try checkedMultiply(sine, centerTransformedX),
                    try checkedMultiply(cosine, centerTransformedY)
                ),
                midpointY
            )
        )

        let startVector = CGPoint(
            x: try checkedDivide(try checkedSubtract(transformedX, centerTransformedX), radiusX),
            y: try checkedDivide(try checkedSubtract(transformedY, centerTransformedY), radiusY)
        )
        let endVector = CGPoint(
            x: try checkedDivide(try checkedSubtract(-transformedX, centerTransformedX), radiusX),
            y: try checkedDivide(try checkedSubtract(-transformedY, centerTransformedY), radiusY)
        )
        let startAngle = try vectorAngle(from: CGPoint(x: 1, y: 0), to: startVector)
        var deltaAngle = try vectorAngle(from: startVector, to: endVector)
        if sweep == false, deltaAngle > 0 {
            deltaAngle = try checkedSubtract(deltaAngle, 2 * .pi)
        } else if sweep, deltaAngle < 0 {
            deltaAngle = try checkedAdd(deltaAngle, 2 * .pi)
        }

        let transform = CGAffineTransform(
            a: try checkedMultiply(cosine, radiusX),
            b: try checkedMultiply(sine, radiusX),
            c: try checkedMultiply(-sine, radiusY),
            d: try checkedMultiply(cosine, radiusY),
            tx: center.x,
            ty: center.y
        )
        try appendArc(
            center: .zero,
            radius: 1,
            startAngle: startAngle,
            endAngle: try checkedAdd(startAngle, deltaAngle),
            clockwise: sweep == false,
            transform: transform,
            exactEnd: end
        )
    }

    private func vectorAngle(from first: CGPoint, to second: CGPoint) throws -> CGFloat {
        let crossProduct = try checkedSubtract(
            try checkedMultiply(first.x, second.y),
            try checkedMultiply(first.y, second.x)
        )
        let dotProduct = try checkedAdd(
            try checkedMultiply(first.x, second.x),
            try checkedMultiply(first.y, second.y)
        )
        return try checkedFinite(atan2(crossProduct, dotProduct))
    }

    private func appendArc(
        center: CGPoint,
        radius: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat,
        clockwise: Bool,
        transform: CGAffineTransform,
        exactEnd: CGPoint
    ) throws {
        struct Element {
            let type: CGPathElementType
            var points: [CGPoint]
        }

        let unitArc = CGMutablePath()
        unitArc.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: clockwise
        )
        var elements: [Element] = []
        unitArc.applyWithBlock { pointer in
            let element = pointer.pointee
            let pointCount: Int
            switch element.type {
            case .moveToPoint, .addLineToPoint:
                pointCount = 1
            case .addQuadCurveToPoint:
                pointCount = 2
            case .addCurveToPoint:
                pointCount = 3
            case .closeSubpath:
                pointCount = 0
            @unknown default:
                pointCount = 0
            }
            elements.append(Element(
                type: element.type,
                points: (0 ..< pointCount).map { element.points[$0] }
            ))
        }

        let lastDrawingIndex = elements.lastIndex { $0.points.isEmpty == false && $0.type != .moveToPoint }
        var transformedElements: [Element] = []
        transformedElements.reserveCapacity(elements.count)
        for index in elements.indices {
            var element = elements[index]
            element.points = try element.points.map { try transformed($0, by: transform) }
            if index == lastDrawingIndex, element.points.isEmpty == false {
                element.points[element.points.count - 1] = exactEnd
            }
            transformedElements.append(element)
        }

        for element in transformedElements {
            switch element.type {
            case .moveToPoint:
                continue
            case .addLineToPoint:
                path.addLine(to: element.points[0])
            case .addQuadCurveToPoint:
                path.addQuadCurve(to: element.points[1], control: element.points[0])
            case .addCurveToPoint:
                path.addCurve(
                    to: element.points[2],
                    control1: element.points[0],
                    control2: element.points[1]
                )
            case .closeSubpath:
                path.closeSubpath()
            @unknown default:
                throw LYSVGAError.invalidPath("The arc contains an unsupported path element.")
            }
        }
    }

    private func transformed(_ point: CGPoint, by transform: CGAffineTransform) throws -> CGPoint {
        CGPoint(
            x: try checkedAdd(
                try checkedAdd(
                    try checkedMultiply(transform.a, point.x),
                    try checkedMultiply(transform.c, point.y)
                ),
                transform.tx
            ),
            y: try checkedAdd(
                try checkedAdd(
                    try checkedMultiply(transform.b, point.x),
                    try checkedMultiply(transform.d, point.y)
                ),
                transform.ty
            )
        )
    }

    private func checkedAdd(_ lhs: CGFloat, _ rhs: CGFloat) throws -> CGFloat {
        try checkedFinite(lhs + rhs)
    }

    private func checkedSubtract(_ lhs: CGFloat, _ rhs: CGFloat) throws -> CGFloat {
        try checkedFinite(lhs - rhs)
    }

    private func checkedMultiply(_ lhs: CGFloat, _ rhs: CGFloat) throws -> CGFloat {
        try checkedFinite(lhs * rhs)
    }

    private func checkedDivide(_ lhs: CGFloat, _ rhs: CGFloat) throws -> CGFloat {
        try checkedFinite(lhs / rhs)
    }

    private func checkedFinite(_ value: CGFloat) throws -> CGFloat {
        guard value.isFinite else {
            throw LYSVGAError.invalidPath("Path geometry must be finite.")
        }
        return value
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
    private var hasReadArgument = false

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

    mutating func beginCommand() {
        hasReadArgument = false
    }

    mutating func skipWhitespace() {
        while let byte = peek, Self.isWhitespace(byte) {
            advance()
        }
    }

    mutating func readNumber(named name: String) throws -> CGFloat {
        try prepareForArgument(named: name)
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
        let result = CGFloat(value)
        guard result.isFinite else {
            throw LYSVGAError.invalidPath("The \(name) is invalid.")
        }
        hasReadArgument = true
        return result
    }

    mutating func readFlag(named name: String) throws -> Bool {
        try prepareForArgument(named: name)
        guard let byte = peek, byte == UInt8(ascii: "0") || byte == UInt8(ascii: "1") else {
            throw LYSVGAError.invalidPath("The \(name) must be 0 or 1.")
        }
        advance()
        hasReadArgument = true
        return byte == UInt8(ascii: "1")
    }

    private mutating func prepareForArgument(named name: String) throws {
        skipWhitespace()
        guard peek == UInt8(ascii: ",") else {
            return
        }
        guard hasReadArgument else {
            throw LYSVGAError.invalidPath("Unexpected comma before \(name).")
        }
        advance()
        skipWhitespace()
        guard peek != UInt8(ascii: ",") else {
            throw LYSVGAError.invalidPath("Unexpected repeated comma before \(name).")
        }
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
