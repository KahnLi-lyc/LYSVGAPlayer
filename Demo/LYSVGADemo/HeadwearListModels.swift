import Foundation
import LYSVGAPlayer

struct HeadwearListUser: Hashable, Sendable {
    let id: Int
    let displayName: String
    let status: String
    let avatarColorIndex: Int

    static let samples: [HeadwearListUser] = {
        let names = [
            "Avery", "Blake", "Casey", "Dakota", "Emery", "Finley", "Gray", "Harper",
            "Indigo", "Jordan", "Kai", "Logan", "Morgan", "Nova", "Parker", "Quinn",
        ]
        let statuses = ["Online", "In a room", "Listening", "Available"]
        return (0..<200).map { index in
            HeadwearListUser(
                id: index,
                displayName: "\(names[index % names.count]) \(index + 1)",
                status: statuses[index % statuses.count],
                avatarColorIndex: index
            )
        }
    }()
}

struct HeadwearListAsset: Sendable {
    let id: String
    let title: String
    let fileName: String
    let video: LYSVGAVideo
}

enum HeadwearListMode: Int, CaseIterable, Sendable {
    case single
    case mixed

    var title: String {
        switch self {
        case .single: "Single"
        case .mixed: "Mixed"
        }
    }
}

struct HeadwearListLoadResult: Sendable {
    let assets: [HeadwearListAsset]
    let failures: [String]
}

enum HeadwearListAssetRepository {
    private struct Descriptor: Sendable {
        let id: String
        let title: String
        let fileName: String
        let source: LYSVGASource
    }

    private enum Outcome: Sendable {
        case success(Int, HeadwearListAsset)
        case failure(Int, String)
    }

    @MainActor
    static func load(using loader: LYSVGAAssetLoader) async -> HeadwearListLoadResult {
        let localDescriptors = Array(DemoSupport.localAssets.prefix(12)).map { asset in
            Descriptor(
                id: asset.url.path,
                title: asset.title,
                fileName: asset.url.lastPathComponent,
                source: .file(asset.url)
            )
        }
        let fallbackDescriptors = bundledDescriptors()
        let primaryDescriptors = localDescriptors.isEmpty ? fallbackDescriptors : localDescriptors
        let primary = await load(primaryDescriptors, using: loader)
        guard primary.assets.isEmpty, localDescriptors.isEmpty == false else {
            return primary
        }

        let fallback = await load(fallbackDescriptors, using: loader)
        return HeadwearListLoadResult(
            assets: fallback.assets,
            failures: primary.failures + fallback.failures
        )
    }

    @MainActor
    private static func bundledDescriptors() -> [Descriptor] {
        [DemoSample.roseV2, .roseV1, .matte].compactMap { sample in
            guard let url = sample.url else { return nil }
            return Descriptor(
                id: sample.rawValue,
                title: sample.title,
                fileName: url.lastPathComponent,
                source: .file(url)
            )
        }
    }

    private static func load(
        _ descriptors: [Descriptor],
        using loader: LYSVGAAssetLoader
    ) async -> HeadwearListLoadResult {
        guard descriptors.isEmpty == false else {
            return HeadwearListLoadResult(assets: [], failures: ["No SVGA assets are available."])
        }

        var iterator = Array(descriptors.enumerated()).makeIterator()
        var outcomes: [Outcome] = []
        await withTaskGroup(of: Outcome.self) { group in
            for _ in 0..<min(3, descriptors.count) {
                guard let item = iterator.next() else { break }
                addLoadTask(item, loader: loader, to: &group)
            }
            while let outcome = await group.next() {
                outcomes.append(outcome)
                if let item = iterator.next() {
                    addLoadTask(item, loader: loader, to: &group)
                }
            }
        }

        let orderedAssets = outcomes.compactMap { outcome -> (Int, HeadwearListAsset)? in
            guard case let .success(index, asset) = outcome else { return nil }
            return (index, asset)
        }.sorted { $0.0 < $1.0 }.map(\.1)
        let failures = outcomes.compactMap { outcome -> (Int, String)? in
            guard case let .failure(index, message) = outcome else { return nil }
            return (index, message)
        }.sorted { $0.0 < $1.0 }.map(\.1)
        return HeadwearListLoadResult(assets: orderedAssets, failures: failures)
    }

    private static func addLoadTask(
        _ item: (offset: Int, element: Descriptor),
        loader: LYSVGAAssetLoader,
        to group: inout TaskGroup<Outcome>
    ) {
        group.addTask {
            do {
                let video = try await loader.load(item.element.source, cachePolicy: .automatic)
                let silentVideo = try LYSVGAVideo(
                    version: video.version,
                    canvasSize: video.canvasSize,
                    fps: video.fps,
                    frameCount: video.frameCount,
                    images: video.images,
                    audioData: [:],
                    sprites: video.sprites,
                    audios: []
                )
                return .success(
                    item.offset,
                    HeadwearListAsset(
                        id: item.element.id,
                        title: item.element.title,
                        fileName: item.element.fileName,
                        video: silentVideo
                    )
                )
            } catch {
                return .failure(item.offset, "\(item.element.title): \(error.localizedDescription)")
            }
        }
    }
}
