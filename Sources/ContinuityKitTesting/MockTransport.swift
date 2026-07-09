import ContinuityKit
import Foundation

/// Scripted transport for tests: per-path responses, per-path download
/// payloads, and mid-download failure injection (fail-after-N-bytes fires
/// once, then the path succeeds — modeling a flaky server that recovers).
public final class MockTransport: ContinuityTransport, @unchecked Sendable {
    public enum ScriptedDownload {
        case success(Data)
        case failAfter(bytes: Int, data: Data)
        case unreachable
    }

    private let lock = NSLock()
    private var responses: [String: ContinuityResponse] = [:]
    private var downloads: [String: ScriptedDownload] = [:]
    private var _recordedRequests: [ContinuityRequest] = []
    private var _recordedResumeOffsets: [Int64] = []

    public init() {}

    // MARK: - Scripting

    public func setResponse(method: String, path: String, response: ContinuityResponse) {
        lock.lock(); defer { lock.unlock() }
        responses[key(method, path)] = response
    }

    public func setDownload(relativePath: String, script: ScriptedDownload) {
        lock.lock(); defer { lock.unlock() }
        downloads[relativePath] = script
    }

    // MARK: - Inspection

    public var recordedRequests: [ContinuityRequest] {
        lock.lock(); defer { lock.unlock() }
        return _recordedRequests
    }

    public var recordedResumeOffsets: [Int64] {
        lock.lock(); defer { lock.unlock() }
        return _recordedResumeOffsets
    }

    // MARK: - ContinuityTransport

    public func request(_ request: ContinuityRequest) async throws -> ContinuityResponse {
        let response: ContinuityResponse? = synchronized {
            _recordedRequests.append(request)
            return responses[key(request.method, request.url.path)]
        }
        guard let response else {
            throw ContinuityError.serverUnreachable(detail: "unscripted \(request.method) \(request.url.path)")
        }
        return response
    }

    public func download(
        _ request: ContinuityRequest,
        to destination: URL,
        resumeOffset: Int64,
        progress: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws -> Int64 {
        let relativePath = Self.relativePath(of: request) ?? request.url.path
        let scripted: ScriptedDownload? = synchronized {
            _recordedRequests.append(request)
            _recordedResumeOffsets.append(resumeOffset)
            return downloads[relativePath]
        }
        guard let script = scripted else {
            throw ContinuityError.serverUnreachable(detail: "unscripted download \(relativePath)")
        }

        switch script {
        case .unreachable:
            throw ContinuityError.serverUnreachable(detail: "scripted unreachable")

        case .success(let data):
            let slice = data.suffix(from: min(Int(resumeOffset), data.count))
            try write(slice, to: destination, at: resumeOffset)
            progress?(Int64(data.count), Int64(data.count))
            return Int64(data.count)

        case .failAfter(let bytes, let data):
            // One-shot: the next attempt on this path succeeds.
            synchronized { downloads[relativePath] = .success(data) }
            let stop = min(bytes, data.count)
            let slice = data.prefix(stop).suffix(from: min(Int(resumeOffset), stop))
            try write(slice, to: destination, at: resumeOffset)
            progress?(Int64(stop), Int64(data.count))
            throw ContinuityError.serverUnreachable(detail: "scripted mid-download failure")
        }
    }

    // MARK: - Helpers

    private func key(_ method: String, _ path: String) -> String { "\(method) \(path)" }

    /// NSLock.lock is `noasync`; funneling through a synchronous helper keeps
    /// the async protocol methods legal.
    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private static func relativePath(of request: ContinuityRequest) -> String? {
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == ContinuityRoutes.filePathQueryKey }?
            .value
    }

    private func write(_ data: Data, to destination: URL, at offset: Int64) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: destination.path) {
            fileManager.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(offset))
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
