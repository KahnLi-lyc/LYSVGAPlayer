import QuartzCore

@MainActor
final class LYSVGASpriteLayer: CALayer {
    let contentLayer = CALayer()
    let vectorLayer: LYSVGAVectorLayer?
    let clipMaskLayer: CAShapeLayer?

    private let sprite: LYSVGASprite
    private let canvasBounds: CGRect
    private let clipPaths: [CGPath?]

    init(sprite: LYSVGASprite, image: CGImage?, canvasSize: CGSize) {
        self.sprite = sprite
        canvasBounds = CGRect(origin: .zero, size: canvasSize)
        clipPaths = sprite.frames.map { frame in
            guard let clipPath = frame.clipPath else { return nil }
            return try? LYSVGASVGPathParser.parse(clipPath)
        }

        if image == nil {
            vectorLayer = LYSVGAVectorLayer(frames: sprite.frames, canvasSize: canvasSize)
        } else {
            vectorLayer = nil
        }
        clipMaskLayer = sprite.frames.contains(where: { $0.clipPath != nil }) ? CAShapeLayer() : nil
        super.init()

        anchorPoint = .zero
        position = .zero
        bounds = canvasBounds
        isHidden = true

        contentLayer.anchorPoint = .zero
        contentLayer.position = .zero
        contentLayer.bounds = .zero
        if let image {
            contentLayer.contents = image
            contentLayer.contentsGravity = .resizeAspect
        }
        addSublayer(contentLayer)

        if let vectorLayer {
            contentLayer.addSublayer(vectorLayer)
        }

        if let clipMaskLayer {
            clipMaskLayer.anchorPoint = .zero
            clipMaskLayer.position = .zero
            clipMaskLayer.bounds = canvasBounds
            clipMaskLayer.fillColor = CGColor(gray: 1, alpha: 1)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func display(frame index: Int) {
        guard sprite.frames.indices.contains(index) else {
            hide()
            return
        }
        let frame = sprite.frames[index]
        guard frame.alpha.isFinite, frame.alpha > 0,
              let layout = frame.layout.finiteCGRect,
              layout.width > 0, layout.height > 0,
              let transform = frame.transform.finiteAffineTransform else {
            hide()
            return
        }

        isHidden = false
        opacity = Float(min(frame.alpha, 1))
        contentLayer.bounds = CGRect(origin: .zero, size: layout.size)
        contentLayer.position = layout.origin
        contentLayer.setAffineTransform(transform)

        if let vectorLayer {
            vectorLayer.position = .zero
            vectorLayer.display(frame: index, contentSize: layout.size)
        }

        if let clipMaskLayer, clipPaths.indices.contains(index), let clipPath = clipPaths[index] {
            clipMaskLayer.path = clipPath
            mask = clipMaskLayer
        } else {
            mask = nil
        }
    }

    func hide() {
        isHidden = true
        mask = nil
        vectorLayer?.hideAllShapes()
    }
}
