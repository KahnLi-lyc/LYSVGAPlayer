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

    init() {
        rootLayer.anchorPoint = .zero
        canvasLayer.anchorPoint = .zero
        rootLayer.addSublayer(canvasLayer)
    }

    func prepare(video: LYSVGAVideo) async throws {
        let images = try await LYSVGAImagePreparer.prepare(video)
        buildLayerTree(video: video, images: images)
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
        withoutAnimations {
            guard let video, (0..<video.frameCount).contains(index) else {
                currentFrame = nil
                spriteLayers.forEach { $0.hide() }
                matteHosts.forEach { $0.layer.isHidden = true }
                return
            }

            currentFrame = index
            for spriteLayer in spriteLayers {
                spriteLayer.display(frame: index)
            }
            for index in missingMatteSpriteIndices {
                spriteLayers[index].hide()
            }
            for host in matteHosts {
                host.layer.isHidden = host.matteLayer.isHidden || host.contentLayers.allSatisfy(\.isHidden)
            }
        }
    }

    private func buildLayerTree(video: LYSVGAVideo, images: [String: LYSVGAPreparedImage]) {
        withoutAnimations {
            canvasLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            canvasLayer.mask = nil
            currentFrame = nil
            self.video = video
            matteHosts = []
            missingMatteSpriteIndices = []

            let canvasSize = CGSize(width: video.canvasSize.width, height: video.canvasSize.height)
            canvasLayer.bounds = CGRect(origin: .zero, size: canvasSize)
            spriteLayers = video.sprites.map { sprite in
                let image = images[LYSVGAResourceKey.canonicalize(sprite.imageKey)]?.cgImage
                return LYSVGASpriteLayer(sprite: sprite, image: image, canvasSize: canvasSize)
            }

            let matteResolution = resolveMattes(in: video.sprites)
            missingMatteSpriteIndices = matteResolution.missing
            let matteIndices = Set(matteResolution.contentToMatte.values)
            var hostsByMatteIndex: [Int: LYSVGAMatteHost] = [:]

            for (index, spriteLayer) in spriteLayers.enumerated() {
                if matteIndices.contains(index) {
                    continue
                }
                if missingMatteSpriteIndices.contains(index) {
                    spriteLayer.hide()
                    continue
                }
                guard let matteIndex = matteResolution.contentToMatte[index] else {
                    canvasLayer.addSublayer(spriteLayer)
                    continue
                }

                let host: LYSVGAMatteHost
                if let existing = hostsByMatteIndex[matteIndex] {
                    host = existing
                } else {
                    host = LYSVGAMatteHost(matteLayer: spriteLayers[matteIndex], canvasSize: canvasSize)
                    hostsByMatteIndex[matteIndex] = host
                    matteHosts.append(host)
                    canvasLayer.addSublayer(host.layer)
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
