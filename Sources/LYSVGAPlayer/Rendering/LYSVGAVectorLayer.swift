import QuartzCore

@MainActor
final class LYSVGAVectorLayer: CALayer {
    let shapeLayers: [CAShapeLayer]
    let resolvedFrameIndices: [Int?]
    private(set) var applicationCount = 0

    private let compiledFrames: [[LYSVGAShapeDescriptor]?]
    private var appliedFrameIndex: Int?

    init(frames: [LYSVGAFrame], canvasSize: CGSize) {
        var compiledFrames: [[LYSVGAShapeDescriptor]?] = []
        var resolvedFrameIndices: [Int?] = []
        var lastNonKeepFrame: Int?
        var maximumShapeCount = 0

        for (index, frame) in frames.enumerated() {
            if frame.shapes.first?.isKeep == true {
                resolvedFrameIndices.append(lastNonKeepFrame)
                if let lastNonKeepFrame {
                    compiledFrames.append(compiledFrames[lastNonKeepFrame])
                } else {
                    compiledFrames.append(nil)
                }
                continue
            }

            let descriptors = frame.shapes.compactMap(LYSVGAShapeDescriptor.init)
            compiledFrames.append(descriptors)
            resolvedFrameIndices.append(index)
            lastNonKeepFrame = index
            maximumShapeCount = max(maximumShapeCount, descriptors.count)
        }

        self.compiledFrames = compiledFrames
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
        guard compiledFrames.indices.contains(index),
              let resolvedFrameIndex = resolvedFrameIndices[index],
              let descriptors = compiledFrames[index] else {
            hideAllShapes()
            return
        }
        guard appliedFrameIndex != resolvedFrameIndex else { return }

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
}
