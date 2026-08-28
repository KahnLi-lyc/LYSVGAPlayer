import AVFAudio
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

    static func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            assertionFailure("Unable to configure the demo audio session: \(error)")
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
