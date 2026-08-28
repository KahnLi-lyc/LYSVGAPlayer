import QuartzCore

@MainActor
final class LYSVGAVectorLayer: CALayer {
    let shapeLayers: [CAShapeLayer]
    let resolvedFrameIndices: [Int?]
    private(set) var applicationCount = 0
    var compiledDescriptorFrameCount: Int { compiledFrames.count }

    private let frames: [LYSVGAFrame]
    private var compiledFrames: [Int: [LYSVGAShapeDescriptor]] = [:]
    private var appliedFrameIndex: Int?

    init?(frames: [LYSVGAFrame], canvasSize: CGSize) {
        var resolvedFrameIndices: [Int?] = []
        var lastNonKeepFrame: Int?
        var maximumShapeCount = 0

        for (index, frame) in frames.enumerated() {
            if frame.shapes.first?.isKeep == true {
                resolvedFrameIndices.append(lastNonKeepFrame)
                continue
            }

            resolvedFrameIndices.append(index)
            lastNonKeepFrame = index
            maximumShapeCount = max(
                maximumShapeCount,
                frame.shapes.lazy.filter(\.canProduceDescriptorWithoutPathParsing).count
            )
        }

        guard maximumShapeCount > 0 else { return nil }

        self.frames = frames
        self.resolvedFrameIndices = resolvedFrameIndices
        shapeLayers = (0..<maximumShapeCount).map { _ in CAShapeLayer() }
        super.init()

        anchorPoint = .zero
        position = .zero
        bounds = CGRect(origin: .zero, size: canvasSize)
        for layer in shapeLayers {
            layer.anchorPoint = .zero
            layer.position = .zero
            layer.bounds = bounds
            layer.isHidden = true
            addSublayer(layer)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func display(frame index: Int, contentSize: CGSize) {
        bounds = CGRect(origin: .zero, size: contentSize)
        for layer in shapeLayers {
            layer.bounds = bounds
        }
        guard resolvedFrameIndices.indices.contains(index),
              let resolvedFrameIndex = resolvedFrameIndices[index] else {
            hideAllShapes()
            return
        }
        guard appliedFrameIndex != resolvedFrameIndex else { return }
        let descriptors: [LYSVGAShapeDescriptor]
        if let cached = compiledFrames[resolvedFrameIndex] {
            descriptors = cached
        } else {
            descriptors = frames[resolvedFrameIndex].shapes.compactMap(LYSVGAShapeDescriptor.init)
            compiledFrames[resolvedFrameIndex] = descriptors
        }

        for (shapeIndex, layer) in shapeLayers.enumerated() {
            guard descriptors.indices.contains(shapeIndex) else {
                layer.isHidden = true
                continue
            }
            apply(descriptors[shapeIndex], to: layer)
        }
        appliedFrameIndex = resolvedFrameIndex
        applicationCount += 1
    }

    func hideAllShapes() {
        appliedFrameIndex = nil
        for layer in shapeLayers {
            layer.isHidden = true
        }
    }

    private func apply(_ descriptor: LYSVGAShapeDescriptor, to layer: CAShapeLayer) {
        layer.path = descriptor.path
        layer.fillColor = descriptor.fillColor
        layer.strokeColor = descriptor.strokeColor
        layer.lineWidth = descriptor.lineWidth
        layer.lineCap = descriptor.lineCap
        layer.lineJoin = descriptor.lineJoin
        layer.miterLimit = descriptor.miterLimit
        layer.lineDashPattern = descriptor.lineDashPattern
        layer.lineDashPhase = descriptor.lineDashPhase
        layer.setAffineTransform(descriptor.transform)
        layer.isHidden = false
    }
}

private extension LYSVGAShape {
    var isKeep: Bool {
        if case .keep = type { return true }
        return false
    }

    var canProduceDescriptorWithoutPathParsing: Bool {
        switch type {
        case let .path(value):
            return value.path.isEmpty == false
        case let .rect(value):
            return value.rect.finiteCGRect != nil && value.cornerRadius.isFinite
        case let .ellipse(value):
            guard value.centerX.isFinite, value.centerY.isFinite,
                  value.radiusX.isFinite, value.radiusY.isFinite,
                  value.radiusX >= 0, value.radiusY >= 0 else {
                return false
            }
            return (value.centerX - value.radiusX).isFinite
                && (value.centerY - value.radiusY).isFinite
                && (value.centerX + value.radiusX).isFinite
                && (value.centerY + value.radiusY).isFinite
                && (value.radiusX * 2).isFinite
                && (value.radiusY * 2).isFinite
        case .keep:
            return false
        }
    }
}
