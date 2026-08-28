import Foundation
import UIKit

@MainActor
public final class LYSVGAFrameExporter {
    public let video: LYSVGAVideo

    private let renderer: LYSVGARenderer

    public init(video: LYSVGAVideo) async throws {
        self.video = video
        let renderer = LYSVGARenderer()
        self.renderer = renderer
        do {
            try await renderer.prepare(video: video)
        } catch is CancellationError {
            throw LYSVGAError.cancelled
        }
    }

    public func image(
        atFrame frame: Int,
        size: CGSize? = nil,
        scale: CGFloat = 1,
        contentMode: UIView.ContentMode = .scaleAspectFit
    ) throws -> UIImage {
        let outputSize = try validatedOutput(size: size, scale: scale)
        guard (0..<video.frameCount).contains(frame) else {
            throw LYSVGAError.invalidExportConfiguration(
                "Frame \(frame) is outside 0..<\(video.frameCount)."
            )
        }

        renderer.layout(
            in: CGRect(origin: .zero, size: outputSize),
            contentMode: contentMode,
            clipsToBounds: true
        )
        renderer.display(frame: frame)

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            renderer.rootLayer.render(in: context.cgContext)
        }
    }

    public func pngData(
        atFrame frame: Int,
        size: CGSize? = nil,
        scale: CGFloat = 1,
        contentMode: UIView.ContentMode = .scaleAspectFit
    ) throws -> Data {
        guard let data = try image(
            atFrame: frame,
            size: size,
            scale: scale,
            contentMode: contentMode
        ).pngData() else {
            throw LYSVGAError.exportEncodingFailure(frame: frame)
        }
        return data
    }

    public func exportPNGSequence(
        frames: ClosedRange<Int>? = nil,
        to directory: URL,
        filePrefix: String = "frame_",
        size: CGSize? = nil,
        scale: CGFloat = 1,
        contentMode: UIView.ContentMode = .scaleAspectFit
    ) async throws -> [URL] {
        let frameRange = try validatedFrames(frames)
        _ = try validatedOutput(size: size, scale: scale)
        guard directory.isFileURL else {
            throw LYSVGAError.invalidExportConfiguration("The output directory must be a file URL.")
        }
        guard filePrefix.contains("/") == false else {
            throw LYSVGAError.invalidExportConfiguration("The file prefix cannot contain path separators.")
        }

        do {
            try await LYSVGAPNGSequenceWriter.createDirectory(directory)
            var urls: [URL] = []
            urls.reserveCapacity(frameRange.count)
            for frame in frameRange {
                try Task.checkCancellation()
                let data = try pngData(
                    atFrame: frame,
                    size: size,
                    scale: scale,
                    contentMode: contentMode
                )
                let frameText = String(frame)
                let padding = String(repeating: "0", count: max(0, 5 - frameText.count))
                let filename = filePrefix + padding + frameText + ".png"
                let url = directory.appendingPathComponent(filename, isDirectory: false)
                try await LYSVGAPNGSequenceWriter.write(data, to: url)
                urls.append(url)
            }
            return urls
        } catch is CancellationError {
            throw LYSVGAError.cancelled
        } catch let error as LYSVGAError {
            throw error
        } catch {
            throw LYSVGAError.exportFileFailure(
                path: directory.path,
                reason: error.localizedDescription
            )
        }
    }

    private func validatedFrames(_ frames: ClosedRange<Int>?) throws -> ClosedRange<Int> {
        let range = frames ?? 0...(video.frameCount - 1)
        guard range.lowerBound >= 0, range.upperBound < video.frameCount else {
            throw LYSVGAError.invalidExportConfiguration(
                "Frame range \(range) is outside 0..<\(video.frameCount)."
            )
        }
        return range
    }

    private func validatedOutput(size: CGSize?, scale: CGFloat) throws -> CGSize {
        let outputSize = size ?? CGSize(
            width: video.canvasSize.width,
            height: video.canvasSize.height
        )
        guard outputSize.width.isFinite, outputSize.height.isFinite,
              outputSize.width > 0, outputSize.height > 0 else {
            throw LYSVGAError.invalidExportConfiguration(
                "Output dimensions must be finite and greater than zero."
            )
        }
        guard scale.isFinite, scale > 0 else {
            throw LYSVGAError.invalidExportConfiguration(
                "Output scale must be finite and greater than zero."
            )
        }

        let pixelWidth = outputSize.width * scale
        let pixelHeight = outputSize.height * scale
        let pixelCount = pixelWidth * pixelHeight
        guard pixelWidth.isFinite, pixelHeight.isFinite, pixelCount.isFinite,
              pixelWidth >= 1, pixelHeight >= 1,
              pixelWidth <= 16_384, pixelHeight <= 16_384,
              pixelCount <= 67_108_864 else {
            throw LYSVGAError.invalidExportConfiguration(
                "Output must be at least 1 pixel and cannot exceed a 16384-pixel dimension or 64 megapixels."
            )
        }
        return outputSize
    }
}

private enum LYSVGAPNGSequenceWriter {
    @concurrent
    static func createDirectory(_ directory: URL) async throws {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw LYSVGAError.exportFileFailure(
                path: directory.path,
                reason: error.localizedDescription
            )
        }
    }

    @concurrent
    static func write(_ data: Data, to url: URL) async throws {
        try Task.checkCancellation()
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw LYSVGAError.exportFileFailure(
                path: url.path,
                reason: error.localizedDescription
            )
        }
        try Task.checkCancellation()
    }
}
