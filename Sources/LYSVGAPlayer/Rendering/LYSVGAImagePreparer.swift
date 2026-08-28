import CoreGraphics
import Foundation
import ImageIO

struct LYSVGAPreparedImage: @unchecked Sendable {
    // CGImage is an immutable Core Graphics object after creation.
    let cgImage: CGImage
    let isPixelDecoded: Bool

    init(cgImage: CGImage, isPixelDecoded: Bool = false) {
        self.cgImage = cgImage
        self.isPixelDecoded = isPixelDecoded
    }
}

enum LYSVGAImagePreparer {
    private enum PixelCachePolicy: Sendable {
        case deferred
        case eager
    }

    private static let cache = LYSVGAPreparedImageCache()

    static var decodeOptions: CFDictionary {
        [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ] as CFDictionary
    }

    static var eagerDecodeOptions: CFDictionary {
        [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
    }

    @concurrent
    static func prepare(
        _ video: LYSVGAVideo,
        checkpoint: (@Sendable () async -> Void)? = nil
    ) async throws -> [String: LYSVGAPreparedImage] {
        try Task.checkCancellation()
        return try await prepareImmediately(canonicalSources(in: video), checkpoint: checkpoint)
    }

    @concurrent
    static func prepareEagerly(_ video: LYSVGAVideo) async throws -> [String: LYSVGAPreparedImage] {
        try Task.checkCancellation()
        return try await prepareImmediately(
            canonicalSources(in: video),
            checkpoint: nil,
            pixelCachePolicy: .eager,
            readsCache: false
        )
    }

    private static func canonicalSources(in video: LYSVGAVideo) -> [String: Data] {
        var sources: [String: Data] = [:]
        sources.reserveCapacity(video.images.count)
        for (sourceKey, data) in video.images {
            sources[LYSVGAResourceKey.canonicalize(sourceKey)] = data
        }
        return sources
    }

    @concurrent
    private static func prepareImmediately(
        _ sources: [String: Data],
        checkpoint: (@Sendable () async -> Void)?,
        pixelCachePolicy: PixelCachePolicy = .deferred,
        readsCache: Bool = true
    ) async throws -> [String: LYSVGAPreparedImage] {
        return try await withThrowingTaskGroup(
            of: (String, LYSVGAPreparedImage).self,
            returning: [String: LYSVGAPreparedImage].self
        ) { group in
            for (key, data) in sources {
                group.addTask {
                    try Task.checkCancellation()
                    if readsCache, checkpoint == nil,
                       let cachedImage = cache.image(for: data),
                       pixelCachePolicy == .deferred || cachedImage.isPixelDecoded {
                        try Task.checkCancellation()
                        return (key, cachedImage)
                    }
                    await checkpoint?()
                    try Task.checkCancellation()
                    let image = try decode(
                        data,
                        key: key,
                        options: pixelCachePolicy == .eager ? eagerDecodeOptions : decodeOptions,
                        isPixelDecoded: pixelCachePolicy == .eager
                    )
                    try Task.checkCancellation()
                    let resultImage = checkpoint == nil
                        ? cache.insertPreferred(image, for: data)
                        : image
                    try Task.checkCancellation()
                    return (key, resultImage)
                }
            }

            var result: [String: LYSVGAPreparedImage] = [:]
            result.reserveCapacity(sources.count)
            for try await (key, image) in group {
                result[key] = image
            }
            try Task.checkCancellation()
            return result
        }
    }

    private static func decode(
        _ data: Data,
        key: String,
        options: CFDictionary,
        isPixelDecoded: Bool
    ) throws -> LYSVGAPreparedImage {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: true] as CFDictionary
        ), let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            throw LYSVGAError.imagePreparationFailure(key)
        }
        return LYSVGAPreparedImage(cgImage: image, isPixelDecoded: isPixelDecoded)
    }

    static func resetCacheForTesting() {
        cache.removeAllImages()
    }
}

private final class LYSVGAPreparedImageBox {
    let image: LYSVGAPreparedImage

    init(_ image: LYSVGAPreparedImage) {
        self.image = image
    }
}

private final class LYSVGAPreparedImageCache: @unchecked Sendable {
    private static let countLimit = 128
    private static let totalCostLimit = 128 * 1_024 * 1_024

    private let storage: NSCache<NSData, LYSVGAPreparedImageBox>
    private let insertionLock = NSLock()

    init() {
        let storage = NSCache<NSData, LYSVGAPreparedImageBox>()
        storage.countLimit = Self.countLimit
        storage.totalCostLimit = Self.totalCostLimit
        self.storage = storage
    }

    func image(for data: Data) -> LYSVGAPreparedImage? {
        storage.object(forKey: data as NSData)?.image
    }

    func insertPreferred(
        _ image: LYSVGAPreparedImage,
        for data: Data
    ) -> LYSVGAPreparedImage {
        insertionLock.withLock {
            let key = data as NSData
            if let cachedImage = storage.object(forKey: key)?.image,
               cachedImage.isPixelDecoded || image.isPixelDecoded == false {
                return cachedImage
            }
            storage.setObject(
                LYSVGAPreparedImageBox(image),
                forKey: key,
                cost: Self.cost(of: image.cgImage, encodedDataCount: data.count)
            )
            return image
        }
    }

    func removeAllImages() {
        insertionLock.withLock {
            storage.removeAllObjects()
        }
    }

    private static func cost(of image: CGImage, encodedDataCount: Int) -> Int {
        let (decodedCost, multiplicationOverflow) = image.bytesPerRow.multipliedReportingOverflow(
            by: image.height
        )
        guard multiplicationOverflow == false else { return Int.max }
        let (totalCost, additionOverflow) = decodedCost.addingReportingOverflow(encodedDataCount)
        return additionOverflow ? Int.max : totalCost
    }
}
