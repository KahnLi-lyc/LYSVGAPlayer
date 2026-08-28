import QuartzCore

@MainActor
final class LYSVGASpriteLayer: CALayer {
    let contentLayer = CALayer()
    let vectorLayer: LYSVGAVectorLayer
    let clipMaskLayer: CAShapeLayer?

    private let sprite: LYSVGASprite
    private let originalImage: CGImage?
    private let canvasBounds: CGRect
    private let clipPaths: [CGPath?]
    private var dynamicContent: LYSVGADynamicContentEntry?
    private(set) var dynamicTextLayerForTesting: CATextLayer?
    private var dynamicContentsScale: CGFloat = 1

    var imageKeyForDynamicContent: String { sprite.imageKey }
    var bitmapImageForTesting: CGImage? { dynamicContent?.image?.cgImage ?? originalImage }

    init(sprite: LYSVGASprite, image: CGImage?, canvasSize: CGSize) {
        self.sprite = sprite
        originalImage = image
        canvasBounds = CGRect(origin: .zero, size: canvasSize)
        clipPaths = sprite.frames.map { frame in
            guard let clipPath = frame.clipPath else { return nil }
            return try? LYSVGASVGPathParser.parse(clipPath)
        }

        vectorLayer = LYSVGAVectorLayer(frames: sprite.frames, canvasSize: canvasSize)
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

        contentLayer.addSublayer(vectorLayer)

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

        vectorLayer.position = .zero
        vectorLayer.display(frame: index, contentSize: layout.size)
        contentLayer.contents = dynamicContent?.image?.cgImage ?? originalImage
        layoutDynamicText(in: contentLayer.bounds)

        if let clipMaskLayer, clipPaths.indices.contains(index), let clipPath = clipPaths[index] {
            clipMaskLayer.bounds = CGRect(origin: .zero, size: layout.size)
            clipMaskLayer.position = .zero
            clipMaskLayer.path = clipPath
            contentLayer.mask = clipMaskLayer
        } else {
            contentLayer.mask = nil
        }
        if dynamicContent?.isHidden == true {
            isHidden = true
            return
        }
        dynamicContent?.drawingHandler?(contentLayer, index)
        if dynamicContent?.isHidden == true {
            isHidden = true
        }
    }

    func hide() {
        isHidden = true
        contentLayer.mask = nil
        vectorLayer.hideAllShapes()
    }

    func applyDynamicContent(_ content: LYSVGADynamicContentEntry?, contentsScale: CGFloat) {
        dynamicContent = content
        dynamicContentsScale = contentsScale
        contentLayer.contents = content?.image?.cgImage ?? originalImage

        if let attributedText = content?.attributedText {
            let textLayer = dynamicTextLayerForTesting ?? makeDynamicTextLayer()
            textLayer.string = attributedText
            textLayer.contentsScale = contentsScale
            dynamicTextLayerForTesting = textLayer
        } else {
            dynamicTextLayerForTesting?.removeFromSuperlayer()
            dynamicTextLayerForTesting = nil
        }
        layoutDynamicText(in: contentLayer.bounds)
    }

    private func makeDynamicTextLayer() -> CATextLayer {
        let textLayer = CATextLayer()
        textLayer.anchorPoint = .zero
        textLayer.alignmentMode = .center
        textLayer.isWrapped = true
        textLayer.truncationMode = .end
        contentLayer.addSublayer(textLayer)
        return textLayer
    }

    private func layoutDynamicText(in bounds: CGRect) {
        guard let textLayer = dynamicTextLayerForTesting,
              let text = textLayer.string as? NSAttributedString else { return }
        let maximumSize = CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        let measuredHeight = ceil(text.boundingRect(
            with: maximumSize,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)
        let height = min(bounds.height, max(0, measuredHeight))
        textLayer.contentsScale = dynamicContentsScale
        textLayer.frame = CGRect(
            x: bounds.minX,
            y: bounds.midY - height / 2,
            width: bounds.width,
            height: height
        )
    }
}
