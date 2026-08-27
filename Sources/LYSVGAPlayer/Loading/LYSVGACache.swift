import Foundation

actor LYSVGACache {
    private struct MemoryEntry {
        let video: LYSVGAVideo
        let cost: Int
        var access: UInt64
    }

    private struct DiskMetadata: Codable {
        let key: String
        let size: Int
        let createdAt: Date
        var accessedAt: Date
        let expiresAt: Date
    }

    private let configuration: LYSVGACacheConfiguration
    private let fileManager: FileManager
    private var memory: [String: MemoryEntry] = [:]
    private var memoryCost = 0
    private var accessCounter: UInt64 = 0

    init(configuration: LYSVGACacheConfiguration, fileManager: FileManager = .default) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    func video(forKey key: String) -> LYSVGAVideo? {
        guard var entry = memory[key] else { return nil }
        accessCounter &+= 1
        entry.access = accessCounter
        memory[key] = entry
        return entry.video
    }

    func store(video: LYSVGAVideo, forKey key: String) {
        guard configuration.memoryCountLimit > 0, configuration.memoryCostLimit > 0 else { return }
        let cost = estimateCost(video)
        if let previous = memory.removeValue(forKey: key) {
            memoryCost -= previous.cost
        }
        accessCounter &+= 1
        memory[key] = MemoryEntry(video: video, cost: cost, access: accessCounter)
        memoryCost += cost
        trimMemory()
    }

    func data(forKey key: String, now: Date = Date()) throws -> Data? {
        let metadataURL = metadataURL(forKey: key)
        guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
        do {
            var metadata = try JSONDecoder().decode(DiskMetadata.self, from: Data(contentsOf: metadataURL))
            guard metadata.key == key else {
                try removeDiskEntry(forKey: key)
                throw LYSVGAError.cacheFailure("Disk metadata key mismatch.")
            }
            guard metadata.expiresAt > now else {
                try removeDiskEntry(forKey: key)
                return nil
            }
            let data = try Data(contentsOf: dataURL(forKey: key), options: [.mappedIfSafe])
            guard data.count == metadata.size else {
                try removeDiskEntry(forKey: key)
                throw LYSVGAError.cacheFailure("Disk entry size does not match metadata.")
            }
            metadata.accessedAt = now
            try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
            return data
        } catch let error as LYSVGAError {
            throw error
        } catch {
            try? removeDiskEntry(forKey: key)
            throw LYSVGAError.cacheFailure(error.localizedDescription)
        }
    }

    func store(data: Data, forKey key: String, now: Date = Date()) throws {
        guard configuration.diskSizeLimit > 0, configuration.timeToLive > 0 else { return }
        do {
            try ensureDirectory()
            try data.write(to: dataURL(forKey: key), options: .atomic)
            let metadata = DiskMetadata(
                key: key,
                size: data.count,
                createdAt: now,
                accessedAt: now,
                expiresAt: now.addingTimeInterval(configuration.timeToLive)
            )
            try JSONEncoder().encode(metadata).write(to: metadataURL(forKey: key), options: .atomic)
            try trimDisk(now: now)
        } catch let error as LYSVGAError {
            throw error
        } catch {
            try? removeDiskEntry(forKey: key)
            throw LYSVGAError.cacheFailure(error.localizedDescription)
        }
    }

    func clearMemory() {
        memory.removeAll(keepingCapacity: false)
        memoryCost = 0
    }

    func clearDisk() throws {
        guard fileManager.fileExists(atPath: configuration.directory.path) else { return }
        do {
            try fileManager.removeItem(at: configuration.directory)
        } catch {
            throw LYSVGAError.cacheFailure(error.localizedDescription)
        }
    }

    func removeDiskData(forKey key: String) {
        try? removeDiskEntry(forKey: key)
    }

    private func estimateCost(_ video: LYSVGAVideo) -> Int {
        video.images.values.reduce(0) { $0 + $1.count }
            + video.audioData.values.reduce(0) { $0 + $1.count }
            + video.sprites.reduce(0) { $0 + ($1.frames.count * 256) }
    }

    private func trimMemory() {
        while memory.count > configuration.memoryCountLimit || memoryCost > configuration.memoryCostLimit {
            guard let victim = memory.min(by: { $0.value.access < $1.value.access }) else { return }
            memoryCost -= victim.value.cost
            memory.removeValue(forKey: victim.key)
        }
    }

    private func trimDisk(now: Date) throws {
        let metadataFiles = try fileManager.contentsOfDirectory(
            at: configuration.directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        var live: [(DiskMetadata, URL)] = []
        var totalSize = 0
        for url in metadataFiles {
            guard let metadata = try? JSONDecoder().decode(DiskMetadata.self, from: Data(contentsOf: url)) else {
                try? fileManager.removeItem(at: url)
                continue
            }
            if metadata.expiresAt <= now {
                try? removeDiskEntry(forKey: metadata.key)
            } else {
                live.append((metadata, url))
                totalSize += metadata.size
            }
        }
        for (metadata, _) in live.sorted(by: { $0.0.accessedAt < $1.0.accessedAt })
            where totalSize > configuration.diskSizeLimit {
            try removeDiskEntry(forKey: metadata.key)
            totalSize -= metadata.size
        }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
    }

    private func dataURL(forKey key: String) -> URL {
        configuration.directory.appendingPathComponent(key).appendingPathExtension("data")
    }

    private func metadataURL(forKey key: String) -> URL {
        configuration.directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    private func removeDiskEntry(forKey key: String) throws {
        for url in [dataURL(forKey: key), metadataURL(forKey: key)]
            where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
