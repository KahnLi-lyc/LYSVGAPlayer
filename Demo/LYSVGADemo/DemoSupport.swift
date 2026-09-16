import AVFAudio
import Foundation
import UIKit

enum DemoSample: String, CaseIterable, Identifiable {
    case roseV2 = "rose_2.0.0"
    case roseV1 = "rose_1.5.0"
    case matte = "matteBitmap"
    case audio = "audio_biling"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .roseV2: "Rose V2"
        case .roseV1: "Rose V1"
        case .matte: "Matte"
        case .audio: "Audio"
        }
    }

    var url: URL? {
        Bundle.main.url(forResource: rawValue, withExtension: "svga")
    }
}

struct DemoLocalAsset: Identifiable {
    let url: URL

    var id: String { url.path }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

enum DemoSupport {
    static let localAssetsDidChange = Notification.Name("DemoSupport.localAssetsDidChange")

    static var localAssets: [DemoLocalAsset] {
        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first,
            let urls = try? FileManager.default.contentsOfDirectory(
                at: documentsURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension.lowercased() == "svga" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(DemoLocalAsset.init)
    }

    @discardableResult
    static func persistImportedFiles(_ urls: [URL]) throws -> [DemoLocalAsset] {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw DemoSupportError.documentsUnavailable
        }

        var imported: [DemoLocalAsset] = []
        defer {
            if imported.isEmpty == false {
                NotificationCenter.default.post(name: localAssetsDidChange, object: nil)
            }
        }
        for url in urls {
            guard url.pathExtension.lowercased() == "svga" else { continue }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }

            let destinationURL = documentsURL.appendingPathComponent(url.lastPathComponent, isDirectory: false)
            let temporaryURL = documentsURL.appendingPathComponent(
                ".\(UUID().uuidString).svga",
                isDirectory: false
            )
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            try FileManager.default.copyItem(at: url, to: temporaryURL)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            }
            imported.append(DemoLocalAsset(url: destinationURL))
        }
        return imported
    }

    static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, options: [.mixWithOthers])
        } catch {
            assertionFailure("Unable to configure the demo audio session: \(error)")
            return
        }

        if #available(iOS 27.0, *) {
            Task {
                do {
                    guard try await session.activate(options: []) else {
                        assertionFailure("Unable to activate the demo audio session.")
                        return
                    }
                } catch {
                    assertionFailure("Unable to activate the demo audio session: \(error)")
                }
            }
        } else {
            DispatchQueue.global(qos: .utility).async {
                do {
                    try session.setActive(true)
                } catch {
                    DispatchQueue.main.async {
                        assertionFailure("Unable to activate the demo audio session: \(error)")
                    }
                }
            }
        }
    }

    @MainActor
    static func replacementImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
            let symbol = UIImage(systemName: "sparkles")?.withTintColor(.white, renderingMode: .alwaysOriginal)
            symbol?.draw(in: CGRect(x: 40, y: 40, width: 80, height: 80))
        }
    }
}

private enum DemoSupportError: LocalizedError {
    case documentsUnavailable

    var errorDescription: String? {
        switch self {
        case .documentsUnavailable: "The app Documents directory is unavailable."
        }
    }
}
