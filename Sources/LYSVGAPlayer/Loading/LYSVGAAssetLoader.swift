import Foundation

public actor LYSVGAAssetLoader {
    private struct LoadedAsset: Sendable {
        let data: Data
        let video: LYSVGAVideo
    }

    private struct SharedRequest {
        let id: UUID
        let task: Task<LoadedAsset, Error>
        var waiters: [UUID: CheckedContinuation<LoadedAsset, Error>]
    }

    private let session: URLSession
    private let cache: LYSVGACache
    private var requests: [String: SharedRequest] = [:]

    public init(
        session: URLSession = .shared,
        cacheConfiguration: LYSVGACacheConfiguration = .default
    ) {
        self.session = session
        cache = LYSVGACache(configuration: cacheConfiguration)
    }

    public func load(
        _ source: LYSVGASource,
        cachePolicy: LYSVGACachePolicy = .automatic
    ) async throws -> LYSVGAVideo {
        do {
            try Task.checkCancellation()
            let key = try LYSVGACacheKey.make(for: source)

            switch cachePolicy {
            case .automatic:
                if let video = await cache.video(forKey: key) {
                    return video
                }
                if let data = try? await cache.data(forKey: key) {
                    do {
                        let video = try LYSVGAFormatDecoder.decode(data)
                        await cache.store(video: video, forKey: key)
                        return video
                    } catch {
                        await cache.removeDiskData(forKey: key)
                    }
                }
            case .memoryOnly:
                if let video = await cache.video(forKey: key) {
                    return video
                }
            case .reloadIgnoringCache, .noCache:
                break
            }

            let loaded = try await sharedLoad(source, key: key)
            try Task.checkCancellation()
            switch cachePolicy {
            case .automatic, .reloadIgnoringCache:
                await cache.store(video: loaded.video, forKey: key)
                try await cache.store(data: loaded.data, forKey: key)
            case .memoryOnly:
                await cache.store(video: loaded.video, forKey: key)
            case .noCache:
                break
            }
            return loaded.video
        } catch is CancellationError {
            throw LYSVGAError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw LYSVGAError.cancelled
        } catch let error as LYSVGAError {
            throw error
        } catch {
            throw LYSVGAError.networkFailure(error.localizedDescription)
        }
    }

    public func clearMemoryCache() async {
        await cache.clearMemory()
    }

    public func clearDiskCache() async throws {
        try await cache.clearDisk()
    }

    private func sharedLoad(_ source: LYSVGASource, key: String) async throws -> LoadedAsset {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                registerWaiter(
                    source: source,
                    key: key,
                    waiterID: waiterID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(key: key, waiterID: waiterID) }
        }
    }

    private func registerWaiter(
        source: LYSVGASource,
        key: String,
        waiterID: UUID,
        continuation: CheckedContinuation<LoadedAsset, Error>
    ) {
        if var shared = requests[key] {
            shared.waiters[waiterID] = continuation
            requests[key] = shared
        } else {
            let session = session
            let requestID = UUID()
            let task = Task {
                let data = try await Self.read(source, session: session)
                try Task.checkCancellation()
                return LoadedAsset(data: data, video: try LYSVGAFormatDecoder.decode(data))
            }
            requests[key] = SharedRequest(
                id: requestID,
                task: task,
                waiters: [waiterID: continuation]
            )
            Task {
                do {
                    completeRequest(key: key, requestID: requestID, result: .success(try await task.value))
                } catch {
                    completeRequest(key: key, requestID: requestID, result: .failure(error))
                }
            }
        }
    }

    private func completeRequest(
        key: String,
        requestID: UUID,
        result: Result<LoadedAsset, Error>
    ) {
        guard let current = requests[key], current.id == requestID,
              let shared = requests.removeValue(forKey: key) else { return }
        for continuation in shared.waiters.values {
            continuation.resume(with: result)
        }
    }

    private func cancelWaiter(key: String, waiterID: UUID) {
        guard var shared = requests[key] else { return }
        guard let continuation = shared.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: LYSVGAError.cancelled)
        if shared.waiters.isEmpty {
            shared.task.cancel()
            requests.removeValue(forKey: key)
        } else {
            requests[key] = shared
        }
    }

    private static func read(_ source: LYSVGASource, session: URLSession) async throws -> Data {
        try Task.checkCancellation()
        switch source {
        case let .data(data, _):
            return data
        case let .file(url):
            guard url.isFileURL else {
                throw LYSVGAError.fileFailure("A file source must use a file URL.")
            }
            do {
                return try Data(contentsOf: url, options: [.mappedIfSafe])
            } catch {
                throw LYSVGAError.fileFailure(error.localizedDescription)
            }
        case let .remote(url):
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw LYSVGAError.networkFailure("The response is not HTTP.")
                }
                guard (200 ... 299).contains(httpResponse.statusCode) else {
                    throw LYSVGAError.httpStatus(httpResponse.statusCode)
                }
                return data
            } catch let error as LYSVGAError {
                throw error
            } catch let error as URLError where error.code == .cancelled {
                throw LYSVGAError.cancelled
            } catch {
                throw LYSVGAError.networkFailure(error.localizedDescription)
            }
        }
    }
}
