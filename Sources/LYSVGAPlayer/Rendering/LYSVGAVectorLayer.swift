import QuartzCore

@MainActor
final class LYSVGAVectorLayer: CALayer {
    let shapeLayers: [CAShapeLayer]
    let resolvedFrameIndices: [Int?]
    private(set) var applicationCount = 0
    var compiledDescriptorFrameCount: Int { plan.descriptors.count }

    private let plan: LYSVGAVectorPlan
    private var appliedFrameIndex: Int?

    /// Builds the reusable shape-layer pool from a precompiled plan; `nil` when there is nothing to draw.
    init?(plan: LYSVGAVectorPlan?, canvasSize: CGSize) {
        guard let plan, plan.maximumShapeCount > 0 else { return nil }

        self.plan = plan
        resolvedFrameIndices = plan.resolvedFrameIndices
        shapeLayers = (0..<plan.maximumShapeCount).map { _ in CAShapeLayer() }
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
        let contentBounds = CGRect(origin: .zero, size: contentSize)
        if bounds != contentBounds {
            bounds = contentBounds
            for layer in shapeLayers {
                layer.bounds = contentBounds
            }
        }
        guard resolvedFrameIndices.indices.contains(index),
              let resolvedFrameIndex = resolvedFrameIndices[index] else {
            hideAllShapes()
            return
        }
        guard appliedFrameIndex != resolvedFrameIndex else { return }
        let descriptors = plan.descriptors[resolvedFrameIndex] ?? []

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
