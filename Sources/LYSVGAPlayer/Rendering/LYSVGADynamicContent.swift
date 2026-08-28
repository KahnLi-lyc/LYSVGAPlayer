import QuartzCore
import ImageIO
import UIKit

public typealias LYSVGADrawingHandler = @MainActor (_ layer: CALayer, _ frame: Int) -> Void

@MainActor
struct LYSVGADynamicContentEntry {
    var image: LYSVGAPreparedImage?
    var attributedText: NSAttributedString?
    var isHidden = false
    var drawingHandler: LYSVGADrawingHandler?
}

@MainActor
struct LYSVGADynamicContentStore {
    private var entries: [String: LYSVGADynamicContentEntry] = [:]

    func entry(forSpriteKey key: String) -> LYSVGADynamicContentEntry? {
        entries[LYSVGAResourceKey.standardizeDynamicKey(key)]
    }

    mutating func setImage(_ image: LYSVGAPreparedImage, forKey key: String) {
        entries[standardKey(key), default: LYSVGADynamicContentEntry()].image = image
    }

    mutating func setAttributedText(_ text: NSAttributedString, forKey key: String) {
        entries[standardKey(key), default: LYSVGADynamicContentEntry()].attributedText =
            NSAttributedString(attributedString: text)
    }

    mutating func setHidden(_ hidden: Bool, forKey key: String) {
        entries[standardKey(key), default: LYSVGADynamicContentEntry()].isHidden = hidden
    }

    mutating func setDrawingHandler(_ handler: LYSVGADrawingHandler?, forKey key: String) {
        entries[standardKey(key), default: LYSVGADynamicContentEntry()].drawingHandler = handler
    }

    mutating func clear() {
        entries.removeAll(keepingCapacity: false)
    }

    private func standardKey(_ key: String) -> String {
        LYSVGAResourceKey.standardizeDynamicKey(key)
    }
}

@MainActor
extension LYSVGAPreparedImage {
    init?(uiImage: UIImage) {
        if uiImage.imageOrientation == .up, let cgImage = uiImage.cgImage {
            self.init(cgImage: cgImage)
            return
        }

        guard uiImage.size.width.isFinite, uiImage.size.height.isFinite,
              uiImage.size.width > 0, uiImage.size.height > 0,
              uiImage.scale.isFinite, uiImage.scale > 0 else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = uiImage.scale
        format.opaque = false
        let normalized = UIGraphicsImageRenderer(size: uiImage.size, format: format).image { _ in
            uiImage.draw(in: CGRect(origin: .zero, size: uiImage.size))
        }
        guard let cgImage = normalized.cgImage else { return nil }
        self.init(cgImage: cgImage)
    }
}

enum LYSVGADynamicImageDecoder {
    @concurrent
    static func decode(_ data: Data, key: String) async throws -> LYSVGAPreparedImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: true] as CFDictionary
        ), let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            LYSVGAImagePreparer.decodeOptions
        ) else {
            throw LYSVGAError.dynamicImageDecodingFailure(key: key)
        }
        try Task.checkCancellation()
        return LYSVGAPreparedImage(cgImage: image)
    }
}
