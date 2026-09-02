import Foundation
import UIKit

@MainActor
public final class LYSVGAImageView: LYSVGAPlayerView {
    @IBInspectable public var autoPlay = true

    @IBInspectable public var imageName: String? {
        didSet { loadImageName() }
    }

    public var resourceBundle: Bundle = .main
    public var assetLoader: LYSVGAAssetLoader = .shared
    public var cachePolicy: LYSVGACachePolicy = .automatic

    private var imageLoadTask: Task<Void, Never>?
    private var imageLoadRevision: UInt = 0

    public override func clear() {
        cancelImageLoad()
        super.clear()
    }

    deinit {
        imageLoadTask?.cancel()
    }
}

@MainActor
private extension LYSVGAImageView {
    func loadImageName() {
        cancelImageLoad()
        let revision = imageLoadRevision
        super.clear()

        guard let imageName, imageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }

        let source: LYSVGASource
        do {
            source = try makeSource(for: imageName)
        } catch {
            reportConvenienceLoadingFailure(error)
            return
        }

        let loader = assetLoader
        let policy = cachePolicy
        let shouldAutoplay = autoPlay
        imageLoadTask = Task { [weak self] in
            let video: LYSVGAVideo
            do {
                video = try await loader.load(source, cachePolicy: policy)
                try Task.checkCancellation()
            } catch {
                guard let self, self.imageLoadRevision == revision, Task.isCancelled == false else { return }
                self.reportConvenienceLoadingFailure(error)
                return
            }

            guard let self, self.imageLoadRevision == revision, Task.isCancelled == false else { return }
            do {
                try await self.setVideo(video, autoplay: shouldAutoplay)
            } catch {
                // LYSVGAPlayerView already reports current installation failures through its delegate.
            }
        }
    }

    func cancelImageLoad() {
        imageLoadTask?.cancel()
        imageLoadTask = nil
        imageLoadRevision &+= 1
    }

    func makeSource(for name: String) throws -> LYSVGASource {
        let lowercasedName = name.lowercased()
        if lowercasedName.hasPrefix("http://") || lowercasedName.hasPrefix("https://") {
            guard let url = URL(string: name),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host?.isEmpty == false else {
                throw LYSVGAError.invalidRequest("The imageName URL is invalid: \(name)")
            }
            return .remote(url)
        }
        return try .bundleResource(named: name, in: resourceBundle)
    }
}
