import Foundation

/// Production transport over URLSession. Downloads stream to disk in chunks —
/// game files run to gigabytes and must never be buffered whole.
public struct URLSessionContinuityTransport: ContinuityTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 3600
            config.waitsForConnectivity = false
            // NearbyArtMirror (app-side) fans out up to 6 concurrent thumb
            // fetches to the same host; HTTP/1.1's per-host default already
            // matches, but pin it explicitly so a platform default change
            // can't silently serialize the mirror back down. Keep in sync
            // with `NearbyArtMirror.concurrency` in the iFly app target.
            config.httpMaximumConnectionsPerHost = 6
            self.session = URLSession(configuration: config)
        }
    }

    public func request(_ request: ContinuityRequest) async throws -> ContinuityResponse {
        let urlRequest = makeURLRequest(request)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw ContinuityError.invalidResponse(status: -1)
            }
            return ContinuityResponse(status: http.statusCode, headers: headerDictionary(http), body: data)
        } catch let error as ContinuityError {
            throw error
        } catch {
            throw ContinuityError.serverUnreachable(detail: (error as? URLError)?.localizedDescription)
        }
    }

    public func download(
        _ request: ContinuityRequest,
        to destination: URL,
        resumeOffset: Int64,
        progress: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws -> Int64 {
        var request = request
        if resumeOffset > 0 {
            request.headers["Range"] = "bytes=\(resumeOffset)-"
        }
        let urlRequest = makeURLRequest(request)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch {
            throw ContinuityError.serverUnreachable(detail: (error as? URLError)?.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ContinuityError.invalidResponse(status: -1)
        }

        var writeOffset = resumeOffset
        switch http.statusCode {
        case 206:
            break
        case 200:
            // Server ignored the Range header — restart from zero.
            writeOffset = 0
        case 401:
            throw ContinuityError.tokenRejected
        case 404:
            throw ContinuityError.noActiveSession
        default:
            throw ContinuityError.invalidResponse(status: http.statusCode)
        }

        let expectedTotal = http.expectedContentLength > 0
            ? writeOffset + http.expectedContentLength
            : nil

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: destination.path) {
            fileManager.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(writeOffset))
        try handle.seekToEnd()

        var written = writeOffset
        var buffer = Data(capacity: 65_536)
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 65_536 {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    progress?(written, expectedTotal)
                    try Task.checkCancellation()
                }
            }
        } catch let error as CancellationError {
            try? handle.write(contentsOf: buffer)
            throw error
        } catch {
            // Keep partial bytes on disk for a Range resume next attempt.
            try? handle.write(contentsOf: buffer)
            throw ContinuityError.serverUnreachable(detail: (error as? URLError)?.localizedDescription)
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        progress?(written, expectedTotal)
        return written
    }

    // MARK: - Helpers

    private func makeURLRequest(_ request: ContinuityRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    private func headerDictionary(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return headers
    }
}
