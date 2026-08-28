import QuartzCore
import UIKit

@MainActor
final class LYSVGARenderer {
    let rootLayer = CALayer()
    let canvasLayer = CALayer()

    private(set) var video: LYSVGAVideo?
    private(set) var currentFrame: Int?
    private(set) var spriteLayers: [LYSVGASpriteLayer] = []
    private(set) var matteHosts: [LYSVGAMatteHost] = []

    private var missingMatteSpriteIndices: Set<Int> = []
    private var additionalMatteLayers: [LYSVGASpriteLayer] = []
    private var isDisplayingFrame = false
    private var imagePreheatTask: Task<Void, Never>?
    private var imagePreheatRevision: UInt = 0

    init() {
        rootLayer.anchorPoint = .zero
        canvasLayer.anchorPoint = .zero
        canvasLayer.masksToBounds = true
        rootLayer.addSublayer(canvasLayer)
    }

    deinit {
        imagePreheatTask?.cancel()
    }

    func prepare(video: LYSVGAVideo) async throws {
        cancelImagePreheat()
        let images = try await LYSVGAImagePreparer.prepare(video)
        buildLayerTree(video: video, images: images)
        startImagePreheat(for: video)
    }

    func cancelImagePreheat() {
        imagePreheatRevision &+= 1
        imagePreheatTask?.cancel()
        imagePreheatTask = nil
    }

    func waitForImagePreheat() async {
        await imagePreheatTask?.value
    }

    func layout(in bounds: CGRect, contentMode: UIView.ContentMode, clipsToBounds: Bool) {
        withoutAnimations {
            rootLayer.masksToBounds = clipsToBounds
            guard bounds.isFiniteRendererBounds else {
                rootLayer.frame = .zero
                canvasLayer.position = .zero
                canvasLayer.setAffineTransform(.identity)
                return
            }

            rootLayer.frame = bounds
            rootLayer.bounds = CGRect(origin: .zero, size: bounds.size)
            guard let video else {
                canvasLayer.bounds = .zero
                canvasLayer.position = .zero
                canvasLayer.setAffineTransform(.identity)
                return
            }

            let videoSize = CGSize(width: video.canvasSize.width, height: video.canvasSize.height)
            let localBounds = CGRect(origin: .zero, size: bounds.size)
            let canvasFrame = LYSVGACanvasLayout.frame(
                videoSize: videoSize,
                in: localBounds,
                contentMode: contentMode
            )
            guard canvasFrame.isFiniteRendererBounds,
                  canvasFrame.width > 0, canvasFrame.height > 0 else {
                canvasLayer.position = .zero
                canvasLayer.setAffineTransform(.identity)
                return
            }

            canvasLayer.bounds = CGRect(origin: .zero, size: videoSize)
            canvasLayer.anchorPoint = .zero
            canvasLayer.position = canvasFrame.origin
            canvasLayer.setAffineTransform(CGAffineTransform(
                scaleX: canvasFrame.width / videoSize.width,
                y: canvasFrame.height / videoSize.height
            ))
        }
    }

    func display(frame index: Int) {
        guard isDisplayingFrame == false else { return }
        isDisplayingFrame = true
        defer { isDisplayingFrame = false }
        withoutAnimations {
            guard let video, (0..<video.frameCount).contains(index) else {
                currentFrame = nil
                spriteLayers.forEach { $0.hide() }
                additionalMatteLayers.forEach { $0.hide() }
                matteHosts.forEach { $0.layer.isHidden = true }
                return
            }

            currentFrame = index
            for spriteLayer in spriteLayers {
                spriteLayer.display(frame: index)
            }
            for matteLayer in additionalMatteLayers {
                matteLayer.display(frame: index)
            }
            for index in missingMatteSpriteIndices {
                spriteLayers[index].hide()
            }
            for host in matteHosts {
                host.layer.isHidden = host.matteLayer.isHidden || host.contentLayers.allSatisfy(\.isHidden)
            }
        }
    }

    func applyDynamicContents(_ contents: LYSVGADynamicContentStore, contentsScale: CGFloat) {
        for spriteLayer in spriteLayers {
            spriteLayer.applyDynamicContent(
                contents.entry(forSpriteKey: spriteLayer.imageKeyForDynamicContent),
                contentsScale: contentsScale
            )
        }
        for matteLayer in additionalMatteLayers {
            matteLayer.applyDynamicContent(
                contents.entry(forSpriteKey: matteLayer.imageKeyForDynamicContent),
                contentsScale: contentsScale
            )
        }
        if isDisplayingFrame == false, let currentFrame {
            display(frame: currentFrame)
        }
    }

    private func buildLayerTree(video: LYSVGAVideo, images: [String: LYSVGAPreparedImage]) {
        withoutAnimations {
            canvasLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            canvasLayer.mask = nil
            canvasLayer.masksToBounds = true
            currentFrame = nil
            self.video = video
            matteHosts = []
            missingMatteSpriteIndices = []
            additionalMatteLayers = []

            let canvasSize = CGSize(width: video.canvasSize.width, height: video.canvasSize.height)
            canvasLayer.bounds = CGRect(origin: .zero, size: canvasSize)
            spriteLayers = video.sprites.map { sprite in
                let key = LYSVGAResourceKey.canonicalize(sprite.imageKey)
                return LYSVGASpriteLayer(
                    sprite: sprite,
                    image: images[key]?.cgImage,
                    canvasSize: canvasSize
                )
            }

            let matteResolution = resolveMattes(in: video.sprites)
            missingMatteSpriteIndices = matteResolution.missing
            let matteIndices = Set(matteResolution.contentToMatte.values)
            var matteHostCounts: [Int: Int] = [:]
            var activeHost: LYSVGAMatteHost?
            var activeMatteIndex: Int?

            for (index, spriteLayer) in spriteLayers.enumerated() {
                if matteIndices.contains(index) {
                    activeHost = nil
                    activeMatteIndex = nil
                    continue
                }
                if missingMatteSpriteIndices.contains(index) {
                    activeHost = nil
                    activeMatteIndex = nil
                    spriteLayer.hide()
                    continue
                }
                guard let matteIndex = matteResolution.contentToMatte[index] else {
                    activeHost = nil
                    activeMatteIndex = nil
                    canvasLayer.addSublayer(spriteLayer)
                    continue
                }

                let host: LYSVGAMatteHost
                if activeMatteIndex == matteIndex, let activeHost {
                    host = activeHost
                } else {
                    let useCount = matteHostCounts[matteIndex, default: 0]
                    let matteLayer: LYSVGASpriteLayer
                    if useCount == 0 {
                        matteLayer = spriteLayers[matteIndex]
                    } else {
                        let matteSprite = video.sprites[matteIndex]
                        let image = images[LYSVGAResourceKey.canonicalize(matteSprite.imageKey)]?.cgImage
                        matteLayer = LYSVGASpriteLayer(
                            sprite: matteSprite,
                            image: image,
                            canvasSize: canvasSize
                        )
                        additionalMatteLayers.append(matteLayer)
                    }
                    host = LYSVGAMatteHost(matteLayer: matteLayer, canvasSize: canvasSize)
                    matteHostCounts[matteIndex] = useCount + 1
                    matteHosts.append(host)
                    canvasLayer.addSublayer(host.layer)
                    activeHost = host
                    activeMatteIndex = matteIndex
                }
                host.addContentLayer(spriteLayer)
            }

            layout(
                in: CGRect(origin: .zero, size: canvasSize),
                contentMode: .center,
                clipsToBounds: false
            )
        }
    }

    private func startImagePreheat(for video: LYSVGAVideo) {
        imagePreheatRevision &+= 1
        let revision = imagePreheatRevision
        imagePreheatTask = Task(priority: .utility) { [weak self] in
            do {
                let images = try await LYSVGAImagePreparer.prepareEagerly(video)
                try Task.checkCancellation()
                guard let self, imagePreheatRevision == revision else { return }
                installPreheatedImages(images)
                imagePreheatTask = nil
            } catch {
                guard let self, imagePreheatRevision == revision else { return }
                imagePreheatTask = nil
            }
        }
    }

    private func installPreheatedImages(_ images: [String: LYSVGAPreparedImage]) {
        withoutAnimations {
            for layer in spriteLayers + additionalMatteLayers {
                let key = LYSVGAResourceKey.canonicalize(layer.imageKeyForDynamicContent)
                layer.replaceOriginalImage(images[key]?.cgImage)
            }
        }
    }

    private func resolveMattes(
        in sprites: [LYSVGASprite]
    ) -> (contentToMatte: [Int: Int], missing: Set<Int>) {
        var exact: [String: Int] = [:]
        var canonical: [String: Int] = [:]
        for (index, sprite) in sprites.enumerated() {
            if exact[sprite.imageKey] == nil {
                exact[sprite.imageKey] = index
            }
            let key = LYSVGAResourceKey.canonicalize(sprite.imageKey)
            if canonical[key] == nil {
                canonical[key] = index
            }
        }

        var contentToMatte: [Int: Int] = [:]
        var missing: Set<Int> = []
        for (index, sprite) in sprites.enumerated() {
            guard let matteKey = sprite.matteKey, matteKey.isEmpty == false else { continue }
            if let matteIndex = exact[matteKey] ?? canonical[LYSVGAResourceKey.canonicalize(matteKey)],
               matteIndex != index {
                contentToMatte[index] = matteIndex
            } else {
                missing.insert(index)
            }
        }
        return (contentToMatte, missing)
    }

    private func withoutAnimations(_ updates: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updates()
        CATransaction.commit()
    }
}

@MainActor
final class LYSVGAMatteHost {
    let layer = CALayer()
    let matteLayer: LYSVGASpriteLayer
    private(set) var contentLayers: [LYSVGASpriteLayer] = []

    init(matteLayer: LYSVGASpriteLayer, canvasSize: CGSize) {
        self.matteLayer = matteLayer
        layer.anchorPoint = .zero
        layer.position = .zero
        layer.bounds = CGRect(origin: .zero, size: canvasSize)
        layer.mask = matteLayer
        layer.isHidden = true
    }

    func addContentLayer(_ contentLayer: LYSVGASpriteLayer) {
        contentLayers.append(contentLayer)
        layer.addSublayer(contentLayer)
    }
}

private extension CGRect {
    var isFiniteRendererBounds: Bool {
        origin.x.isFinite && origin.y.isFinite &&
            width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
