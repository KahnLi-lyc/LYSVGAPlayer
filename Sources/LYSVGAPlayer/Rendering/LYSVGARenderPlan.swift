import CoreGraphics
import Foundation

/// Precompiled, immutable vector geometry for one sprite.
///
/// `CGPath` and `CGColor` are immutable after creation, so a plan can be built off the main
/// thread and shared by every player that renders the same video.
struct LYSVGAVectorPlan: @unchecked Sendable {
    /// For each frame, the frame whose shapes are displayed (keep frames resolve backwards).
    let resolvedFrameIndices: [Int?]
    /// Size of the reusable `CAShapeLayer` pool.
    let maximumShapeCount: Int
    /// Descriptors keyed by resolved frame index.
    let descriptors: [Int: [LYSVGAShapeDescriptor]]
}

struct LYSVGASpriteRenderPlan: @unchecked Sendable {
    /// `nil` when the sprite has no drawable vector shapes.
    let vector: LYSVGAVectorPlan?
    /// Parsed clip paths keyed by frame index; frames with invalid paths are absent.
    let clipPaths: [Int: CGPath]
}

final class LYSVGARenderPlan: @unchecked Sendable {
    let sprites: [LYSVGASpriteRenderPlan]

    init(video: LYSVGAVideo) {
        sprites = video.sprites.map(Self.makeSpritePlan)
    }

    /// Returns the plan shared by all copies of `video`, building it on the calling thread once.
    @concurrent
    static func shared(for video: LYSVGAVideo) async -> LYSVGARenderPlan {
        video.renderPlanBox.plan(for: video)
    }

    private static func makeSpritePlan(_ sprite: LYSVGASprite) -> LYSVGASpriteRenderPlan {
        var clipPaths: [Int: CGPath] = [:]
        for (index, frame) in sprite.frames.enumerated() {
            guard let value = frame.clipPath, let path = try? LYSVGASVGPathParser.parse(value) else { continue }
            clipPaths[index] = path
        }
        return LYSVGASpriteRenderPlan(vector: makeVectorPlan(sprite.frames), clipPaths: clipPaths)
    }

    private static func makeVectorPlan(_ frames: [LYSVGAFrame]) -> LYSVGAVectorPlan? {
        var resolvedFrameIndices: [Int?] = []
        resolvedFrameIndices.reserveCapacity(frames.count)
        var lastNonKeepFrame: Int?
        var maximumShapeCount = 0
        var descriptors: [Int: [LYSVGAShapeDescriptor]] = [:]

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
            descriptors[index] = frame.shapes.compactMap(LYSVGAShapeDescriptor.init)
        }

        guard maximumShapeCount > 0 else { return nil }
        return LYSVGAVectorPlan(
            resolvedFrameIndices: resolvedFrameIndices,
            maximumShapeCount: maximumShapeCount,
            descriptors: descriptors
        )
    }
}

/// Lazily holds the render plan of one decoded video. Copies of a `LYSVGAVideo` share the box,
/// so videos returned from the loader's memory cache compile their vector geometry only once.
final class LYSVGARenderPlanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var plan: LYSVGARenderPlan?

    func plan(for video: LYSVGAVideo) -> LYSVGARenderPlan {
        lock.withLock {
            if let plan { return plan }
            let built = LYSVGARenderPlan(video: video)
            plan = built
            return built
        }
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
