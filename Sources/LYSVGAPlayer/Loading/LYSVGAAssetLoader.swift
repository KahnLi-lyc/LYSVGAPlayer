import Foundation
import os

typealias LYSVGAAssetReader = @Sendable (LYSVGASource, URLSession) async throws -> Data
typealias LYSVGAAssetDecoder = @Sendable (Data) throws -> LYSVGAVideo

public actor LYSVGAAssetLoader {
    public static let shared = LYSVGAAssetLoader()

    private struct SharedRequest {
        let id: UUID
        let task: Task<LYSVGAVideo, Error>
        var waiters: [UUID: CheckedContinuation<LYSVGAVideo, Error>]
    }

    private static let logger = Logger(subsystem: "LYSVGAPlayer", category: "AssetLoader")

    private let session: URLSession
    private let cache: LYSVGACache
    private let reader: LYSVGAAssetReader
    private let decoder: LYSVGAAssetDecoder
    private var requests: [String: SharedRequest] = [:]

    /// - Parameter faultTolerance: `.lenient` (default) skips missing archive resources and
    ///   repairs inconsistent frame counts or audio cues, recording them in `LYSVGAVideo.warnings`.
    ///   `.strict` rejects such files. The memory cache belongs to this loader, so loaders with
    ///   different policies never share decoded videos.
    public init(
        session: URLSession = .shared,
        cacheConfiguration: LYSVGACacheConfiguration = .default,
        faultTolerance: LYSVGAFaultTolerance = .lenient
    ) {
        self.session = session
        cache = LYSVGACache(configuration: cacheConfiguration)
        reader = Self.read
        decoder = { data in try LYSVGAFormatDecoder.decode(data, faultTolerance: faultTolerance) }
    }

    init(
        session: URLSession,
        cacheConfiguration: LYSVGACacheConfiguration,
        reader: @escaping LYSVGAAssetReader,
        decoder: @escaping LYSVGAAssetDecoder
    ) {
        self.session = session
        cache = LYSVGACache(configuration: cacheConfiguration)
        self.reader = reader
        self.decoder = decoder
    }

    public func load(
        _ source: LYSVGASource,
        cachePolicy: LYSVGACachePolicy = .automatic
    ) async throws -> LYSVGAVideo {
        do {
            try Task.checkCancellation()
            let key = try LYSVGACacheKey.make(for: source)

            switch cachePolicy {
            case .automatic, .memoryOnly:
                if let video = await cache.video(forKey: key) {
                    return video
                }
            case .reloadIgnoringCache, .noCache:
                break
            }

            let video = try await sharedLoad(source, key: key, cachePolicy: cachePolicy)
            try Task.checkCancellation()
            return video
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

    /// Joins (or starts) the single pipeline for this cache key and policy.
    ///
    /// The shared task performs disk lookup, reading, decoding and cache writes exactly once,
    /// so concurrent callers never decode or write the same asset repeatedly.
    private func sharedLoad(
        _ source: LYSVGASource,
        key: String,
        cachePolicy: LYSVGACachePolicy
    ) async throws -> LYSVGAVideo {
        let requestKey = "\(key)#\(Self.tag(for: cachePolicy))"
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                registerWaiter(
                    source: source,
                    key: key,
                    requestKey: requestKey,
                    cachePolicy: cachePolicy,
                    waiterID: waiterID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(requestKey: requestKey, waiterID: waiterID) }
        }
    }

    private func registerWaiter(
        source: LYSVGASource,
        key: String,
        requestKey: String,
        cachePolicy: LYSVGACachePolicy,
        waiterID: UUID,
        continuation: CheckedContinuation<LYSVGAVideo, Error>
    ) {
        if var shared = requests[requestKey] {
            shared.waiters[waiterID] = continuation
            requests[requestKey] = shared
            return
        }

        let session = session
        let reader = reader
        let decoder = decoder
        let cache = cache
        let requestID = UUID()
        let task = Task.detached {
            try await Self.runPipeline(
                source: source,
                key: key,
                cachePolicy: cachePolicy,
                session: session,
                reader: reader,
                decoder: decoder,
                cache: cache
            )
        }
        requests[requestKey] = SharedRequest(
            id: requestID,
            task: task,
            waiters: [waiterID: continuation]
        )
        Task {
            do {
                completeRequest(requestKey: requestKey, requestID: requestID, result: .success(try await task.value))
            } catch {
                completeRequest(requestKey: requestKey, requestID: requestID, result: .failure(error))
            }
        }
    }

    private func completeRequest(
        requestKey: String,
        requestID: UUID,
        result: Result<LYSVGAVideo, Error>
    ) {
        guard let current = requests[requestKey], current.id == requestID,
              let shared = requests.removeValue(forKey: requestKey) else { return }
        for continuation in shared.waiters.values {
            continuation.resume(with: result)
        }
    }

    private func cancelWaiter(requestKey: String, waiterID: UUID) {
        guard var shared = requests[requestKey] else { return }
        guard let continuation = shared.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: LYSVGAError.cancelled)
        if shared.waiters.isEmpty {
            shared.task.cancel()
            requests.removeValue(forKey: requestKey)
        } else {
            requests[requestKey] = shared
        }
    }

    private static func runPipeline(
        source: LYSVGASource,
        key: String,
        cachePolicy: LYSVGACachePolicy,
        session: URLSession,
        reader: LYSVGAAssetReader,
        decoder: LYSVGAAssetDecoder,
        cache: LYSVGACache
    ) async throws -> LYSVGAVideo {
        // Local data and files are already on device; copying them into the disk cache only
        // costs I/O and space, so they are cached in memory only.
        let usesDiskCache = source.usesDiskCache

        if cachePolicy == .automatic, usesDiskCache, let data = try? await cache.data(forKey: key) {
            do {
                try Task.checkCancellation()
                let video = try decoder(data)
                try Task.checkCancellation()
                await cache.store(video: video, forKey: key)
                return video
            } catch let error where isCancellation(error) {
                // Keep the valid disk entry and do not fall back to the reader.
                throw error
            } catch {
                await cache.removeDiskData(forKey: key)
            }
        }

        let data = try await reader(source, session)
        try Task.checkCancellation()
        let video = try decoder(data)
        try Task.checkCancellation()

        switch cachePolicy {
        case .automatic, .reloadIgnoringCache:
            await cache.store(video: video, forKey: key)
            if usesDiskCache {
                do {
                    try await cache.store(data: data, forKey: key)
                } catch {
                    // The asset loaded successfully; a failed cache write must not fail playback.
                    logger.error("Disk cache write failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        case .memoryOnly:
            await cache.store(video: video, forKey: key)
        case .noCache:
            break
        }
        return video
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError, error.code == .cancelled { return true }
        if let error = error as? LYSVGAError, error == .cancelled { return true }
        return false
    }

    private static func tag(for cachePolicy: LYSVGACachePolicy) -> String {
        switch cachePolicy {
        case .automatic: "automatic"
        case .reloadIgnoringCache: "reload"
        case .memoryOnly: "memory"
        case .noCache: "none"
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
            return try await read(request, session: session)
        case let .request(request):
            guard request.httpBodyStream == nil else {
                throw LYSVGAError.invalidRequest(
                    "URLRequest.httpBodyStream is unsupported because it cannot be replayed safely."
                )
            }
            return try await read(request, session: session)
        }
    }

    private static func read(_ request: URLRequest, session: URLSession) async throws -> Data {
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

private extension LYSVGASource {
    var usesDiskCache: Bool {
        switch self {
        case .remote, .request: true
        case .data, .file: false
        }
    }
}
